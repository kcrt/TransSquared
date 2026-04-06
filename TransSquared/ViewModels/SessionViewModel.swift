import SwiftUI
import Speech
import Translation
import AVFoundation
import UniformTypeIdentifiers
import os

private let logger = Logger.app("Session")

/// Central view model that owns all application state for Trans².
///
/// Responsibilities are split across extensions by domain:
/// - **Session lifecycle** — `startSession()` / `stopSession()` (this file)
/// - **Transcription events** — `SessionViewModel+Transcription.swift`
/// - **Translation pipeline** — `SessionViewModel+Translation.swift`
/// - **Export & clipboard** — `SessionViewModel+Export.swift`
/// - **File transcription** — `SessionViewModel+FileTranscription.swift`
/// - **Permissions & utilities** — `SessionViewModel+Permissions.swift`
@Observable
@MainActor
final class SessionViewModel {

    // MARK: - Persistence

    /// The `UserDefaults` instance used for all persistence.
    /// Defaults to `.standard`; tests can inject a dedicated suite to avoid side-effects.
    let defaults: UserDefaults

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
    

    // MARK: - Recording State

    /// The active recording service (non-nil while a session is running).
    var recordingService: AudioRecordingService?
    /// All recording segments captured during this session (one per start/stop cycle).
    var recordingSegments: [RecordingSegment] = []
    /// URL of the most-recent recording file (convenience for export).
    var currentRecordingURL: URL? { recordingSegments.last?.url }
    /// Whether any recording file exists (enables playback UI).
    var hasRecording: Bool { !recordingSegments.isEmpty }



    // MARK: - Playback State

    /// Playback service for replaying recorded audio at specific timestamps.
    var playbackService: AudioPlaybackService?
    /// URL currently loaded in the playback service (to detect when a reload is needed).
    var loadedPlaybackURL: URL?

    /// Speech synthesis service for reading translated text aloud.
    let speechSynthesisService = SpeechSynthesisService()

    var fontSize: CGFloat = 16
    var isAlwaysOnTop = false
    var errorMessage: String?
    var showSettings = false
    var showAudioPopover = false
    var displayMode: DisplayMode = .normal
    var permissionIssue: PermissionIssue?
    /// The sentenceID currently highlighted across all panes (set by tapping a timestamp).
    var highlightedSentenceID: UUID?

    // MARK: - File Export State
    var isExporterPresented = false
    var exportContent: String?
    var exportDefaultFilename = ""
    var exportContentTypes: [UTType] = [.plainText]

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
    /// Security-scoped URL of the file transcription source, kept alive for post-transcription playback.
    var fileTranscriptionSourceURL: URL?

    /// Custom vocabulary words per source locale, keyed by locale identifier (persisted via UserDefaults).
    var contextualStringsByLocale: [String: [String]] = [:] {
        didSet { persistToUserDefaults(contextualStringsByLocale, forKey: "contextualStringsByLocale") }
    }

    /// Convenience accessor for the current source locale's vocabulary.
    var currentContextualStrings: [String] {
        get { contextualStringsByLocale[sourceLocaleIdentifier] ?? [] }
        set { contextualStringsByLocale[sourceLocaleIdentifier] = newValue }
    }

    /// Auto-replacement rules per source locale, keyed by locale identifier (persisted via UserDefaults).
    var autoReplacementsByLocale: [String: [AutoReplacement]] = [:] {
        didSet { persistToUserDefaults(autoReplacementsByLocale, forKey: "autoReplacementsByLocale") }
    }

    /// Convenience accessor for the current source locale's auto-replacement rules.
    var currentAutoReplacements: [AutoReplacement] {
        get { autoReplacementsByLocale[sourceLocaleIdentifier] ?? [] }
        set { autoReplacementsByLocale[sourceLocaleIdentifier] = newValue }
    }

    /// Silence duration (in seconds) before a sentence boundary is assumed (persisted via UserDefaults).
    var sentenceBoundarySeconds: Double = 3.0 {
        didSet { defaults.set(sentenceBoundarySeconds, forKey: "sentenceBoundarySeconds") }
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

    /// Audio level monitor — separated to reduce observation churn from high-frequency updates.
    let audioLevelMonitor = AudioLevelMonitor()

    // Language selection stored as String identifiers for reliable Picker binding.
    // Persisted via UserDefaults so the last-used languages are restored on relaunch.
    var sourceLocaleIdentifier: String = "ja_JP" {
        didSet { defaults.set(sourceLocaleIdentifier, forKey: "sourceLocaleIdentifier") }
    }
    /// Convenience accessor for the primary target language (slot 0 of `targetLanguageIdentifiers`).
    var targetLanguageIdentifier: String {
        get { targetLanguageIdentifiers[0] }
        set { targetLanguageIdentifiers[0] = newValue }
    }

    var supportedSourceLocales: [Locale] = []
    /// Set of source locale identifiers that are installed on device (no download needed).
    var installedSourceLocaleIdentifiers: Set<String> = []
    /// Set of source locale identifiers currently being downloaded.
    var downloadingSourceLocaleIdentifiers: Set<String> = []
    /// Task handles for in-progress speech asset downloads, keyed by locale identifier.
    /// Used to support real cancellation from `toggleSession()`.
    var speechDownloadTasks: [String: Task<Void, Never>] = [:]
    var supportedTargetLanguages: [Locale.Language] = []
    /// Whether each target language is installed on device, keyed by minimalIdentifier.
    /// Status depends on the current source language (rebuilt by `updateTargetLanguages()`).
    var targetLanguageDownloadStatus: [String: Bool] = [:]
    /// Configuration for proactively downloading translation models via `prepareTranslation()`.
    /// Set by `prepareTranslationModelIfNeeded(for:)`, consumed by the `.translationTask()` in ContentView.
    var translationPreparationConfig: TranslationSession.Configuration?

    // Microphone selection
    var availableMicrophones: [AVCaptureDevice] = []
    var selectedMicrophoneID: String = ""  // empty = system default

    // MARK: - Target Language Count

    /// Maximum number of target languages (derived from the canonical slot count).
    static let maxTargetCount = TranscriptEntry.maxTranslationSlots

    /// Number of active target panes (1, 2, or 3).
    var targetCount: Int = 1 {
        didSet { defaults.set(targetCount, forKey: "targetCount") }
    }

    /// Default target language identifiers used when no persisted value exists.
    /// The array is padded to `maxTargetCount` by cycling through the defaults.
    private static let defaultTargetLanguages = ["en", "zh-Hans", "ko"]
    private static var initialTargetLanguageIdentifiers: [String] {
        (0..<maxTargetCount).map { defaultTargetLanguages[$0 % defaultTargetLanguages.count] }
    }

    /// Target language identifiers for all slots (always `maxTargetCount` elements; only first `targetCount` are active).
    var targetLanguageIdentifiers: [String] = SessionViewModel.initialTargetLanguageIdentifiers {
        didSet { defaults.set(targetLanguageIdentifiers, forKey: "targetLanguageIdentifiers") }
    }

    // MARK: - Computed Properties

    /// Whether there is any transcript content (source or translation) to export or clear.
    var hasTranscriptContent: Bool {
        !entries.isEmpty
    }

    var sourceLocale: Locale {
        Locale(identifier: sourceLocaleIdentifier)
    }

    /// Whether the subtitle mode button should be disabled.
    var isSubtitleButtonDisabled: Bool {
        if displayMode == .subtitle { return false }
        if !isSessionActive { return true }
        return targetCount > 1
    }

    /// The currently selected microphone device, or nil for system default.
    var selectedMicrophone: AVCaptureDevice? {
        if selectedMicrophoneID.isEmpty { return nil }
        return availableMicrophones.first { $0.uniqueID == selectedMicrophoneID }
    }

    // MARK: - Internal State (accessed by extensions)
    //
    // These properties are `var` (internal setter) because they are mutated by
    // ViewModel extensions in separate files. Swift's access control does not
    // allow restricting setter access to "same class and its extensions across
    // files" without making them fully internal.

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

    // MARK: - Entry Index Map (O(1) lookup by UUID)

    /// Maps entry UUIDs to their index in the `entries` array for O(1) lookup.
    var entryIndexMap: [UUID: Int] = [:]

    /// Rebuilds the entry index map from the current entries array.
    /// Call after bulk mutations (remove, removeAll, etc.) that shift indices.
    func rebuildEntryIndexMap() {
        entryIndexMap.removeAll(keepingCapacity: true)
        for (index, entry) in entries.enumerated() {
            entryIndexMap[entry.id] = index
        }
    }

    /// Converts a raw audio offset to a cumulative elapsed time.
    /// For file transcription the offset is used directly; for live transcription
    /// the accumulated time from previous sessions is added.
    func adjustedElapsedTime(audioOffset: TimeInterval) -> TimeInterval {
        isTranscribingFile ? audioOffset : accumulatedElapsedTime + audioOffset
    }

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
        // Leave elapsedTime nil so it gets set from the audio offset of the
        // first transcription event for this entry. This ensures accurate
        // alignment with the recorded audio file for playback.
        let entry = TranscriptEntry(elapsedTime: nil)
        let idx = entries.count
        entries.append(entry)
        entryIndexMap[entry.id] = idx
        return idx
    }

    /// Finds the entry index for a given entry ID (O(1) via index map).
    func entryIndex(for entryID: UUID) -> Int? {
        entryIndexMap[entryID]
    }

    /// Creates fresh translation slots for the current target language configuration.
    func makeTranslationSlots() -> [TranslationSlot] {
        (0..<targetCount).map { i in
            var slot = TranslationSlot()
            let targetLang = Locale.Language(identifier: targetLanguageIdentifiers[i])
            slot.config = TranslationSession.Configuration(
                source: sourceLocale.language,
                target: targetLang
            )
            return slot
        }
    }

    static let partialTranslationDebounce: Duration = .milliseconds(300)

    // Sentence-ending punctuation characters
    static let sentenceEndChars: Set<Character> = [".", "。", "!", "?", "！", "？"]
    /// Normalized audio level at or below which audio is considered silence (≈ -40 dB).
    static let silenceThreshold: Float = 0.2
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
        async let supported = SpeechTranscriber.supportedLocales
        async let installed = SpeechTranscriber.installedLocales
        supportedSourceLocales = await supported
        installedSourceLocaleIdentifiers = Set(await installed.map(\.identifier))
        logger.info("Found \(self.supportedSourceLocales.count) supported, \(self.installedSourceLocaleIdentifiers.count) installed source locales")
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

    /// Refreshes only the installed-status set for source locales (lightweight, no full reload).
    func refreshSourceLocaleInstallStatus() async {
        let installed = await SpeechTranscriber.installedLocales
        installedSourceLocaleIdentifiers = Set(installed.map(\.identifier))
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

        // Verify speech recognition assets are installed before starting.
        // Check our own downloading set first — AssetInventory.status may not
        // report .downloading if the request was issued by a detached Task.
        let isDownloadingLocally = downloadingSourceLocaleIdentifiers.contains(sourceLocaleIdentifier)
        let transcriber = SpeechTranscriber(locale: sourceLocale, preset: .timeIndexedProgressiveTranscription)
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        logger.info("Asset status for \(self.sourceLocaleIdentifier): \(String(describing: assetStatus)), localDownloading: \(isDownloadingLocally)")

        if assetStatus != .installed {
            if isDownloadingLocally || assetStatus == .downloading {
                logger.info("Session start aborted: speech assets still downloading for \(self.sourceLocaleIdentifier)")
                errorMessage = String(
                    localized: "Speech recognition model is still downloading. Please wait and try again.",
                    comment: "Error shown when speech model is still downloading at session start"
                )
                return
            } else if assetStatus == .supported {
                logger.info("Session start aborted: speech assets not installed for \(self.sourceLocaleIdentifier)")
                errorMessage = String(
                    localized: "Speech recognition model is not installed. Please select the language again to start the download.",
                    comment: "Error shown when user tries to start a session without the required speech model"
                )
                downloadSpeechAssetsIfNeeded(for: sourceLocale)
                return
            } else if assetStatus == .unsupported {
                logger.info("Session start aborted: speech assets unsupported for \(self.sourceLocaleIdentifier)")
                errorMessage = String(
                    localized: "Speech recognition is not supported for this language.",
                    comment: "Error shown when the selected language is not supported for speech recognition"
                )
                return
            }
        }

        // Verify translation models are installed for all active target languages.
        let translationAvailability = LanguageAvailability()
        for i in 0..<targetCount {
            let targetLangId = targetLanguageIdentifiers[i]
            let targetLang = Locale.Language(identifier: targetLangId)
            let translationStatus = await translationAvailability.status(
                from: sourceLocale.language, to: targetLang
            )
            logger.info("Translation status for \(self.sourceLocaleIdentifier)→\(targetLangId): \(String(describing: translationStatus))")
            if translationStatus != .installed {
                let langName = Locale.current.localizedString(forIdentifier: targetLangId) ?? targetLangId
                logger.info("Session start aborted: translation model not installed for \(targetLangId)")
                errorMessage = String(
                    localized: "Translation model for \(langName) is not installed. Please install it from System Settings > General > Language & Region > Translation Languages.",
                    comment: "Error shown when translation model is not installed at session start"
                )
                return
            }
        }

        errorMessage = nil

        // Remove any leftover partial state from the previous session
        if let idx = currentEntryIndex {
            entries[idx].pendingPartial = nil
            entries[idx].translations = entries[idx].translations.filter { !$0.value.isPartial }
            // Remove the entry entirely if it has no content
            if entries[idx].source.text.isEmpty && entries[idx].translations.isEmpty {
                entries.remove(at: idx)
                rebuildEntryIndexMap()
            }
        }

        // Insert a separator if there is previous history
        if !entries.isEmpty {
            let separator = TranscriptEntry(isSeparator: true)
            entries.append(separator)
            entryIndexMap[separator.id] = entries.count - 1
        }

        pendingSentenceBuffer = ""
        segmentIndex = 0
        sessionStartDate = Date()

        // Initialize translation slots
        translationSlots = makeTranslationSlots()

        isSessionActive = true

        transcriptionTask = Task {
            do {
                // Start recording alongside transcription
                let recorder = AudioRecordingService()
                let url = try recorder.startRecording()
                self.recordingService = recorder
                self.recordingSegments.append(
                    RecordingSegment(url: url, elapsedTimeOffset: accumulatedElapsedTime)
                )
                logger.info("Audio recording started: \(url.lastPathComponent)")

                logger.info("Starting transcription manager...")
                let streams = try await transcriptionManager.start(locale: sourceLocale, audioDevice: selectedMicrophone, contextualStrings: currentContextualStrings, recordingService: recorder)

                // Start consuming audio levels for waveform display + silence-based sentence boundary
                if let levelStream = streams.audioLevels {
                    audioLevelTask = Task {
                        var silenceStart: ContinuousClock.Instant?
                        for await level in levelStream {
                            audioLevelMonitor.append(level)

                            // Silence-based sentence boundary detection:
                            // When actual audio silence persists for sentenceBoundarySeconds,
                            // commit any pending (non-punctuated) text.
                            if level <= Self.silenceThreshold {
                                if silenceStart == nil { silenceStart = .now }
                                if let start = silenceStart,
                                   ContinuousClock.now - start >= sentenceBoundaryTimeout,
                                   !pendingSentenceBuffer.isEmpty {
                                    let sentence = pendingSentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                                    pendingSentenceBuffer = ""
                                    commitSentence(sentence)
                                    // Don't reset silenceStart — still silent, so later
                                    // finalized text can be committed immediately.
                                }
                            } else {
                                silenceStart = nil
                            }
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
                recordingService?.cleanup()
                recordingService = nil
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

        // Cancel audio level task and timers, but keep transcriptionTask
        // alive so it can receive final events from the transcription manager.
        audioLevelTask?.cancel()
        audioLevelTask = nil
        sentenceBoundaryTimer?.cancel()
        sentenceBoundaryTimer = nil

        // Capture elapsed time before async cleanup so it reflects the
        // wall-clock duration of actual transcription, not the teardown wait.
        let stopDate = Date()

        // Stop transcription gracefully — this lets the analyzer finalize
        // its current hypothesis and produce a final result before closing.
        // While awaiting, transcriptionTask continues processing events on
        // the MainActor (which is free because we are suspended here).
        await transcriptionManager.stop()

        // The event stream has ended. Cancel transcriptionTask for cleanup.
        transcriptionTask?.cancel()
        transcriptionTask = nil

        // Accumulate elapsed time from this session segment, using the
        // timestamp captured before the async stop to avoid inflating it.
        if let start = sessionStartDate {
            accumulatedElapsedTime += stopDate.timeIntervalSince(start)
        }
        sessionStartDate = nil

        // Safety net: if the framework didn't finalize the last partial,
        // promote it to source text so it isn't lost.
        if let idx = currentEntryIndex,
           let partial = entries[idx].pendingPartial, !partial.isEmpty {
            logger.debug("Promoting unfinalised partial: \"\(partial, privacy: .private)\"")
            entries[idx].source.text += partial
            entries[idx].pendingPartial = nil
            pendingSentenceBuffer += partial
        }

        // Flush any remaining buffer
        if !pendingSentenceBuffer.isEmpty {
            logger.debug("Flushing pending buffer: \"\(self.pendingSentenceBuffer)\"")
            commitSentence(pendingSentenceBuffer)
            pendingSentenceBuffer = ""
        }

        // Finalize recording (keep URL for playback)
        if let recorder = recordingService {
            await recorder.stopRecording()
            recordingService = nil
            logger.info("Audio recording finalized")
        }

        isSessionActive = false
        // Clean up timers and partial state, but keep queue and config alive
        // so that pending/in-flight translations can still complete.
        // startSession() replaces translationSlots entirely, so no stale state leaks.
        cleanupTranslationSlotState()
        audioLevelMonitor.reset()
        logger.info("Session stopped (entries: \(self.entries.count))")

        // Refresh download status — models may have been downloaded during the session
        await refreshSourceLocaleInstallStatus()
    }

    func toggleSession() {
        // If the current source language is downloading, cancel the download
        if downloadingSourceLocaleIdentifiers.contains(sourceLocaleIdentifier) {
            speechDownloadTasks[sourceLocaleIdentifier]?.cancel()
            speechDownloadTasks.removeValue(forKey: sourceLocaleIdentifier)
            downloadingSourceLocaleIdentifiers.remove(sourceLocaleIdentifier)
            return
        }
        Task {
            if isSessionActive {
                await stopSession()
            } else {
                await startSession()
            }
        }
    }

    // MARK: - Playback

    /// Plays recorded audio from the given elapsed time.
    func playFromTimestamp(_ elapsedTime: TimeInterval, entryID: UUID) {
        // Stop any ongoing TTS to avoid overlap
        speechSynthesisService.stop()

        // Find the recording segment that contains this entry's elapsed time
        guard let segment = recordingSegments.last(where: { $0.elapsedTimeOffset <= elapsedTime }) else { return }

        // Load the correct audio file if needed (different segment or first play)
        if playbackService == nil || loadedPlaybackURL != segment.url {
            playbackService?.cleanup()
            playbackService = AudioPlaybackService()
            playbackService?.loadAudio(url: segment.url)
            loadedPlaybackURL = segment.url
        }

        // Convert entry elapsed time to audio file position
        let audioTime = elapsedTime - segment.elapsedTimeOffset
        guard audioTime >= 0 else { return }

        // Look up the entry's duration for auto-stop
        let duration = entryIndex(for: entryID).flatMap { entries[$0].duration }

        // Toggle: stop if already playing this entry, otherwise play
        if playbackService?.playingEntryID == entryID && playbackService?.isPlaying == true {
            playbackService?.stop()
        } else {
            playbackService?.play(from: audioTime, duration: duration, entryID: entryID)
        }
    }

    /// Speaks the translated text of the given entry and slot using TTS.
    func speakTranslation(entryID: UUID, slot: Int) {
        // Stop any ongoing audio playback to avoid overlap
        playbackService?.stop()

        // Toggle: stop if already speaking this entry
        if speechSynthesisService.speakingEntryID == entryID && speechSynthesisService.isSpeaking {
            speechSynthesisService.stop()
            return
        }

        // Look up the translation text for this entry and slot
        guard let idx = entryIndex(for: entryID),
              let translation = entries[idx].translations[slot],
              !translation.text.isEmpty,
              slot < targetLanguageIdentifiers.count else { return }

        let language = targetLanguageIdentifiers[slot]
        speechSynthesisService.speak(text: translation.text, language: language, entryID: entryID)
    }

    /// Cancels partial translation timers and clears transient slot state.
    /// Call this when stopping a session or discarding translation state.
    func cleanupTranslationSlotState() {
        for slot in 0..<translationSlots.count {
            translationSlots[slot].partialTranslationTimer?.cancel()
            translationSlots[slot].partialTranslationTimer = nil
            translationSlots[slot].pendingPartialText = nil
            translationSlots[slot].pendingPartialElapsedTime = nil
            translationSlots[slot].partialEntryID = nil
        }
    }

    /// Cleans up all recording files and playback state.
    func cleanupRecording() {
        playbackService?.cleanup()
        playbackService = nil
        loadedPlaybackURL = nil
        for segment in recordingSegments {
            try? FileManager.default.removeItem(at: segment.url)
        }
        recordingSegments = []
        recordingService = nil
        cleanupFileTranscriptionSource()
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

    static let minFontSize: CGFloat = 12
    static let maxFontSize: CGFloat = 32
    static let fontSizeStep: CGFloat = 2

    func increaseFontSize() {
        if fontSize < Self.maxFontSize {
            fontSize += Self.fontSizeStep
        }
    }

    func decreaseFontSize() {
        if fontSize > Self.minFontSize {
            fontSize -= Self.fontSizeStep
        }
    }

    // MARK: - UserDefaults Helpers

    private static func loadFromDefaults<T: Codable>(_ defaults: UserDefaults, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func persistToUserDefaults<T: Codable>(_ value: T, forKey key: String) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: key)
        } catch {
            logger.error("Failed to encode '\(key)' for UserDefaults: \(error.localizedDescription)")
        }
    }

    // MARK: - Initialization

    /// Creates a new session view model.
    /// - Parameter defaults: The `UserDefaults` instance to use. Pass a dedicated suite in tests.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Restore persisted values
        self.contextualStringsByLocale = Self.loadFromDefaults(defaults, forKey: "contextualStringsByLocale") ?? [:]
        self.autoReplacementsByLocale = Self.loadFromDefaults(defaults, forKey: "autoReplacementsByLocale") ?? [:]
        self.sentenceBoundarySeconds = defaults.object(forKey: "sentenceBoundarySeconds") as? Double ?? 3.0
        self.sourceLocaleIdentifier = defaults.string(forKey: "sourceLocaleIdentifier") ?? "ja_JP"

        let storedCount = defaults.integer(forKey: "targetCount")
        self.targetCount = (1...Self.maxTargetCount).contains(storedCount) ? storedCount : 1

        if let stored = defaults.array(forKey: "targetLanguageIdentifiers") as? [String], !stored.isEmpty {
            if stored.count >= Self.maxTargetCount {
                self.targetLanguageIdentifiers = stored
            } else {
                // Pad with defaults to maintain maxTargetCount elements
                var padded = stored
                let defaults = Self.initialTargetLanguageIdentifiers
                while padded.count < Self.maxTargetCount {
                    padded.append(defaults[padded.count % defaults.count])
                }
                self.targetLanguageIdentifiers = padded
            }
        }
    }
}
