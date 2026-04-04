import AVFoundation
import CoreMedia
import os

private let logger = Logger.app("AudioRecording")

/// Records raw audio from the capture pipeline into an AAC-encoded m4a file.
///
/// The service creates an `AVAssetWriter` and exposes it so that
/// `AudioCaptureDelegate` can lazily create the `AVAssetWriterInput` using
/// the actual `CMSampleBuffer` format description — ensuring the AAC encoder
/// receives the correct source format hint regardless of microphone hardware.
final class AudioRecordingService {
    /// The underlying asset writer (exposed so the delegate can add an input and start a session).
    private(set) var assetWriter: AVAssetWriter?
    /// URL of the temporary recording file.
    private(set) var recordingURL: URL?

    /// AAC output settings used when creating the writer input lazily.
    static let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 1,
        AVSampleRateKey: 48000.0,
        AVEncoderBitRateKey: 128_000
    ]

    /// Starts recording to a new temporary m4a file.
    ///
    /// The `AVAssetWriterInput` is **not** created here — it is created lazily
    /// by `AudioCaptureDelegate` when the first sample buffer arrives, using the
    /// buffer's `formatDescription` as `sourceFormatHint`.
    /// - Returns: The URL of the temporary file being written.
    func startRecording() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        // NOTE: startWriting() and startSession(atSourceTime:) are called by
        // AudioCaptureDelegate when the first sample buffer arrives — the input
        // must be added before startWriting(), and we need the buffer's
        // formatDescription to create the input with the correct sourceFormatHint.

        self.assetWriter = writer
        self.recordingURL = url
        logger.info("Recording started → \(url.lastPathComponent)")
        return url
    }

    /// Finalizes the recording and returns the file URL on success, or nil on failure.
    func stopRecording() async -> URL? {
        guard let writer = assetWriter else { return nil }
        await writer.finishWriting()
        let url = recordingURL
        assetWriter = nil
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
    }
}
