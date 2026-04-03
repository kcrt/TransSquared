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

    /// The source of truth for all transcript data. Each entry groups source segments with translations.
    var entries: [TranscriptEntry] = []
    /// Translation slots — one per target language (always `targetCount` active slots).
    /// Slots manage queue state; translation results are stored in `entries`.
    var translationSlots: [TranslationSlot] = [TranslationSlot()]

    /// Derived source lines for the UI, computed from entries.
    var sourceLines: [TranscriptLine] {
        entries.flatMap { $0.sourceTranscriptLines() }
    }

    /// Derives translation lines for the given slot from entries.
    func translationLines(forSlot slot: Int) -> [TranscriptLine] {
        entries.compactMap { entry in
            if entry.isSeparator {
                return TranscriptLine(id: entry.id, text: "", isPartial: false, isSeparator: true)
            }
            return entry.translationTranscriptLine(forSlot: slot)
        }
    }
    var isSessionActive = false

    // MARK: - Session Mode & Recording State

    /// Whether the session transcribes only or also records audio (persisted via UserDefaults).
    var sessionMode: SessionMode = {
        if let raw = UserDefaults.standard.string(forKey: "sessionMode"),
           let mode = SessionMode(rawValue: raw) {
            return mode
        }
        return .transcribeOnly
    }() {
        didSet { UserDefaults.standard.set(sessionMode.rawValue, forKey: "sessionMode") }
    }

    /// The active recording service (non-nil only while recording in `.recordAndTranscribe` mode).
    var recordingService: AudioRecordingService?
    /// URL of the current/most-recent recording file. Available for playback after recording stops.
    var currentRecordingURL: URL?
    /// The cumulative elapsed time offset when recording started, used to map entry timestamps to audio time.
    var recordingStartElapsedOffset: TimeInterval = 0
    /// Whether a recording file exists for the current session (enables playback UI).
    var hasRecording: Bool { currentRecordingURL != nil }

    /// Pending mode switch awaiting user confirmation (non-nil when confirmation alert is shown).
    var pendingModeSwitch: SessionMode?
    /// Whether the mode-switch confirmation alert is presented.
    var showModeSwitchConfirmation = false

    // MARK: - Playback State

    /// Playback service for replaying recorded audio at specific timestamps.
    var playbackService: AudioPlaybackService?

    var fontSize: CGFloat = 16
    var isAlwaysOnTop = false
    var errorMessage: String?
    var showSettings = false
    var displayMode: DisplayMode = .normal
    var permissionIssue: PermissionIssue?
    /// The sentenceID currently highlighted across all panes (set by tapping a timestamp).
    var highlightedSentenceID: UUID?

    // MARK: - File Export State
    var isExporterPresented = false
    var exportContent: String?
    var exportDefaultFilename = ""

    // MARK: - File Transcription State
    var isTranscribingFile = false
    var showFileImporter = false
    var fileTranscriptionTask: Task<Void, Never>?
    var audioFileTranscriber: AudioFileTranscriber?
    var fileTranscriptionProgress: Double = 0
    var fileAudioDuration: TimeInterval = 0
    /// URL awaiting user confirmation before file transcription clears existing data.
    var pendingFileTranscriptionURL: URL?
    var showFileTranscriptionConfirmation = false

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

    /// Silence duration (in seconds) before a sentence boundary is assumed (persisted via UserDefaults).
    var sentenceBoundarySeconds: Double = UserDefaults.standard.object(forKey: "sentenceBoundarySeconds") as? Double ?? 3.0 {
        didSet { UserDefaults.standard.set(sentenceBoundarySeconds, forKey: "sentenceBoundarySeconds") }
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

    /// Number of audio level samples kept for waveform visualization.
    static let audioLevelSampleCount = 20
    /// Ordered audio level samples for waveform visualization (oldest → newest, 0.0–1.0).
    /// Backed by a ring buffer for O(1) writes; the ordered array is only constructed on read.
    var audioLevels: [Float] {
        let n = Self.audioLevelSampleCount
        let start = audioLevelWriteIndex % n
        if start == 0 { return audioLevelRingBuffer }
        return Array(audioLevelRingBuffer[start...]) + Array(audioLevelRingBuffer[..<start])
    }
    private var audioLevelRingBuffer = Array(repeating: Float(0), count: audioLevelSampleCount)
    private var audioLevelWriteIndex = 0

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
    static let maxTargetCount = 3

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
        !entries.isEmpty
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
    var sentenceBoundaryGeneration: UInt64 = 0
    var pendingSentenceBuffer = ""
    var sessionStartDate: Date?
    /// Total elapsed time accumulated from previous start/stop cycles.
    var accumulatedElapsedTime: TimeInterval = 0
    var segmentIndex = 0

    /// Cumulative elapsed time from the first session start to now,
    /// accounting for time accumulated across previous start/stop cycles.
    var currentElapsedTime: TimeInterval {
        let currentSegment: TimeInterval
        if let start = sessionStartDate {
            currentSegment = Date().timeIntervalSince(start)
        } else {
            currentSegment = 0
        }
        return accumulatedElapsedTime + currentSegment
    }

    /// Index of the current uncommitted, non-separator entry (the one being built).
    var currentEntryIndex: Int? {
        guard let last = entries.indices.last else { return nil }
        let entry = entries[last]
        if entry.isSeparator || entry.isCommitted { return nil }
        return last
    }

    /// Ensures a current (uncommitted) entry exists, creating one if needed.
    /// Returns the index of the current entry.
    @discardableResult
    func ensureCurrentEntry() -> Int {
        if let idx = currentEntryIndex { return idx }
        entries.append(TranscriptEntry(elapsedTime: currentElapsedTime))
        return entries.count - 1
    }

    /// Finds the entry index for a given entry ID.
    func entryIndex(for entryID: UUID) -> Int? {
        entries.firstIndex(where: { $0.id == entryID })
    }

    static let partialTranslationDebounce: Duration = .milliseconds(300)

    // Sentence-ending punctuation characters
    static let sentenceEndChars: Set<Character> = [".", "。", "!", "?", "！", "？"]
    /// Sentence boundary timeout derived from the user-configurable `sentenceBoundarySeconds`.
    var sentenceBoundaryTimeout: Duration { .milliseconds(Int(sentenceBoundarySeconds * 1000)) }

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

        // Remove any leftover partial state from the previous session
        if let idx = currentEntryIndex {
            entries[idx].pendingPartial = nil
            for slot in 0..<entries[idx].translations.count {
                if entries[idx].translations[slot]?.isPartial == true {
                    entries[idx].translations[slot] = nil
                }
            }
            // Remove the entry entirely if it has no content
            if entries[idx].source.text.isEmpty && entries[idx].translations.allSatisfy({ $0 == nil }) {
                entries.remove(at: idx)
            }
        }

        // Insert a separator if there is previous history
        if !entries.isEmpty {
            entries.append(TranscriptEntry(isSeparator: true))
        }

        pendingSentenceBuffer = ""
        segmentIndex = 0
        sessionStartDate = Date()

        // Initialize translation slots
        let slotCount = targetCount
        translationSlots = (0..<slotCount).map { i in
            var slot = TranslationSlot()
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
                // Start recording if in record-and-transcribe mode
                var writerInput: AVAssetWriterInput?
                var writer: AVAssetWriter?
                if sessionMode == .recordAndTranscribe {
                    let recorder = AudioRecordingService()
                    let url = try recorder.startRecording()
                    self.recordingService = recorder
                    self.currentRecordingURL = url
                    self.recordingStartElapsedOffset = accumulatedElapsedTime
                    writerInput = recorder.audioWriterInput
                    writer = recorder.assetWriter
                    logger.info("Audio recording started: \(url.lastPathComponent)")
                }

                logger.info("Starting transcription manager...")
                let streams = try await transcriptionManager.start(locale: sourceLocale, audioDevice: selectedMicrophone, contextualStrings: currentContextualStrings, recordingInput: writerInput, recordingWriter: writer)

                // Start consuming audio levels for waveform display
                if let levelStream = streams.audioLevels {
                    audioLevelTask = Task {
                        for await level in levelStream {
                            audioLevelRingBuffer[audioLevelWriteIndex % Self.audioLevelSampleCount] = level
                            audioLevelWriteIndex += 1
                        }
                    }
                }

                logger.info("Transcription started, consuming events...")
                for await event in streams.events {
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

        // Accumulate elapsed time from this session segment
        if let start = sessionStartDate {
            accumulatedElapsedTime += Date().timeIntervalSince(start)
        }
        sessionStartDate = nil

        // Await full teardown so the microphone is released before any restart
        await transcriptionManager.stop()

        // Finalize recording (keep URL for playback)
        if let recorder = recordingService {
            _ = await recorder.stopRecording()
            recordingService = nil
            logger.info("Audio recording finalized")
        }

        isSessionActive = false
        for slot in 0..<translationSlots.count {
            translationSlots[slot].reset()
        }
        audioLevelRingBuffer = Array(repeating: 0, count: Self.audioLevelSampleCount)
        audioLevelWriteIndex = 0
        logger.info("Session stopped (entries: \(self.entries.count))")
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

    // MARK: - Session Mode

    /// Changes the session mode, potentially showing a confirmation alert if a recording exists.
    func setSessionMode(_ mode: SessionMode) {
        guard mode != sessionMode else { return }
        guard !isSessionActive else { return }
        if currentRecordingURL != nil {
            pendingModeSwitch = mode
            showModeSwitchConfirmation = true
            return
        }
        sessionMode = mode
    }

    /// Confirms the pending mode switch, cleaning up any existing recording.
    func confirmModeSwitch() {
        guard let mode = pendingModeSwitch else { return }
        cleanupRecording()
        sessionMode = mode
        pendingModeSwitch = nil
    }

    // MARK: - Playback

    /// Plays recorded audio from the given elapsed time.
    func playFromTimestamp(_ elapsedTime: TimeInterval, entryID: UUID) {
        guard let url = currentRecordingURL else { return }

        if playbackService == nil {
            playbackService = AudioPlaybackService()
            playbackService?.loadAudio(url: url)
        }

        // Convert entry elapsed time to audio file position
        let audioTime = elapsedTime - recordingStartElapsedOffset
        guard audioTime >= 0 else { return }

        // Toggle: stop if already playing this entry, otherwise play
        if playbackService?.playingEntryID == entryID && playbackService?.isPlaying == true {
            playbackService?.stop()
        } else {
            playbackService?.play(from: audioTime, entryID: entryID)
        }
    }

    /// Cleans up recording file and playback state.
    func cleanupRecording() {
        playbackService?.cleanup()
        playbackService = nil
        recordingService?.cleanup()
        recordingService = nil
        currentRecordingURL = nil
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
