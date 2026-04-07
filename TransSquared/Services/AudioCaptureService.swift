@preconcurrency import AVFoundation
import CoreMedia
import Speech
import os

private let logger = Logger.app("AudioCapture")

/// Captures microphone audio using AVCaptureSession and produces an AsyncStream of AnalyzerInput.
/// This approach works around a known macOS 26 regression (FB19024508) where AVAudioEngine
/// fails to detect input devices and throws -10877.
@MainActor
final class AudioCaptureService {
    private var captureSession: AVCaptureSession?
    private var delegate: AudioCaptureDelegate?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var isCapturing = false
    private let captureQueue = DispatchQueue(label: "net.kcrt.app.transsquared.audiocapture", qos: .userInteractive)

    /// Publishes audio level samples (0.0–1.0) for waveform visualization.
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private(set) var audioLevelStream: AsyncStream<Float>?

    func startCapture(audioFormat: AVAudioFormat, device: AVCaptureDevice? = nil, recordingService: AudioRecordingService? = nil) async throws -> AsyncStream<AnalyzerInput> {
        guard !isCapturing else {
            logger.error("startCapture called while already capturing")
            throw TransSquaredError.alreadyCapturing
        }

        guard let audioDevice = device ?? AVCaptureDevice.default(for: .audio) else {
            logger.error("No default audio device available for capture")
            throw TransSquaredError.microphoneUnavailable
        }
        logger.info("Starting capture with device: \(audioDevice.localizedName)")
        logger.info("Target audio format: \(audioFormat.sampleRate) Hz, \(audioFormat.channelCount) ch, \(audioFormat.commonFormat.rawValue)")

        let session = AVCaptureSession()
        session.beginConfiguration()

        // Add audio input
        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        guard session.canAddInput(audioInput) else {
            logger.error("Cannot add audio input to capture session")
            throw TransSquaredError.microphoneUnavailable
        }
        session.addInput(audioInput)
        logger.debug("Added audio input to session")

        // Add audio data output
        let audioOutput = AVCaptureAudioDataOutput()
        guard session.canAddOutput(audioOutput) else {
            logger.error("Cannot add audio output to capture session")
            throw TransSquaredError.microphoneUnavailable
        }
        session.addOutput(audioOutput)

        // Do NOT set audioSettings — accept the device's native format.
        // Setting any audioSettings triggers an internal AudioUnit processing
        // chain inside AVCaptureAudioDataOutput. Virtual audio drivers (e.g.
        // BlackHole) cause this chain to fail with a Fig assert, resulting in
        // silent or corrupted audio. By accepting native format, no internal
        // conversion is needed, and AudioCaptureDelegate's AVAudioConverter
        // handles all resampling and channel mapping.
        logger.debug("Added audio data output to session (native format)")

        session.commitConfiguration()
        logger.debug("Session configuration committed")

        // Create the async stream
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.inputContinuation = continuation

        // Create audio level stream for waveform visualization.
        // Use .bufferingNewest(1) so the UI consumer always sees the latest
        // sample instead of falling progressively behind when the main thread
        // cannot keep up with the high-frequency audio callbacks.
        let (levelStream, levelCont) = AsyncStream.makeStream(
            of: Float.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.audioLevelStream = levelStream
        self.levelContinuation = levelCont

        // Create delegate that handles sample buffer conversion.
        // recordingService is passed at init to avoid a data race — the
        // delegate must have its recording service before any callbacks fire.
        let captureDelegate = AudioCaptureDelegate(
            targetFormat: audioFormat,
            continuation: continuation,
            levelContinuation: levelCont,
            recordingService: recordingService
        )
        self.delegate = captureDelegate
        audioOutput.setSampleBufferDelegate(captureDelegate, queue: captureQueue)

        self.captureSession = session
        self.isCapturing = true

        // Start the session on a background queue (startRunning is blocking)
        // and wait for it to actually start before returning.
        logger.info("Starting AVCaptureSession...")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async {
                session.startRunning()
                if session.isRunning {
                    logger.info("AVCaptureSession is now running")
                    continuation.resume()
                } else {
                    logger.error("AVCaptureSession failed to start running")
                    continuation.resume(throwing: TransSquaredError.microphoneUnavailable)
                }
            }
        }

        return stream
    }

    func stopCapture() async {
        guard isCapturing else {
            logger.debug("stopCapture called but not capturing")
            return
        }

        logger.info("Stopping audio capture")
        // stopRunning() is synchronous and guarantees no further captureOutput
        // callbacks will fire after it returns.
        captureSession?.stopRunning()
        captureSession = nil

        // Flush remaining audio on the capture queue. Use async + continuation
        // instead of sync to avoid a potential deadlock if this method were
        // ever called from the capture queue.
        let delegateToFlush = delegate
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            captureQueue.async {
                delegateToFlush?.finishRecording()
                delegateToFlush?.flushAccumulationBuffer()
                continuation.resume()
            }
        }
        delegate = nil

        inputContinuation?.finish()
        inputContinuation = nil
        levelContinuation?.finish()
        levelContinuation = nil
        audioLevelStream = nil
        isCapturing = false
        logger.info("Audio capture stopped")
    }
}



