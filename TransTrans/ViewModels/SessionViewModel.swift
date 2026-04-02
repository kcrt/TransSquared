import SwiftUI
import Speech
import Translation
import AVFoundation
import os

private let logger = Logger.app("Session")

@Observable
@MainActor
final class SessionViewModel {
    // MARK: - Published State

    var sourceLines: [TranscriptLine] = []
    /// Translation slots — one per target language (always `targetCount` active slots).
    var translationSlots: [TranslationSlot] = [TranslationSlot()]
    var isSessionActive = false
    var fontSize: CGFloat = 16
    var isAlwaysOnTop = false
    var errorMessage: String?
    var showSettings = false
    var displayMode: DisplayMode = .normal
    var permissionIssue: PermissionIssue?

    // MARK: - File Export State
    var isExporterPresented = false
    var exportContent: String?
    var exportDefaultFilename = ""

    /// Custom vocabulary words per source locale, keyed by locale identifier (persisted via UserDefaults).
    var contextualStringsByLocale: [String: [String]] = SessionViewModel.loadFromUserDefaults(forKey: "contextualStringsByLocale") ?? [:] {
        didSet { persistToUserDefaults(contextualStringsByLocale, forKey: "contextualStringsByLocale") }
    }

    /// Convenience accessor for the current source locale's vocabulary.
    var currentContextualStrings: [String] {
        get { contextualStringsByLocale[sourceLocaleIdentifier] ?? [] }
        set { contextualStringsByLocale[sourceLocaleIdentifier] = newValue }
    }

    /// Auto-replacement rules per source locale, keyed by locale identifier (persisted via UserDefaults).
    var autoReplacementsByLocale: [String: [AutoReplacement]] = SessionViewModel.loadFromUserDefaults(forKey: "autoReplacementsByLocale") ?? [:] {
        didSet { persistToUserDefaults(autoReplacementsByLocale, forKey: "autoReplacementsByLocale") }
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
    /// Convenience accessor for the primary target language (slot 0 of `targetLanguageIdentifiers`).
    var targetLanguageIdentifier: String {
        get { targetLanguageIdentifiers[0] }
        set { targetLanguageIdentifiers[0] = newValue }
    }

    var supportedSourceLocales: [Locale] = []
    var supportedTargetLanguages: [Locale.Language] = []

    // Microphone selection
    var availableMicrophones: [AVCaptureDevice] = []
    var selectedMicrophoneID: String = ""  // empty = system default

    // MARK: - Target Language Count

    /// Maximum number of target languages.
    static let maxTargetCount = 5

    /// Number of active target panes (1, 2, or 3).
    var targetCount: Int = {
        let stored = UserDefaults.standard.integer(forKey: "targetCount")
        if stored >= 1 && stored <= 3 { return stored }
        return 1
    }() {
        didSet { UserDefaults.standard.set(targetCount, forKey: "targetCount") }
    }

    /// Target language identifiers for all slots (always 3 elements; only first `targetCount` are active).
    var targetLanguageIdentifiers: [String] = {
        if let stored = UserDefaults.standard.array(forKey: "targetLanguageIdentifiers") as? [String], stored.count >= 3 {
            return stored
        }
        return ["en", "zh-Hans", "ko"]
    }() {
        didSet { UserDefaults.standard.set(targetLanguageIdentifiers, forKey: "targetLanguageIdentifiers") }
    }

    // MARK: - Computed Properties

    /// Whether there is any transcript content (source or translation) to export or clear.
    var hasTranscriptContent: Bool {
        !sourceLines.isEmpty || translationSlots.first?.lines.isEmpty == false
    }

    var sourceLocale: Locale {
        Locale(identifier: sourceLocaleIdentifier)
    }

    /// The currently selected microphone device, or nil for system default.
    var selectedMicrophone: AVCaptureDevice? {
        if selectedMicrophoneID.isEmpty { return nil }
        return availableMicrophones.first { $0.uniqueID == selectedMicrophoneID }
    }

    // MARK: - Internal State (accessed by extensions)

    let transcriptionManager = TranscriptionManager()
    var transcriptionTask: Task<Void, Never>?
    var audioLevelTask: Task<Void, Never>?
    var sentenceBoundaryTimer: Task<Void, Never>?
    var pendingSentenceBuffer = ""
    var sessionStartDate: Date?
    var segmentIndex = 0

    static let partialTranslationDebounce: UInt64 = 300_000_000 // 0.3 seconds

    // Sentence-ending punctuation characters
    static let sentenceEndChars: Set<Character> = [".", "。", "!", "?", "！", "？"]
    static let sentenceBoundaryTimeout: UInt64 = 3_000_000_000 // 3 seconds in nanoseconds

    // MARK: - Device Monitoring

    /// Persistent discovery session kept alive for KVO observation of device changes.
    private var microphoneDiscoverySession: AVCaptureDevice.DiscoverySession?
    private var deviceObservation: NSKeyValueObservation?

    // MARK: - Lifecycle

    /// Refreshes the microphone list and starts monitoring for device changes (connect/disconnect).
    func refreshMicrophones() {
        // Create a persistent discovery session if not already set up
        if microphoneDiscoverySession == nil {
            let session = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone],
                mediaType: .audio,
                position: .unspecified
            )
            microphoneDiscoverySession = session

            // Observe device list changes via KVO
            deviceObservation = session.observe(\.devices, options: [.new]) { [weak self] discoverySession, _ in
                let devices = discoverySession.devices
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.availableMicrophones = devices
                    logger.info("Microphone list updated: \(devices.count) device(s)")

                    // If the selected device disappeared, reset to default
                    if !self.selectedMicrophoneID.isEmpty,
                       !devices.contains(where: { $0.uniqueID == self.selectedMicrophoneID }) {
                        logger.info("Selected microphone disconnected, resetting to default")
                        let wasActive = self.isSessionActive
                        self.selectedMicrophoneID = ""

                        // Stop the active session since the device is gone
                        if wasActive {
                            logger.warning("Active microphone disconnected during session, stopping")
                            await self.stopSession()
                            self.errorMessage = String(
                                localized: "Microphone was disconnected. The session has been stopped.",
                                comment: "Error shown when the active microphone is unplugged during a session"
                            )
                        }
                    }
                }
            }
        }

        availableMicrophones = microphoneDiscoverySession?.devices ?? []
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
            logger.warning("Unknown microphone authorization status: \(micStatus.rawValue)")
            permissionIssue = .microphone
            return false
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
            logger.warning("Unknown speech recognition authorization status: \(speechStatus.rawValue)")
            permissionIssue = .speechRecognition
            return false
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
        let slotCount = targetCount
        let previousSlots = translationSlots
        translationSlots = (0..<slotCount).map { i in
            var slot = TranslationSlot()
            // Preserve existing lines (history) from previous slots if available
            if i < previousSlots.count {
                slot.lines = previousSlots[i].lines
            }
            let targetLang = Locale.Language(identifier: targetLanguageIdentifiers[i])
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
        logger.info("Session stopped (source lines: \(self.sourceLines.count), target lines: \(self.translationSlots[0].lines.count))")
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
        // Sort by localized display name for a user-friendly order
        available.sort { lhs, rhs in
            let lhsName = Locale.current.localizedString(forIdentifier: lhs.minimalIdentifier) ?? lhs.minimalIdentifier
            let rhsName = Locale.current.localizedString(forIdentifier: rhs.minimalIdentifier) ?? rhs.minimalIdentifier
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
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

    // MARK: - Display Mode

    func toggleDisplayMode() {
        if displayMode == .subtitle {
            displayMode = .normal
        } else if isSessionActive && targetCount <= 1 {
            displayMode = .subtitle
        }
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

    // MARK: - UserDefaults Helpers

    private static func loadFromUserDefaults<T: Codable>(forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func persistToUserDefaults<T: Codable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
