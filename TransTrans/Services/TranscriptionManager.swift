import Speech
import AVFoundation
import os

enum TranscriptionEvent: Sendable {
    case partial(String)
    case final_(String)
    case error(String)
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

    func start(locale: Locale, audioDevice: AVCaptureDevice? = nil, contextualStrings: [String] = []) async throws -> TranscriptionStreams {
        guard !isRunning else {
            logger.warning("start() called while already running")
            throw TransTransError.alreadyRunning
        }

        logger.info("Starting transcription for locale: \(locale.identifier)")

        // Create transcriber with progressive preset (volatile + fast results)
        let newTranscriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        logger.debug("Created SpeechTranscriber with .progressiveTranscription preset")

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

        // Get the hardware format from the capture service to inform format selection
        let hardwareFormat = await captureService.hardwareInputFormat(device: audioDevice)
        if let hwf = hardwareFormat {
            logger.info("Hardware format: \(hwf.sampleRate) Hz, \(hwf.channelCount) ch")
        } else {
            logger.warning("No hardware format available (nil)")
        }

        // Determine the best audio format, considering the hardware's native format
        guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [newTranscriber],
            considering: hardwareFormat
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
        let audioStream = try await captureService.startCapture(audioFormat: audioFormat, device: audioDevice)
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
                    if result.isFinal {
                        logger.info("Final result #\(resultCount): \"\(text)\"")
                        capturedContinuation.yield(.final_(text))
                    } else {
                        logger.debug("Partial result #\(resultCount): \"\(text)\"")
                        capturedContinuation.yield(.partial(text))
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

        // Stop audio capture first
        await audioCaptureService?.stopCapture()
        audioCaptureService = nil

        // Cancel tasks
        analyzeTask?.cancel()
        resultTask?.cancel()
        analyzeTask = nil
        resultTask = nil

        // Finish the analyzer
        if let analyzer {
            logger.debug("Finishing analyzer...")
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


