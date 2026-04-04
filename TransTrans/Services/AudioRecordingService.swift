import AVFoundation
import CoreMedia
import os

private let logger = Logger.app("AudioRecording")

/// Records raw audio from the capture pipeline into an AAC-encoded m4a file.
///
/// The `AVAssetWriterInput` is created lazily on the first sample buffer
/// so that the actual `CMFormatDescription` is used as `sourceFormatHint`,
/// ensuring the AAC encoder receives the correct source format regardless
/// of microphone hardware.
///
/// Thread-safety is ensured by an `NSLock` guarding all mutable state.
/// `appendSampleBuffer` and `finishWriterInput` are called from the serial
/// capture queue, while `startRecording`, `stopRecording`, and `cleanup`
/// are called from the MainActor.
final class AudioRecordingService: @unchecked Sendable {
    private let lock = NSLock()
    private var assetWriter: AVAssetWriter?
    /// URL of the temporary recording file.
    private(set) var recordingURL: URL?

    /// Writer input created lazily from the first buffer's format description.
    private var writerInput: AVAssetWriterInput?

    /// AAC output settings used when creating the writer input.
    private static let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 1,
        AVSampleRateKey: 48000.0,
        AVEncoderBitRateKey: 128_000
    ]

    /// Starts recording to a new temporary m4a file.
    /// - Returns: The URL of the temporary file being written.
    func startRecording() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        lock.withLock {
            self.assetWriter = writer
            self.recordingURL = url
        }
        logger.info("Recording started → \(url.lastPathComponent)")
        return url
    }

    /// Appends a raw sample buffer to the recording.
    ///
    /// On the first call, lazily creates the `AVAssetWriterInput` using the
    /// buffer's `formatDescription` as `sourceFormatHint` and starts writing.
    /// Must be called from a serial queue (the capture queue).
    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        guard let writer = assetWriter else { lock.unlock(); return }

        if writerInput == nil {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: Self.outputSettings,
                sourceFormatHint: sampleBuffer.formatDescription
            )
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            guard writer.startWriting() else {
                lock.unlock()
                logger.error("AVAssetWriter failed to start: \(writer.error?.localizedDescription ?? "unknown")")
                return
            }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            writerInput = input
            logger.info("Created recording writer input with source format: \(String(describing: sampleBuffer.formatDescription))")
        }

        let input = writerInput
        lock.unlock()

        if let input, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    /// Marks the writer input as finished so the asset writer can finalize.
    /// Must be called from the capture queue before `stopRecording()`.
    func finishWriterInput() {
        lock.withLock {
            writerInput?.markAsFinished()
            writerInput = nil
        }
    }

    /// Finalizes the recording and returns the file URL on success, or nil on failure.
    func stopRecording() async -> URL? {
        let (writer, url) = lock.withLock { () -> (AVAssetWriter?, URL?) in
            let w = assetWriter
            let u = recordingURL
            assetWriter = nil
            writerInput = nil
            return (w, u)
        }
        guard let writer else { return nil }
        await writer.finishWriting()
        if writer.status == .completed {
            logger.info("Recording finalized successfully")
            return url
        } else {
            logger.error("Recording finalization failed (status: \(writer.status.rawValue), error: \(writer.error?.localizedDescription ?? "nil"))")
            return nil
        }
    }

    /// Removes the temporary recording file from disk.
    func cleanup() {
        let url = lock.withLock { () -> URL? in
            let u = recordingURL
            recordingURL = nil
            assetWriter = nil
            writerInput = nil
            return u
        }
        if let url {
            try? FileManager.default.removeItem(at: url)
            logger.debug("Cleaned up recording file: \(url.lastPathComponent)")
        }
    }
}
