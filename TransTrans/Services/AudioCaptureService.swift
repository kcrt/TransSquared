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
    private let captureQueue = DispatchQueue(label: "net.kcrt.app.transtrans.audiocapture", qos: .userInteractive)

    /// Publishes audio level samples (0.0–1.0) for waveform visualization.
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private(set) var audioLevelStream: AsyncStream<Float>?

    func startCapture(audioFormat: AVAudioFormat, device: AVCaptureDevice? = nil, recordingService: AudioRecordingService? = nil) throws -> AsyncStream<AnalyzerInput> {
        guard !isCapturing else {
            logger.error("startCapture called while already capturing")
            throw TransTransError.alreadyCapturing
        }

        guard let audioDevice = device ?? AVCaptureDevice.default(for: .audio) else {
            logger.error("No default audio device available for capture")
            throw TransTransError.microphoneUnavailable
        }
        logger.info("Starting capture with device: \(audioDevice.localizedName)")
        logger.info("Target audio format: \(audioFormat.sampleRate) Hz, \(audioFormat.channelCount) ch, \(audioFormat.commonFormat.rawValue)")

        let session = AVCaptureSession()
        session.beginConfiguration()

        // Add audio input
        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        guard session.canAddInput(audioInput) else {
            logger.error("Cannot add audio input to capture session")
            throw TransTransError.microphoneUnavailable
        }
        session.addInput(audioInput)
        logger.debug("Added audio input to session")

        // Add audio data output
        let audioOutput = AVCaptureAudioDataOutput()
        guard session.canAddOutput(audioOutput) else {
            logger.error("Cannot add audio output to capture session")
            throw TransTransError.microphoneUnavailable
        }
        session.addOutput(audioOutput)
        logger.debug("Added audio data output to session")

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

        // Create delegate that handles sample buffer conversion
        let captureDelegate = AudioCaptureDelegate(
            targetFormat: audioFormat,
            continuation: continuation,
            levelContinuation: levelCont
        )
        captureDelegate.recordingService = recordingService
        self.delegate = captureDelegate
        audioOutput.setSampleBufferDelegate(captureDelegate, queue: captureQueue)

        self.captureSession = session
        self.isCapturing = true

        // Start the session on a background queue (startRunning is blocking)
        logger.info("Starting AVCaptureSession...")
        captureQueue.async {
            session.startRunning()
            logger.info("AVCaptureSession is now running: \(session.isRunning)")
        }

        return stream
    }

    func stopCapture() {
        guard isCapturing else {
            logger.debug("stopCapture called but not capturing")
            return
        }

        logger.info("Stopping audio capture")
        captureSession?.stopRunning()
        captureSession = nil

        // Flush on the capture queue to avoid racing with captureOutput callbacks
        let delegateToFlush = delegate
        captureQueue.sync {
            delegateToFlush?.finishRecording()
            delegateToFlush?.flushAccumulationBuffer()
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



