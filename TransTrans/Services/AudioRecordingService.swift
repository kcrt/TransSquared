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
final class AudioRecordingService {
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
        self.assetWriter = writer
        self.recordingURL = url
        logger.info("Recording started → \(url.lastPathComponent)")
        return url
    }

    /// Appends a raw sample buffer to the recording.
    ///
    /// On the first call, lazily creates the `AVAssetWriterInput` using the
    /// buffer's `formatDescription` as `sourceFormatHint` and starts writing.
    /// Must be called from a serial queue (the capture queue).
    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let writer = assetWriter else { return }

        if writerInput == nil {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: Self.outputSettings,
                sourceFormatHint: sampleBuffer.formatDescription
            )
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            guard writer.startWriting() else {
                logger.error("AVAssetWriter failed to start: \(writer.error?.localizedDescription ?? "unknown")")
                return
            }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            writerInput = input
            logger.info("Created recording writer input with source format: \(String(describing: sampleBuffer.formatDescription))")
        }

        if let writerInput, writerInput.isReadyForMoreMediaData {
            writerInput.append(sampleBuffer)
        }
    }

    /// Marks the writer input as finished so the asset writer can finalize.
    /// Must be called from the capture queue before `stopRecording()`.
    func finishWriterInput() {
        writerInput?.markAsFinished()
        writerInput = nil
    }

    /// Finalizes the recording and returns the file URL on success, or nil on failure.
    func stopRecording() async -> URL? {
        guard let writer = assetWriter else { return nil }
        await writer.finishWriting()
        let url = recordingURL
        assetWriter = nil
        writerInput = nil
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
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            logger.debug("Cleaned up recording file: \(url.lastPathComponent)")
        }
        recordingURL = nil
        assetWriter = nil
        writerInput = nil
    }
}
