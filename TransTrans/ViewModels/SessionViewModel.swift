import SwiftUI
import SwiftData
import Speech
import Translation
import AVFoundation
import os

private let logger = Logger(subsystem: "com.transtrans", category: "Session")

/// A single line of transcribed/translated text displayed in the UI.
struct TranscriptLine: Identifiable {
    let id = UUID()
    var text: String
    var isPartial: Bool
}

@Observable
@MainActor
final class SessionViewModel {
    // MARK: - Published State

    var sourceLines: [TranscriptLine] = []
    var targetLines: [TranscriptLine] = []
    var isSessionActive = false
    var fontSize: CGFloat = 16
    var isAlwaysOnTop = true
    var errorMessage: String?
    var showSettings = false

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

    // Translation configuration — triggers .translationTask() when invalidated
    var translationConfig: TranslationSession.Configuration?

    // MARK: - Computed Properties

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

    // Queue of (sentence, targetLineIndex, isPartial) tuples awaiting translation
    private var translationQueue: [(sentence: String, targetIndex: Int, isPartial: Bool)] = []

    // Index of the current partial translation line in targetLines (-1 = none)
    private var partialTargetIndex: Int = -1
    // Debounce timer for partial translations
    private var partialTranslationTimer: Task<Void, Never>?
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

    // MARK: - Session Control

    func startSession() async {
        // Ensure any previous session is fully torn down before starting a new one
        if isSessionActive {
            await stopSession()
        }

        logger.info("Starting session: source=\(self.sourceLocaleIdentifier), target=\(self.targetLanguageIdentifier)")

        errorMessage = nil
        sourceLines = []
        targetLines = []
        pendingSentenceBuffer = ""
        segmentIndex = 0
        sessionStartDate = Date()
        translationQueue = []
        partialTargetIndex = -1
        partialTranslationTimer?.cancel()
        partialTranslationTimer = nil

        isSessionActive = true

        // Set up translation config
        translationConfig = TranslationSession.Configuration(
            source: sourceLocale.language,
            target: targetLanguage
        )
        logger.debug("Translation config created: \(self.sourceLocale.language.minimalIdentifier) → \(self.targetLanguage.minimalIdentifier)")

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
        partialTranslationTimer?.cancel()
        partialTranslationTimer = nil

        // Flush any remaining buffer
        if !pendingSentenceBuffer.isEmpty {
            logger.debug("Flushing pending buffer: \"\(self.pendingSentenceBuffer)\"")
            commitSentence(pendingSentenceBuffer)
            pendingSentenceBuffer = ""
        }

        // Await full teardown so the microphone is released before any restart
        await transcriptionManager.stop()

        isSessionActive = false
        translationConfig = nil
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

        // For languages like "en" with no region, prefer the likely default locale (e.g. en_US for "en")
        let likelyLocaleID = Locale.Language(identifier: oldTargetIdentifier).maximalIdentifier
            // maximalIdentifier returns e.g. "en-Latn-US" → extract region
        let likelyRegionStr = likelyLocaleID.split(separator: "-").last.map(String.init)
        let likelyRegion = likelyRegionStr.map { Locale.Region($0) }
        logger.info("swapLanguages: likelyLocaleID='\(likelyLocaleID)', likelyRegion=\(likelyRegion?.identifier ?? "nil")")

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

            // Prefer: exact region match with user locale → no region → likely default region → first
            let userRegion = Locale.current.region
            let likelyRegion = Locale.Language(identifier: targetLanguageIdentifier).maximalIdentifier
                .split(separator: "-").last.map { Locale.Region(String($0)) }
            logger.info("updateTargetLanguages: userRegion=\(userRegion?.identifier ?? "nil"), likelyRegion=\(likelyRegion?.identifier ?? "nil")")

            if let match = candidates.first(where: { $0.region == userRegion })
                ?? candidates.first(where: { $0.region == nil })
                ?? candidates.first(where: { $0.region == likelyRegion })
                ?? candidates.first {
                logger.info("updateTargetLanguages: re-mapped target '\(self.targetLanguageIdentifier)' → '\(match.minimalIdentifier)'")
                targetLanguageIdentifier = match.minimalIdentifier
            } else if let first = available.first {
                logger.info("updateTargetLanguages: no candidate match, defaulting to '\(first.minimalIdentifier)'")
                targetLanguageIdentifier = first.minimalIdentifier
            }
        }

        logger.info("updateTargetLanguages: final target='\(self.targetLanguageIdentifier)'")
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

    /// Called from the `.translationTask()` view modifier when a session is available.
    func handleTranslationSession(_ session: TranslationSession) async {
        logger.info("Translation session available, queued translations: \(self.translationQueue.count)")

        // Process queued translations using the session provided by the closure.
        // Do NOT store the session — it is only valid within this closure scope.
        while !translationQueue.isEmpty {
            let item = translationQueue.removeFirst()
            await translateSentence(item.sentence, using: session, targetIndex: item.targetIndex, isPartial: item.isPartial)
        }
    }

    // MARK: - Private Methods

    private func handleTranscriptionEvent(_ event: TranscriptionEvent) {
        switch event {
        case .partial(let text):
            logger.debug("Event: partial \"\(text)\"")
            // Remove old partial line and add new one
            if let lastIndex = sourceLines.indices.last, sourceLines[lastIndex].isPartial {
                sourceLines[lastIndex] = TranscriptLine(text: text, isPartial: true)
            } else {
                sourceLines.append(TranscriptLine(text: text, isPartial: true))
            }

            // Request partial translation (debounced)
            requestPartialTranslation(for: pendingSentenceBuffer + text)

        case .final_(let text):
            logger.info("Event: final \"\(text)\"")
            // Cancel any pending partial translation
            partialTranslationTimer?.cancel()
            partialTranslationTimer = nil

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

        // Debounce: cancel previous timer and start a new one
        partialTranslationTimer?.cancel()
        partialTranslationTimer = Task {
            try? await Task.sleep(nanoseconds: Self.partialTranslationDebounce)
            guard !Task.isCancelled else { return }

            // Create or update the partial target line
            if partialTargetIndex >= 0 && partialTargetIndex < targetLines.count && targetLines[partialTargetIndex].isPartial {
                // Reuse existing partial line — update text to show we're translating
            } else {
                // Add a new partial line
                targetLines.append(TranscriptLine(text: "…", isPartial: true))
                partialTargetIndex = targetLines.count - 1
            }

            // Queue partial translation
            let idx = partialTargetIndex
            logger.debug("Queuing partial translation (targetIndex: \(idx)): \"\(trimmed)\"")
            translationQueue.append((sentence: trimmed, targetIndex: idx, isPartial: true))
            translationConfig?.invalidate()
        }
    }

    private func commitSentence(_ sentence: String) {
        guard !sentence.isEmpty else { return }

        segmentIndex += 1
        logger.info("Committing sentence #\(self.segmentIndex): \"\(sentence)\"")

        // If there's a partial translation line, reuse it for the final translation
        if partialTargetIndex >= 0 && partialTargetIndex < targetLines.count && targetLines[partialTargetIndex].isPartial {
            // Reuse the partial line as placeholder for the final translation
            targetLines[partialTargetIndex] = TranscriptLine(text: targetLines[partialTargetIndex].text, isPartial: true)
            let targetIndex = partialTargetIndex
            partialTargetIndex = -1
            logger.debug("Reusing partial line for final translation (targetIndex: \(targetIndex))")
            translationQueue.append((sentence: sentence, targetIndex: targetIndex, isPartial: false))
            translationConfig?.invalidate()
        } else {
            // Add placeholder to target pane
            targetLines.append(TranscriptLine(text: "…", isPartial: true))
            let targetIndex = targetLines.count - 1
            partialTargetIndex = -1
            logger.debug("Queuing for translation (targetIndex: \(targetIndex))")
            translationQueue.append((sentence: sentence, targetIndex: targetIndex, isPartial: false))
            translationConfig?.invalidate()
        }
    }

    private func translateSentence(_ sentence: String, using session: TranslationSession, targetIndex: Int? = nil, isPartial: Bool = false) async {
        logger.debug("Translating (\(isPartial ? "partial" : "final")): \"\(sentence)\"")
        do {
            let response = try await session.translate(sentence)
            logger.info("Translation result (\(isPartial ? "partial" : "final")): \"\(response.targetText)\"")
            let idx = targetIndex ?? (targetLines.count - 1)
            if idx >= 0 && idx < targetLines.count {
                // For partial translations, only update if the line is still partial
                // (a final translation may have already replaced it)
                if isPartial {
                    if targetLines[idx].isPartial {
                        targetLines[idx] = TranscriptLine(text: response.targetText, isPartial: true)
                    }
                } else {
                    targetLines[idx] = TranscriptLine(text: response.targetText, isPartial: false)
                }
            }
        } catch {
            logger.error("Translation failed: \(error.localizedDescription)")
            // Only show error for final translations; silently ignore partial failures
            if !isPartial {
                let idx = targetIndex ?? (targetLines.count - 1)
                if idx >= 0 && idx < targetLines.count {
                    targetLines[idx] = TranscriptLine(text: "[Translation failed]", isPartial: false)
                }
            }
        }
    }

    // MARK: - Copy / Export Helpers

    func copyAllOriginal() -> String {
        sourceLines.filter { !$0.isPartial }.map(\.text).joined(separator: "\n")
    }

    func copyAllTranslation() -> String {
        targetLines.filter { !$0.isPartial }.map(\.text).joined(separator: "\n")
    }

    func copyAllInterleaved() -> String {
        var result: [String] = []
        let finalSource = sourceLines.filter { !$0.isPartial }
        let finalTarget = targetLines.filter { !$0.isPartial }
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
