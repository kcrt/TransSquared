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
/// ## Threading Model
///
/// This class is `@unchecked Sendable` because it manages its own
/// synchronization via `OSAllocatedUnfairLock`. All mutable state lives in
/// a single `State` struct guarded by the lock:
///
/// | Method                | Called from            |
/// |-----------------------|------------------------|
/// | `startRecording()`    | MainActor              |
/// | `appendSampleBuffer`  | Serial capture queue   |
/// | `finishWriterInput()`  | Serial capture queue   |
/// | `stopRecording()`     | MainActor (async)      |
/// | `cleanup()`           | MainActor              |
///
/// > Note: Converting to a Swift `actor` is not viable because
/// > `appendSampleBuffer` must run synchronously on the capture queue.
/// > Actor methods are async, which would introduce unacceptable latency
/// > for real-time audio processing.
final class AudioRecordingService: @unchecked Sendable {

    /// All mutable state guarded by `lock`.
    private struct State {
        var assetWriter: AVAssetWriter?
        var recordingURL: URL?
        var writerInput: AVAssetWriterInput?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// URL of the temporary recording file.
    var recordingURL: URL? {
        lock.withLockUnchecked { $0.recordingURL }
    }

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
        lock.withLockUnchecked { state in
            state.assetWriter = writer
            state.recordingURL = url
        }
        logger.info("Recording started → \(url.lastPathComponent)")
        return url
    }

    /// Appends a raw sample buffer to the recording.
    ///
    /// On the first call, lazily creates the `AVAssetWriterInput` using the
    /// buffer's `formatDescription` as `sourceFormatHint` and starts writing.
    ///
    /// The lock is released before calling `AVAssetWriterInput.append(_:)` to
    /// avoid blocking the capture queue on a potentially slow I/O operation.
    ///
    /// Must be called from a serial queue (the capture queue).
    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        let (input, isNew): (AVAssetWriterInput?, Bool) = lock.withLockUnchecked { state in
            guard let writer = state.assetWriter else { return (nil, false) }

            if state.writerInput == nil {
                let input = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: Self.outputSettings,
                    sourceFormatHint: sampleBuffer.formatDescription
                )
                input.expectsMediaDataInRealTime = true
                writer.add(input)
                guard writer.startWriting() else {
                    logger.error("AVAssetWriter failed to start: \(writer.error?.localizedDescription ?? "unknown")")
                    return (nil, false)
                }
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                state.writerInput = input
                return (input, true)
            }

            return (state.writerInput, false)
        }

        if isNew {
            logger.info("Created recording writer input with source format: \(String(describing: sampleBuffer.formatDescription))")
        }

        if let input, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    /// Marks the writer input as finished so the asset writer can finalize.
    /// Must be called from the capture queue before `stopRecording()`.
    func finishWriterInput() {
        lock.withLockUnchecked { state in
            state.writerInput?.markAsFinished()
            state.writerInput = nil
        }
    }

    /// Finalizes the recording and returns the file URL on success, or nil on failure.
    @discardableResult
    func stopRecording() async -> URL? {
        let (writer, url) = lock.withLockUnchecked { state -> (AVAssetWriter?, URL?) in
            let w = state.assetWriter
            let u = state.recordingURL
            state.assetWriter = nil
            state.writerInput = nil
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
        let url = lock.withLockUnchecked { state -> URL? in
            let u = state.recordingURL
            state.recordingURL = nil
            state.assetWriter = nil
            state.writerInput = nil
            return u
        }
        if let url {
            try? FileManager.default.removeItem(at: url)
            logger.debug("Cleaned up recording file: \(url.lastPathComponent)")
        }
    }
}
