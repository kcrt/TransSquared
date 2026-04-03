import AVFoundation
import CoreMedia
import os

private let logger = Logger.app("AudioRecording")

/// Records raw audio from the capture pipeline into an AAC-encoded m4a file.
///
/// The service exposes its `AVAssetWriter` and `AVAssetWriterInput` so that
/// `AudioCaptureDelegate` can append `CMSampleBuffer`s directly from the
/// capture queue — no cross-actor hop required.
final class AudioRecordingService {
    /// The underlying asset writer (exposed so the delegate can call `startSession`).
    private(set) var assetWriter: AVAssetWriter?
    /// The audio writer input (exposed so the delegate can call `append`).
    private(set) var audioWriterInput: AVAssetWriterInput?
    /// URL of the temporary recording file.
    private(set) var recordingURL: URL?

    /// Starts recording to a new temporary m4a file.
    /// - Returns: The URL of the temporary file being written.
    func startRecording() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 48000.0,
            AVEncoderBitRateKey: 128_000
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        guard writer.startWriting() else {
            logger.error("AVAssetWriter failed to start: \(writer.error?.localizedDescription ?? "unknown")")
            throw writer.error ?? TransTransError.recordingFailed
        }
        // NOTE: startSession(atSourceTime:) is called by AudioCaptureDelegate
        // when the first sample buffer arrives — this keeps timing accurate.

        self.assetWriter = writer
        self.audioWriterInput = input
        self.recordingURL = url
        logger.info("Recording started → \(url.lastPathComponent)")
        return url
    }

    /// Finalizes the recording and returns the file URL on success, or nil on failure.
    func stopRecording() async -> URL? {
        guard let writer = assetWriter else { return nil }
        audioWriterInput?.markAsFinished()
        await writer.finishWriting()
        let url = recordingURL
        assetWriter = nil
        audioWriterInput = nil
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
        audioWriterInput = nil
    }
}
