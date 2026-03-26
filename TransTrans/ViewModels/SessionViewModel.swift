import SwiftUI
import Speech
import Translation
import AVFoundation
import os

/// Describes a missing permission that the user needs to grant in System Settings.
enum PermissionIssue: Identifiable {
    case microphone
    case speechRecognition

    var id: String {
        switch self {
        case .microphone: return "microphone"
        case .speechRecognition: return "speechRecognition"
        }
    }

    var title: String {
        switch self {
        case .microphone:
            return String(localized: "Microphone Access Required")
        case .speechRecognition:
            return String(localized: "Speech Recognition Access Required")
        }
    }

    var message: String {
        switch self {
        case .microphone:
            return String(localized: "TransTrans needs microphone access for speech transcription. Please enable it in System Settings > Privacy & Security > Microphone.")
        case .speechRecognition:
            return String(localized: "TransTrans needs speech recognition access for transcription. Please enable it in System Settings > Privacy & Security > Speech Recognition.")
        }
    }
}

private let logger = Logger(subsystem: "net.kcrt.app.transtrans", category: "Session")

/// A single line of transcribed/translated text displayed in the UI.
struct TranscriptLine: Identifiable {
    let id = UUID()
    var text: String
    var isPartial: Bool
    /// The time when this line was finalized (non-partial). Used for subtitle expiration.
    var finalizedAt: Date?
    /// True for visual separator lines inserted between sessions.
    var isSeparator: Bool = false
}

extension Array where Element == TranscriptLine {
    /// Returns only finalized, non-separator lines suitable for export.
    var finalizedLines: [TranscriptLine] {
        filter { !$0.isPartial && !$0.isSeparator }
    }
}

/// Controls which panes are visible in the main content area.
enum DisplayMode: String, CaseIterable {
    /// Show both source (transcription) and target (translation) panes.
    case dual
    /// Show only the target (translation) pane in a subtitle-style overlay at the bottom of the screen.
    case subtitle
    /// Show source pane on top with multiple translation panes stacked below (up to 3 targets).
    case multi
}

/// A single auto-replacement rule: when `from` appears in transcription output, replace with `to`.
struct AutoReplacement: Codable, Identifiable, Equatable {
    var id = UUID()
    var from: String
    var to: String
}

/// Encapsulates the mutable translation state for one target language slot.
/// Used for both the single-pane target and each multi-pane target.
struct TranslationSlot {
    var lines: [TranscriptLine] = []
    var queue: [(sentence: String, targetIndex: Int, isPartial: Bool)] = []
    var partialTargetIndex: Int = -1
    var partialTranslationTimer: Task<Void, Never>? = nil
    var config: TranslationSession.Configuration? = nil

    mutating func reset() {
        queue = []
        partialTargetIndex = -1
        partialTranslationTimer?.cancel()
        partialTranslationTimer = nil
        config = nil
    }
}

@Observable
@MainActor
final class SessionViewModel {
    // MARK: - Published State

    var sourceLines: [TranscriptLine] = []
    /// Translation slots — one per target language (1 in dual/subtitle mode, 2-3 in multi mode).
    var translationSlots: [TranslationSlot] = [TranslationSlot()]
    var isSessionActive = false
    var fontSize: CGFloat = 16
    var isAlwaysOnTop = true
    var errorMessage: String?
    var showSettings = false
    var displayMode: DisplayMode = {
        if let raw = UserDefaults.standard.string(forKey: "displayMode"),
           let mode = DisplayMode(rawValue: raw),
           mode != .subtitle {  // Don't restore subtitle mode on launch (requires active session)
            return mode
        }
        return .dual
    }() {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode") }
    }
    var permissionIssue: PermissionIssue?

    /// Custom vocabulary words per source locale, keyed by locale identifier (persisted via UserDefaults).
    var contextualStringsByLocale: [String: [String]] = {
        guard let data = UserDefaults.standard.data(forKey: "contextualStringsByLocale"),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return dict
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(contextualStringsByLocale) {
                UserDefaults.standard.set(data, forKey: "contextualStringsByLocale")
            }
        }
    }

    /// Convenience accessor for the current source locale's vocabulary.
    var currentContextualStrings: [String] {
        get { contextualStringsByLocale[sourceLocaleIdentifier] ?? [] }
        set { contextualStringsByLocale[sourceLocaleIdentifier] = newValue }
    }

    /// Auto-replacement rules per source locale, keyed by locale identifier (persisted via UserDefaults).
    var autoReplacementsByLocale: [String: [AutoReplacement]] = {
        guard let data = UserDefaults.standard.data(forKey: "autoReplacementsByLocale"),
              let dict = try? JSONDecoder().decode([String: [AutoReplacement]].self, from: data) else {
            return [:]
        }
        return dict
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(autoReplacementsByLocale) {
                UserDefaults.standard.set(data, forKey: "autoReplacementsByLocale")
            }
        }
    }

    /// Convenience accessor for the current source locale's auto-replacement rules.
    var currentAutoReplacements: [AutoReplacement] {
        get { autoReplacementsByLocale[sourceLocaleIdentifier] ?? [] }
        set { autoReplacementsByLocale[sourceLocaleIdentifier] = newValue }
    }

    /// Applies auto-replacement rules to the given text.
    func applyAutoReplacements(_ text: String) -> String {
        var result = text
        for rule in currentAutoReplacements {
            guard !rule.from.isEmpty else { continue }
            result = result.replacingOccurrences(of: rule.from, with: rule.to)
        }
        return result
    }

    /// Rolling audio level samples for waveform visualization (0.0–1.0).
    var audioLevels: [Float] = Array(repeating: 0, count: 20)

    // Language selection stored as String identifiers for reliable Picker binding.
    // Persisted via UserDefaults so the last-used languages are restored on relaunch.
    var sourceLocaleIdentifier: String = UserDefaults.standard.string(forKey: "sourceLocaleIdentifier") ?? "ja_JP" {
        didSet { UserDefaults.standard.set(sourceLocaleIdentifier, forKey: "sourceLocaleIdentifier") }
    }
    var targetLanguageIdentifier: String = UserDefaults.standard.string(forKey: "targetLanguageIdentifier") ?? "en" {
        didSet { UserDefaults.standard.set(targetLanguageIdentifier, forKey: "targetLanguageIdentifier") }
    }

    var supportedSourceLocales: [Locale] = []
    var supportedTargetLanguages: [Locale.Language] = []

    // Microphone selection
    var availableMicrophones: [AVCaptureDevice] = []
    var selectedMicrophoneID: String = ""  // empty = system default

    // MARK: - Multi-Pane State

    /// Maximum number of target languages in multi-pane mode.
    static let maxMultiTargetCount = 3

    /// Number of active target panes in multi mode (2 or 3).
    var multiTargetCount: Int = {
        let stored = UserDefaults.standard.integer(forKey: "multiTargetCount")
        return (stored >= 2 && stored <= 3) ? stored : 2
    }() {
        didSet { UserDefaults.standard.set(multiTargetCount, forKey: "multiTargetCount") }
    }

    /// Target language identifiers for multi-pane mode (up to 3 slots).
    var multiTargetLanguageIdentifiers: [String] = {
        if let stored = UserDefaults.standard.array(forKey: "multiTargetLanguageIdentifiers") as? [String], stored.count >= 3 {
            return stored
        }
        return ["en", "zh-Hans", "ko"]
    }() {
        didSet { UserDefaults.standard.set(multiTargetLanguageIdentifiers, forKey: "multiTargetLanguageIdentifiers") }
    }

    // MARK: - Computed Properties

    /// Backward-compatible accessor for the primary (or only) target lines.
    var targetLines: [TranscriptLine] {
        get { translationSlots.isEmpty ? [] : translationSlots[0].lines }
        set { if !translationSlots.isEmpty { translationSlots[0].lines = newValue } }
    }

    /// Backward-compatible accessor for multi-pane target lines.
    var multiTargetLines: [[TranscriptLine]] {
        get { translationSlots.map(\.lines) }
        set {
            for i in 0..<min(newValue.count, translationSlots.count) {
                translationSlots[i].lines = newValue[i]
            }
        }
    }

    /// Backward-compatible accessor for the single-pane translation config.
    var translationConfig: TranslationSession.Configuration? {
        get { translationSlots.isEmpty ? nil : translationSlots[0].config }
        set { if !translationSlots.isEmpty { translationSlots[0].config = newValue } }
    }

    /// Backward-compatible accessor for multi-pane translation configs.
    var multiTranslationConfigs: [TranslationSession.Configuration?] {
        get { translationSlots.map(\.config) }
        set {
            for i in 0..<min(newValue.count, translationSlots.count) {
                translationSlots[i].config = newValue[i]
            }
        }
    }

    /// Number of active translation slots based on current display mode.
    var activeSlotCount: Int {
        displayMode == .multi ? multiTargetCount : 1
    }

    var sourceLocale: Locale {
        Locale(identifier: sourceLocaleIdentifier)
    }

    var targetLanguage: Locale.Language {
        Locale.Language(identifier: targetLanguageIdentifier)
    }

    /// The currently selected microphone device, or nil for system default.
    var selectedMicrophone: AVCaptureDevice? {
        if selectedMicrophoneID.isEmpty { return nil }
        return availableMicrophones.first { $0.uniqueID == selectedMicrophoneID }
    }

    // MARK: - Private State

    private let transcriptionManager = TranscriptionManager()
    private var transcriptionTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?
    private var sentenceBoundaryTimer: Task<Void, Never>?
    private var pendingSentenceBuffer = ""
    private var sessionStartDate: Date?
    private var segmentIndex = 0

    private static let partialTranslationDebounce: UInt64 = 300_000_000 // 0.3 seconds

    // Sentence-ending punctuation characters
    private static let sentenceEndChars: Set<Character> = [".", "。", "!", "?", "！", "？"]
    private static let sentenceBoundaryTimeout: UInt64 = 3_000_000_000 // 3 seconds in nanoseconds

    // MARK: - Lifecycle

    func refreshMicrophones() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        availableMicrophones = discoverySession.devices
        logger.info("Found \(self.availableMicrophones.count) microphone(s)")

        // If the selected device disappeared, reset to default
        if !selectedMicrophoneID.isEmpty,
           !availableMicrophones.contains(where: { $0.uniqueID == selectedMicrophoneID }) {
            logger.info("Selected microphone no longer available, resetting to default")
            selectedMicrophoneID = ""
        }
    }

    func loadSupportedLocales() async {
        logger.info("Loading supported locales...")
        supportedSourceLocales = await SpeechTranscriber.supportedLocales
        logger.info("Found \(self.supportedSourceLocales.count) supported source locales")
        await updateTargetLanguages()

        // Ensure initial selection is valid
        if !supportedSourceLocales.contains(where: { $0.identifier == sourceLocaleIdentifier }) {
            if let first = supportedSourceLocales.first {
                logger.info("Initial source locale '\(self.sourceLocaleIdentifier)' not available, defaulting to '\(first.identifier)'")
                sourceLocaleIdentifier = first.identifier
            }
        }
        logger.info("Source locale: \(self.sourceLocaleIdentifier), Target language: \(self.targetLanguageIdentifier)")
    }

    // MARK: - Permission Checks

    /// Checks microphone and speech recognition permissions, returning false if denied.
    private func checkPermissions() async -> Bool {
        // Check microphone access
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                logger.warning("Microphone access denied by user")
                permissionIssue = .microphone
                return false
            }
        case .denied, .restricted:
            logger.warning("Microphone access denied (status: \(micStatus.rawValue))")
            permissionIssue = .microphone
            return false
        case .authorized:
            break
        @unknown default:
            break
        }

        // Check speech recognition access
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        switch speechStatus {
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            if !granted {
                logger.warning("Speech recognition access denied by user")
                permissionIssue = .speechRecognition
                return false
            }
        case .denied, .restricted:
            logger.warning("Speech recognition access denied (status: \(speechStatus.rawValue))")
            permissionIssue = .speechRecognition
            return false
        case .authorized:
            break
        @unknown default:
            break
        }

        return true
    }

    /// Opens the Privacy & Security section in System Settings.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Session Control

    func startSession() async {
        // Ensure any previous session is fully torn down before starting a new one
        if isSessionActive {
            await stopSession()
        }

        logger.info("Starting session: source=\(self.sourceLocaleIdentifier), target=\(self.targetLanguageIdentifier)")

        // Verify permissions before proceeding
        guard await checkPermissions() else {
            logger.info("Session start aborted: missing permissions")
            return
        }

        errorMessage = nil

        // Remove any leftover partial lines from the previous session
        sourceLines.removeAll { $0.isPartial }
        for slot in 0..<translationSlots.count {
            translationSlots[slot].lines.removeAll { $0.isPartial }
        }

        // Insert a separator if there is previous history
        if !sourceLines.isEmpty {
            let separator = TranscriptLine(text: "", isPartial: false, isSeparator: true)
            sourceLines.append(separator)
            for slot in 0..<translationSlots.count {
                translationSlots[slot].lines.append(separator)
            }
        }

        pendingSentenceBuffer = ""
        segmentIndex = 0
        sessionStartDate = Date()

        // Initialize translation slots based on display mode
        let slotCount = activeSlotCount
        let previousSlots = translationSlots
        translationSlots = (0..<slotCount).map { i in
            var slot = TranslationSlot()
            // Preserve existing lines (history) from previous slots if available
            if i < previousSlots.count {
                slot.lines = previousSlots[i].lines
            }
            let targetLang: Locale.Language
            if displayMode == .multi {
                targetLang = Locale.Language(identifier: multiTargetLanguageIdentifiers[i])
            } else {
                targetLang = targetLanguage
            }
            slot.config = TranslationSession.Configuration(
                source: sourceLocale.language,
                target: targetLang
            )
            logger.debug("Translation config created for slot \(i): \(self.sourceLocale.language.minimalIdentifier) → \(targetLang.minimalIdentifier)")
            return slot
        }

        isSessionActive = true

        transcriptionTask = Task {
            do {
                logger.info("Starting transcription manager...")
                let events = try await transcriptionManager.start(locale: sourceLocale, audioDevice: selectedMicrophone, contextualStrings: currentContextualStrings)

                // Start consuming audio levels for waveform display
                if let levelStream = await transcriptionManager.audioLevelStream {
                    audioLevelTask = Task {
                        for await level in levelStream {
                            audioLevels.append(level)
                            if audioLevels.count > 20 {
                                audioLevels.removeFirst(audioLevels.count - 20)
                            }
                        }
                    }
                }

                logger.info("Transcription started, consuming events...")
                for await event in events {
                    handleTranscriptionEvent(event)
                }
                logger.info("Event stream ended")
            } catch {
                logger.error("Session error: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
                isSessionActive = false
            }
        }
    }

    func stopSession() async {
        guard isSessionActive else {
            logger.debug("stopSession called but not active")
            return
        }

        logger.info("Stopping session...")

        transcriptionTask?.cancel()
        transcriptionTask = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
        sentenceBoundaryTimer?.cancel()
        sentenceBoundaryTimer = nil

        // Flush any remaining buffer
        if !pendingSentenceBuffer.isEmpty {
            logger.debug("Flushing pending buffer: \"\(self.pendingSentenceBuffer)\"")
            commitSentence(pendingSentenceBuffer)
            pendingSentenceBuffer = ""
        }

        // Await full teardown so the microphone is released before any restart
        await transcriptionManager.stop()

        isSessionActive = false
        for slot in 0..<translationSlots.count {
            translationSlots[slot].reset()
        }
        audioLevels = Array(repeating: 0, count: 20)
        logger.info("Session stopped (source lines: \(self.sourceLines.count), target lines: \(self.targetLines.count))")
    }

    func toggleSession() {
        Task {
            if isSessionActive {
                await stopSession()
            } else {
                await startSession()
            }
        }
    }

    // MARK: - Language Control

    func swapLanguages() {
        guard !isSessionActive else { return }

        let oldSourceIdentifier = sourceLocaleIdentifier
        let oldSourceLangCode = sourceLocale.language.languageCode
        let oldTargetIdentifier = targetLanguageIdentifier

        logger.info("swapLanguages: oldSource='\(oldSourceIdentifier)' (langCode=\(oldSourceLangCode?.identifier ?? "nil")), oldTarget='\(oldTargetIdentifier)'")

        // Find a source locale matching the old target language.
        // Prefer: exact identifier match → user's region → no region → first match
        let targetLang = Locale.Language(identifier: oldTargetIdentifier)
        let targetLangCode = targetLang.languageCode
        logger.info("swapLanguages: targetLang parsed: languageCode=\(targetLangCode?.identifier ?? "nil"), region=\(targetLang.region?.identifier ?? "nil")")

        let candidates = supportedSourceLocales.filter {
            $0.language.languageCode == targetLangCode
        }
        logger.info("swapLanguages: candidates=[\(candidates.map(\.identifier).joined(separator: ", "))]")

        let userRegion = Locale.current.region
        logger.info("swapLanguages: userRegion=\(userRegion?.identifier ?? "nil")")

        let likelyRegion = Self.likelyRegion(for: oldTargetIdentifier)
        logger.info("swapLanguages: likelyRegion=\(likelyRegion?.identifier ?? "nil")")

        let newSource = candidates.first(where: { $0.identifier == oldTargetIdentifier })
            ?? candidates.first(where: { $0.language.region == targetLang.region && targetLang.region != nil })
            ?? candidates.first(where: { $0.language.region == likelyRegion })
            ?? candidates.first(where: { $0.language.region == userRegion })
            ?? candidates.first(where: { $0.identifier.hasPrefix((targetLangCode?.identifier ?? "") + "_US") })
            ?? candidates.first
        if let newSource {
            logger.info("swapLanguages: selected newSource='\(newSource.identifier)'")
            sourceLocaleIdentifier = newSource.identifier
            // Use the old source language code as target
            if let code = oldSourceLangCode {
                logger.info("swapLanguages: setting targetLanguageIdentifier='\(code.identifier)'")
                targetLanguageIdentifier = code.identifier
            }
            Task {
                await updateTargetLanguages()
            }
        } else {
            logger.warning("swapLanguages: no matching source locale found for targetLangCode=\(targetLangCode?.identifier ?? "nil")")
        }

        logger.info("swapLanguages: result source='\(self.sourceLocaleIdentifier)', target='\(self.targetLanguageIdentifier)'")
    }

    func updateTargetLanguages() async {
        logger.info("updateTargetLanguages: current source='\(self.sourceLocaleIdentifier)', target='\(self.targetLanguageIdentifier)'")

        let availability = LanguageAvailability()
        let allLangs = await availability.supportedLanguages
        var available: [Locale.Language] = []
        for lang in allLangs {
            if lang.languageCode != sourceLocale.language.languageCode {
                let status = await availability.status(from: sourceLocale.language, to: lang)
                if status != .unsupported {
                    available.append(lang)
                }
            }
        }
        supportedTargetLanguages = available
        logger.info("updateTargetLanguages: \(available.count) target languages available")

        // Ensure current target is still valid
        let exactMatch = available.contains(where: { $0.minimalIdentifier == targetLanguageIdentifier })
        logger.info("updateTargetLanguages: exact match for '\(self.targetLanguageIdentifier)' in available: \(exactMatch)")

        if !exactMatch {
            // Try matching by language code only (e.g. "en" matches "en-US")
            let targetLang = Locale.Language(identifier: targetLanguageIdentifier)
            let candidates = available.filter { $0.languageCode == targetLang.languageCode }
            logger.info("updateTargetLanguages: fallback candidates for langCode=\(targetLang.languageCode?.identifier ?? "nil"): [\(candidates.map(\.minimalIdentifier).joined(separator: ", "))]")

            if let match = Self.bestLanguageMatch(from: candidates, for: targetLanguageIdentifier) {
                logger.info("updateTargetLanguages: re-mapped target '\(self.targetLanguageIdentifier)' → '\(match.minimalIdentifier)'")
                targetLanguageIdentifier = match.minimalIdentifier
            } else if let first = available.first {
                logger.info("updateTargetLanguages: no candidate match, defaulting to '\(first.minimalIdentifier)'")
                targetLanguageIdentifier = first.minimalIdentifier
            }
        }

        logger.info("updateTargetLanguages: final target='\(self.targetLanguageIdentifier)'")
    }

    // MARK: - Locale Resolution Helpers

    /// Extracts the likely region from a language identifier via its maximal form.
    /// e.g. "en" → maximalIdentifier "en-Latn-US" → Region("US")
    private static func likelyRegion(for identifier: String) -> Locale.Region? {
        let maximal = Locale.Language(identifier: identifier).maximalIdentifier
        return maximal.split(separator: "-").last.map { Locale.Region(String($0)) }
    }

    /// Picks the best match from a list of `Locale.Language` candidates, preferring
    /// user region → no region → likely default region → first available.
    private static func bestLanguageMatch(
        from candidates: [Locale.Language],
        for identifier: String
    ) -> Locale.Language? {
        let userRegion = Locale.current.region
        let likely = likelyRegion(for: identifier)
        return candidates.first(where: { $0.region == userRegion })
            ?? candidates.first(where: { $0.region == nil })
            ?? candidates.first(where: { $0.region == likely })
            ?? candidates.first
    }

    // MARK: - Font Size

    func increaseFontSize() {
        if fontSize < 32 {
            fontSize += 2
        }
    }

    func decreaseFontSize() {
        if fontSize > 12 {
            fontSize -= 2
        }
    }

    // MARK: - Translation Callback

    /// Called from the `.translationTask()` view modifier when a session is available for a given slot.
    func handleTranslationSession(_ session: TranslationSession, slot: Int) async {
        guard slot >= 0 && slot < translationSlots.count else { return }
        logger.info("Translation session available for slot \(slot), queued: \(self.translationSlots[slot].queue.count)")

        // Process queued translations using the session provided by the closure.
        // Do NOT store the session — it is only valid within this closure scope.
        // Re-check bounds after each await since translationSlots may be rebuilt.
        while slot < translationSlots.count && !translationSlots[slot].queue.isEmpty {
            let item = translationSlots[slot].queue.removeFirst()
            await translateSentence(item.sentence, using: session, slot: slot, targetIndex: item.targetIndex, isPartial: item.isPartial)
        }
    }

    // MARK: - Multi-Pane Target Management

    func addMultiTarget() {
        guard multiTargetCount < Self.maxMultiTargetCount else { return }
        multiTargetCount += 1
        // Pick a default language not already selected
        let used = Set(multiTargetLanguageIdentifiers.prefix(multiTargetCount - 1))
        if let available = supportedTargetLanguages.first(where: { !used.contains($0.minimalIdentifier) }) {
            if multiTargetLanguageIdentifiers.count < multiTargetCount {
                multiTargetLanguageIdentifiers.append(available.minimalIdentifier)
            } else {
                multiTargetLanguageIdentifiers[multiTargetCount - 1] = available.minimalIdentifier
            }
        }
    }

    func removeMultiTarget() {
        guard multiTargetCount > 2 else { return }
        multiTargetCount -= 1
    }

    // MARK: - Private Methods

    private func handleTranscriptionEvent(_ event: TranscriptionEvent) {
        switch event {
        case .partial(let rawText):
            let text = applyAutoReplacements(rawText)
            logger.debug("Event: partial \"\(rawText)\" → \"\(text)\"")
            // Remove old partial line and add new one
            if let lastIndex = sourceLines.indices.last, sourceLines[lastIndex].isPartial {
                sourceLines[lastIndex] = TranscriptLine(text: text, isPartial: true)
            } else {
                sourceLines.append(TranscriptLine(text: text, isPartial: true))
            }

            // Request partial translation (debounced)
            requestPartialTranslation(for: pendingSentenceBuffer + text)

        case .final_(let rawText):
            let text = applyAutoReplacements(rawText)
            logger.info("Event: final \"\(rawText)\" → \"\(text)\"")
            // Cancel any pending partial translation timers
            for slot in 0..<translationSlots.count {
                translationSlots[slot].partialTranslationTimer?.cancel()
                translationSlots[slot].partialTranslationTimer = nil
            }

            // Remove partial line if present
            if let lastIndex = sourceLines.indices.last, sourceLines[lastIndex].isPartial {
                sourceLines.removeLast()
            }

            // Append finalized text
            sourceLines.append(TranscriptLine(text: text, isPartial: false))

            // Add to sentence buffer and check for boundaries
            pendingSentenceBuffer += text
            checkSentenceBoundary()

        case .error(let message):
            logger.error("Event: error \"\(message)\"")
            errorMessage = message
        }
    }

    private func checkSentenceBoundary() {
        // Check if the buffer ends with sentence-ending punctuation
        if let lastChar = pendingSentenceBuffer.last, Self.sentenceEndChars.contains(lastChar) {
            let sentence = pendingSentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingSentenceBuffer = ""
            commitSentence(sentence)
        } else {
            // Reset the silence timer
            resetSentenceBoundaryTimer()
        }
    }

    private func resetSentenceBoundaryTimer() {
        sentenceBoundaryTimer?.cancel()
        sentenceBoundaryTimer = Task {
            try? await Task.sleep(nanoseconds: Self.sentenceBoundaryTimeout)
            guard !Task.isCancelled else { return }
            if !pendingSentenceBuffer.isEmpty {
                let sentence = pendingSentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                pendingSentenceBuffer = ""
                commitSentence(sentence)
            }
        }
    }

    private func requestPartialTranslation(for text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        for slot in 0..<activeSlotCount {
            requestPartialTranslationForSlot(slot, text: trimmed)
        }
    }

    private func requestPartialTranslationForSlot(_ slot: Int, text: String) {
        guard slot < translationSlots.count else { return }
        translationSlots[slot].partialTranslationTimer?.cancel()
        let capturedSlot = slot
        translationSlots[slot].partialTranslationTimer = Task {
            try? await Task.sleep(nanoseconds: Self.partialTranslationDebounce)
            guard !Task.isCancelled, capturedSlot < translationSlots.count else { return }

            // Create or update the partial target line
            let pIdx = translationSlots[capturedSlot].partialTargetIndex
            if pIdx >= 0 && pIdx < translationSlots[capturedSlot].lines.count
                && translationSlots[capturedSlot].lines[pIdx].isPartial {
                // Reuse existing partial line
            } else {
                translationSlots[capturedSlot].lines.append(TranscriptLine(text: "…", isPartial: true))
                translationSlots[capturedSlot].partialTargetIndex = translationSlots[capturedSlot].lines.count - 1
            }

            let idx = translationSlots[capturedSlot].partialTargetIndex
            logger.debug("Queuing partial translation slot \(capturedSlot) (targetIndex: \(idx)): \"\(text)\"")
            translationSlots[capturedSlot].queue.append((sentence: text, targetIndex: idx, isPartial: true))
            translationSlots[capturedSlot].config?.invalidate()
        }
    }

    private func commitSentence(_ sentence: String) {
        guard !sentence.isEmpty else { return }

        segmentIndex += 1
        logger.info("Committing sentence #\(self.segmentIndex): \"\(sentence)\"")

        for slot in 0..<activeSlotCount {
            commitSentenceForSlot(slot, sentence: sentence)
        }
    }

    private func commitSentenceForSlot(_ slot: Int, sentence: String) {
        guard slot < translationSlots.count else { return }
        translationSlots[slot].partialTranslationTimer?.cancel()
        translationSlots[slot].partialTranslationTimer = nil

        let pIdx = translationSlots[slot].partialTargetIndex
        if pIdx >= 0 && pIdx < translationSlots[slot].lines.count
            && translationSlots[slot].lines[pIdx].isPartial {
            // Reuse the partial line as placeholder for the final translation
            let targetIndex = pIdx
            translationSlots[slot].partialTargetIndex = -1
            logger.debug("Reusing partial line for final translation (slot: \(slot), targetIndex: \(targetIndex))")
            translationSlots[slot].queue.append((sentence: sentence, targetIndex: targetIndex, isPartial: false))
            translationSlots[slot].config?.invalidate()
        } else {
            // Add placeholder to target pane
            translationSlots[slot].lines.append(TranscriptLine(text: "…", isPartial: true))
            let targetIndex = translationSlots[slot].lines.count - 1
            translationSlots[slot].partialTargetIndex = -1
            logger.debug("Queuing for translation (slot: \(slot), targetIndex: \(targetIndex))")
            translationSlots[slot].queue.append((sentence: sentence, targetIndex: targetIndex, isPartial: false))
            translationSlots[slot].config?.invalidate()
        }
    }

    private func translateSentence(_ sentence: String, using session: TranslationSession, slot: Int, targetIndex: Int, isPartial: Bool) async {
        logger.debug("Translating slot \(slot) (\(isPartial ? "partial" : "final")): \"\(sentence)\"")
        do {
            let response = try await session.translate(sentence)
            logger.info("Slot \(slot) translation result (\(isPartial ? "partial" : "final")): \"\(response.targetText)\"")
            // Re-check slot bounds after await since translationSlots may have been rebuilt
            guard slot < translationSlots.count,
                  targetIndex >= 0 && targetIndex < translationSlots[slot].lines.count else { return }
            // For partial translations, only update if the line is still partial
            // (a final translation may have already replaced it)
            if isPartial {
                if translationSlots[slot].lines[targetIndex].isPartial {
                    translationSlots[slot].lines[targetIndex] = TranscriptLine(text: response.targetText, isPartial: true)
                }
            } else {
                translationSlots[slot].lines[targetIndex] = TranscriptLine(text: response.targetText, isPartial: false, finalizedAt: Date())
            }
        } catch {
            logger.error("Slot \(slot) translation failed: \(error.localizedDescription)")
            // Only show error for final translations; silently ignore partial failures
            if !isPartial {
                if slot < translationSlots.count,
                   targetIndex >= 0 && targetIndex < translationSlots[slot].lines.count {
                    translationSlots[slot].lines[targetIndex] = TranscriptLine(text: "[Translation failed]", isPartial: false, finalizedAt: Date())
                }
            }
        }
    }

    // MARK: - Save / Export

    enum SaveContentType {
        case original
        case translation
        case both
    }

    /// Presents an NSSavePanel and writes the selected content to a text file.
    func saveTranscript(contentType: SaveContentType) {
        let content: String
        switch contentType {
        case .original:
            content = copyAllOriginal()
        case .translation:
            content = copyAllTranslation()
        case .both:
            content = copyAllInterleaved()
        }

        guard !content.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = defaultFileName(for: contentType)
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            logger.info("Transcript saved to \(url.path)")
        } catch {
            logger.error("Failed to save transcript: \(error.localizedDescription)")
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func defaultFileName(for contentType: SaveContentType) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let suffix: String
        switch contentType {
        case .original: suffix = "original"
        case .translation: suffix = "translation"
        case .both: suffix = "interleaved"
        }
        return "TransTrans_\(timestamp)_\(suffix).txt"
    }

    // MARK: - Copy / Export Helpers

    func clearHistory() {
        sourceLines = []
        for slot in 0..<translationSlots.count {
            translationSlots[slot].lines = []
        }
    }

    func copyAllOriginal() -> String {
        sourceLines.finalizedLines.map(\.text).joined(separator: "\n")
    }

    func copyAllTranslation() -> String {
        if displayMode == .multi {
            var result: [String] = []
            let targets = multiTargetLines
            for slot in 0..<min(multiTargetCount, targets.count) {
                let langId = slot < multiTargetLanguageIdentifiers.count
                    ? multiTargetLanguageIdentifiers[slot].uppercased() : "?"
                result.append("[\(langId)]")
                result.append(contentsOf: targets[slot].finalizedLines.map(\.text))
                result.append("")
            }
            return result.joined(separator: "\n")
        }
        return targetLines.finalizedLines.map(\.text).joined(separator: "\n")
    }

    func copyAllInterleaved() -> String {
        let finalSource = sourceLines.finalizedLines

        if displayMode == .multi {
            var result: [String] = []
            let targets = multiTargetLines
            let safeCount = min(multiTargetCount, targets.count)
            let multiTargets = (0..<safeCount).map { slot in
                targets[slot].finalizedLines
            }
            let maxCount = ([finalSource.count] + multiTargets.map(\.count)).max() ?? 0
            for i in 0..<maxCount {
                if i < finalSource.count {
                    result.append(finalSource[i].text)
                }
                for slot in 0..<safeCount {
                    if i < multiTargets[slot].count {
                        result.append(multiTargets[slot][i].text)
                    }
                }
                result.append("")
            }
            return result.joined(separator: "\n")
        }

        var result: [String] = []
        let finalTarget = targetLines.finalizedLines
        let count = max(finalSource.count, finalTarget.count)
        for i in 0..<count {
            if i < finalSource.count {
                result.append(finalSource[i].text)
            }
            if i < finalTarget.count {
                result.append(finalTarget[i].text)
            }
            result.append("")
        }
        return result.joined(separator: "\n")
    }
}
