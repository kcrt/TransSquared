import Speech
import AVFoundation
import os

/// Transcribes an audio file using the Speech framework's SpeechTranscriber.
///
/// Usage:
/// ```swift
/// let transcriber = AudioFileTranscriber()
/// let stream = try await transcriber.transcribe(fileURL: url, locale: locale)
/// for await event in stream {
///     // handle TranscriptionEvent
/// }
/// ```
actor AudioFileTranscriber {
    private nonisolated let logger = Logger.app("FileTranscription")
    private var analyzer: SpeechAnalyzer?
    private var pipelineTask: Task<Void, Never>?

    /// Transcribes the audio file at the given URL and yields `TranscriptionEvent`s.
    ///
    /// The returned stream emits `.partial` and `.finalized` events as speech is recognized,
    /// followed by stream termination when complete.
    func transcribe(
        fileURL: URL,
        locale: Locale,
        contextualStrings: [String] = [],
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (stream: AsyncStream<TranscriptionEvent>, duration: TimeInterval) {
        logger.info("Starting file transcription: \(fileURL.lastPathComponent), locale: \(locale.identifier)")

        let audioFile = try AVAudioFile(forReading: fileURL)
        let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        logger.info("Audio: \(audioFile.fileFormat.sampleRate) Hz, \(audioFile.length) frames, \(String(format: "%.1f", duration))s")

        // Use .transcription preset options with audioTimeRange for accurate offline recognition
        let basePreset = SpeechTranscriber.Preset.transcription
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: basePreset.transcriptionOptions,
            reportingOptions: basePreset.reportingOptions,
            attributeOptions: basePreset.attributeOptions.union([.audioTimeRange])
        )

        // Ensure speech assets are installed
        try await SpeechAnalyzer.ensureAssetsInstalled(for: [transcriber])

        let newAnalyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = newAnalyzer

        try await newAnalyzer.setContextualStrings(contextualStrings)

        // Report transcription progress via volatile range changes.
        if let onProgress {
            let totalDuration = duration
            await newAnalyzer.setVolatileRangeChangedHandler { range, _, changedEnd in
                guard changedEnd, totalDuration > 0 else { return }
                let progress = min(1.0, range.end.seconds / totalDuration)
                onProgress(progress)
            }
        }

        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptionEvent.self)
        let capturedLogger = logger

        // Cancel the analyzer if the consuming side drops the stream.
        let analyzerForCleanup = newAnalyzer
        continuation.onTermination = { termination in
            if case .cancelled = termination {
                Task { await analyzerForCleanup.cancelAndFinishNow() }
            }
        }

        pipelineTask = Task { [weak self] in
            // Consume transcription results concurrently with analysis.
            let resultTask = Task {
                do {
                    for try await result in transcriber.results {
                        let event = await TranscriptionEvent.from(result)
                        if result.isFinal {
                            capturedLogger.info("Final: \"\(String(result.text.characters))\"")
                        }
                        continuation.yield(event)
                    }
                    capturedLogger.info("Results stream ended")
                } catch {
                    if !Task.isCancelled {
                        capturedLogger.error("Result error: \(error.localizedDescription)")
                        continuation.yield(.error(error.localizedDescription))
                    }
                }
            }

            // Feed the audio file into the analyzer.
            do {
                let endTime = try await newAnalyzer.analyzeSequence(from: audioFile)
                capturedLogger.info("File consumed, endTime: \(String(describing: endTime))")

                if let endTime {
                    try await newAnalyzer.finalizeAndFinish(through: endTime)
                    capturedLogger.info("Analysis finalized")
                } else {
                    await newAnalyzer.cancelAndFinishNow()
                }
            } catch {
                if !Task.isCancelled {
                    capturedLogger.error("Analysis error: \(error.localizedDescription)")
                    continuation.yield(.error(error.localizedDescription))
                }
                await newAnalyzer.cancelAndFinishNow()
            }

            _ = await resultTask.result
            continuation.finish()

            if let self {
                await self.cleanup()
            }
        }

        return (stream, duration)
    }

    /// Cancels any in-progress transcription.
    func cancel() async {
        pipelineTask?.cancel()
        pipelineTask = nil
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        cleanup()
    }

    private func cleanup() {
        analyzer = nil
        pipelineTask = nil
    }
}
