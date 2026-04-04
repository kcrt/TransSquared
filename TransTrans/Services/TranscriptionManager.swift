import Speech
import AVFoundation
import CoreMedia
import os

enum TranscriptionEvent: Sendable {
    case partial(String, duration: TimeInterval?, audioOffset: TimeInterval?)
    case finalized(String, duration: TimeInterval?, audioOffset: TimeInterval?)
    case error(String)
}

/// Timing information extracted from a `SpeechTranscriber.Result`'s `TimeRangeAttribute` runs.
struct AudioTimeInfo: Sendable {
    /// Start position within the audio source (seconds).
    let offset: TimeInterval
    /// Duration of the spoken audio (seconds).
    let duration: TimeInterval

    /// Extracts the audio start offset and total spoken-audio duration from a `SpeechTranscriber.Result`'s
    /// attributed string by reading `TimeRangeAttribute` runs.
    static func from(_ text: AttributedString) -> AudioTimeInfo? {
        var minStart: CMTime?
        var maxEnd: CMTime?
        for run in text.runs {
            guard let timeRange = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
            let start = timeRange.start
            let end = CMTimeAdd(start, timeRange.duration)
            if minStart == nil || CMTimeCompare(start, minStart!) < 0 {
                minStart = start
            }
            if maxEnd == nil || CMTimeCompare(end, maxEnd!) > 0 {
                maxEnd = end
            }
        }
        guard let start = minStart, let end = maxEnd else { return nil }
        let duration = CMTimeGetSeconds(CMTimeSubtract(end, start))
        guard duration > 0 else { return nil }
        return AudioTimeInfo(offset: CMTimeGetSeconds(start), duration: duration)
    }
}

/// Streams returned by `TranscriptionManager.start()`.
struct TranscriptionStreams {
    let events: AsyncStream<TranscriptionEvent>
    let audioLevels: AsyncStream<Float>?
}

actor TranscriptionManager {
    private nonisolated let logger = Logger.app("Transcription")
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var audioCaptureService: AudioCaptureService?
    private var analyzeTask: Task<Void, Error>?
    private var resultTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<TranscriptionEvent>.Continuation?
    private var isRunning = false

    func start(locale: Locale, audioDevice: AVCaptureDevice? = nil, contextualStrings: [String] = [], recordingService: AudioRecordingService? = nil) async throws -> TranscriptionStreams {
        guard !isRunning else {
            logger.warning("start() called while already running")
            throw TransTransError.alreadyRunning
        }

        logger.info("Starting transcription for locale: \(locale.identifier)")

        // Create transcriber with time-indexed progressive preset (volatile + fast + audioTimeRange)
        let newTranscriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        logger.debug("Created SpeechTranscriber with .timeIndexedProgressiveTranscription preset")

        // Ensure assets are installed
        logger.info("Checking speech assets...")
        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [newTranscriber]) {
            logger.info("Speech assets need installation, downloading...")
            try await installationRequest.downloadAndInstall()
            logger.info("Speech assets installed successfully")
        } else {
            logger.info("Speech assets already available")
        }

        // Create capture service (MainActor-isolated)
        let captureService = await AudioCaptureService()

        // Let SpeechAnalyzer choose the best format without hardware hints.
        // AVCaptureAudioDataOutput resamples to a system rate (typically 48 kHz)
        // regardless of the device's native format, so device.formats is unreliable
        // for this purpose. AVAudioConverter handles any rate mismatch.
        guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [newTranscriber]
        ) else {
            logger.error("No compatible audio format found for transcriber")
            throw TransTransError.audioFormatUnavailable
        }
        logger.info("Selected audio format: \(audioFormat.sampleRate) Hz, \(audioFormat.channelCount) ch")

        // Create analyzer
        let newAnalyzer = SpeechAnalyzer(modules: [newTranscriber])
        logger.debug("Created SpeechAnalyzer")

        // Set contextual strings to bias recognition toward custom vocabulary
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try await newAnalyzer.setContext(context)
            logger.info("Set \(contextualStrings.count) contextual string(s) on analyzer")
        }

        // Start audio capture
        logger.info("Starting audio capture...")
        let audioStream = try await captureService.startCapture(audioFormat: audioFormat, device: audioDevice, recordingService: recordingService)
        logger.info("Audio capture started successfully")

        // Create event stream
        let (eventStream, continuation) = AsyncStream.makeStream(of: TranscriptionEvent.self)
        self.eventContinuation = continuation

        let audioLevels = await captureService.audioLevelStream

        self.audioCaptureService = captureService
        self.transcriber = newTranscriber
        self.analyzer = newAnalyzer
        self.isRunning = true

        // Start consuming transcription results
        let capturedTranscriber = newTranscriber
        let capturedContinuation = continuation
        let logger = self.logger
        resultTask = Task { [weak self] in
            logger.debug("Result consumption task started")
            var resultCount = 0
            do {
                for try await result in capturedTranscriber.results {
                    resultCount += 1
                    let text = String(result.text.characters)
                    let timeInfo = await AudioTimeInfo.from(result.text)
                    if result.isFinal {
                        logger.debug("Final result #\(resultCount): \"\(text, privacy: .private)\" (duration: \(timeInfo.map { String(format: "%.2fs", $0.duration) } ?? "nil"))")
                        capturedContinuation.yield(.finalized(text, duration: timeInfo?.duration, audioOffset: timeInfo?.offset))
                    } else {
                        logger.debug("Partial result #\(resultCount): \"\(text, privacy: .private)\"")
                        capturedContinuation.yield(.partial(text, duration: timeInfo?.duration, audioOffset: timeInfo?.offset))
                    }
                }
                logger.info("Transcriber results stream ended (total: \(resultCount))")
            } catch {
                if !Task.isCancelled {
                    logger.error("Transcriber results error: \(error.localizedDescription)")
                    capturedContinuation.yield(.error(error.localizedDescription))
                } else {
                    logger.debug("Result task cancelled")
                }
            }
            if let self = self {
                await self.markStopped()
            }
        }

        // Start analysis in the background
        let capturedAnalyzer = newAnalyzer
        analyzeTask = Task {
            logger.debug("Analysis task started")
            do {
                let endTime = try await capturedAnalyzer.analyzeSequence(audioStream)
                logger.info("analyzeSequence completed, endTime=\(String(describing: endTime))")
                // Finalize the last partial result so the transcriber emits
                // it as a final result before the session ends.
                if let endTime {
                    try await capturedAnalyzer.finalizeAndFinish(through: endTime)
                    logger.info("Analyzer finalized and finished through endTime")
                }
            } catch {
                if !Task.isCancelled {
                    logger.error("analyzeSequence error: \(error.localizedDescription)")
                } else {
                    logger.debug("Analysis task cancelled")
                }
            }
        }

        logger.info("Transcription pipeline fully started")
        return TranscriptionStreams(events: eventStream, audioLevels: audioLevels)
    }

    func stop() async {
        guard isRunning else {
            logger.debug("stop() called but not running")
            return
        }

        logger.info("Stopping transcription...")

        // Stop audio capture — this finishes the audio stream so
        // analyzeSequence returns, which triggers finalizeAndFinish
        // inside analyzeTask to produce the last finalized result.
        await audioCaptureService?.stopCapture()
        audioCaptureService = nil

        // Wait for the analysis to complete naturally. Do NOT cancel —
        // analyzeTask calls finalizeAndFinish after the stream ends,
        // which ensures the last partial is emitted as a final result.
        let pendingAnalyze = analyzeTask
        analyzeTask = nil
        _ = try? await pendingAnalyze?.value

        // Wait for result consumption to finish. The transcriber's
        // results stream ends after the analyzer finishes.
        let pendingResult = resultTask
        resultTask = nil
        _ = await pendingResult?.value

        // Fallback: ensure the analyzer is finished even if the task
        // errored before calling finalizeAndFinish.
        if let analyzer {
            logger.debug("Finishing analyzer (fallback)...")
            await analyzer.cancelAndFinishNow()
        }

        // Clean up
        analyzer = nil
        transcriber = nil
        eventContinuation?.finish()
        eventContinuation = nil
        isRunning = false
        logger.info("Transcription stopped")
    }

    private func markStopped() {
        logger.debug("markStopped called")
        eventContinuation?.finish()
        eventContinuation = nil
    }
}


