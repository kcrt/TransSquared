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

    /// Returns the hardware audio format from the specified (or default) capture device.
    func hardwareInputFormat(device: AVCaptureDevice? = nil) -> AVAudioFormat? {
        guard let device = device ?? AVCaptureDevice.default(for: .audio) else {
            logger.warning("No default audio capture device found")
            return nil
        }
        logger.debug("Audio device: \(device.localizedName)")

        let descriptions = device.formats.compactMap { $0.formatDescription }
        guard let first = descriptions.first else {
            logger.warning("Audio device has no format descriptions")
            return nil
        }
        guard let basicDesc = first.audioStreamBasicDescription, basicDesc.mSampleRate > 0, basicDesc.mChannelsPerFrame > 0 else {
            logger.warning("Audio device format has invalid sample rate or channel count")
            return nil
        }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: basicDesc.mSampleRate,
            channels: basicDesc.mChannelsPerFrame,
            interleaved: false
        )
        logger.info("Hardware input format: \(basicDesc.mSampleRate) Hz, \(basicDesc.mChannelsPerFrame) ch")
        return format
    }

    func startCapture(audioFormat: AVAudioFormat, device: AVCaptureDevice? = nil) throws -> AsyncStream<AnalyzerInput> {
        guard !isCapturing else {
            logger.error("startCapture called while already capturing")
            throw AudioCaptureError.alreadyCapturing
        }

        guard let audioDevice = device ?? AVCaptureDevice.default(for: .audio) else {
            logger.error("No default audio device available for capture")
            throw AudioCaptureError.microphoneUnavailable
        }
        logger.info("Starting capture with device: \(audioDevice.localizedName)")
        logger.info("Target audio format: \(audioFormat.sampleRate) Hz, \(audioFormat.channelCount) ch, \(audioFormat.commonFormat.rawValue)")

        let session = AVCaptureSession()
        session.beginConfiguration()

        // Add audio input
        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        guard session.canAddInput(audioInput) else {
            logger.error("Cannot add audio input to capture session")
            throw AudioCaptureError.microphoneUnavailable
        }
        session.addInput(audioInput)
        logger.debug("Added audio input to session")

        // Add audio data output
        let audioOutput = AVCaptureAudioDataOutput()
        guard session.canAddOutput(audioOutput) else {
            logger.error("Cannot add audio output to capture session")
            throw AudioCaptureError.microphoneUnavailable
        }
        session.addOutput(audioOutput)
        logger.debug("Added audio data output to session")

        session.commitConfiguration()
        logger.debug("Session configuration committed")

        // Create the async stream
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.inputContinuation = continuation

        // Create audio level stream for waveform visualization
        let (levelStream, levelCont) = AsyncStream.makeStream(of: Float.self)
        self.audioLevelStream = levelStream
        self.levelContinuation = levelCont

        // Create delegate that handles sample buffer conversion
        let captureDelegate = AudioCaptureDelegate(
            targetFormat: audioFormat,
            continuation: continuation,
            levelContinuation: levelCont
        )
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

// MARK: - Delegate for handling audio sample buffers

private final class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let targetFormat: AVAudioFormat
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    let levelContinuation: AsyncStream<Float>.Continuation
    private var converter: AVAudioConverter?
    private var bufferCount = 0

    // Accumulation buffer: collect small chunks before yielding to the analyzer.
    // 4800 frames @ 16 kHz = 300 ms — enough context for the speech recognizer.
    private static let accumulationFrameCount: AVAudioFrameCount = 4800
    private var accumulationBuffer: AVAudioPCMBuffer?
    private var accumulatedFrames: AVAudioFrameCount = 0

    init(targetFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation, levelContinuation: AsyncStream<Float>.Continuation) {
        self.targetFormat = targetFormat
        self.continuation = continuation
        self.levelContinuation = levelContinuation
        super.init()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        bufferCount += 1

        guard let formatDesc = sampleBuffer.formatDescription else {
            logger.warning("Sample buffer has no format description")
            return
        }
        guard let basicDesc = formatDesc.audioStreamBasicDescription else {
            logger.warning("Cannot read ASBD from format description")
            return
        }

        let frameCount = sampleBuffer.numSamples
        guard frameCount > 0 else {
            logger.debug("Empty sample buffer received")
            return
        }

        if bufferCount == 1 {
            logger.info("First audio buffer received: \(basicDesc.mSampleRate) Hz, \(basicDesc.mChannelsPerFrame) ch, \(frameCount) frames")
        }

        // Create AVAudioFormat from the sample buffer's format
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: basicDesc.mSampleRate,
            channels: basicDesc.mChannelsPerFrame,
            interleaved: false
        ) else {
            logger.error("Failed to create source AVAudioFormat")
            return
        }

        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let pcmBuffer = cmSampleBufferToAVAudioPCMBuffer(
            sampleBuffer,
            sourceFormat: sourceFormat,
            frameCount: AVAudioFrameCount(frameCount)
        ) else {
            logger.error("Failed to convert CMSampleBuffer to AVAudioPCMBuffer")
            return
        }

        // Convert format if needed, or use directly
        let outputBuffer: AVAudioPCMBuffer
        if sourceFormat.sampleRate == targetFormat.sampleRate
            && sourceFormat.channelCount == targetFormat.channelCount
            && sourceFormat.commonFormat == targetFormat.commonFormat {
            outputBuffer = pcmBuffer
        } else {
            // Lazy-create converter
            if converter == nil {
                logger.info("Creating audio converter: \(sourceFormat.sampleRate) Hz → \(self.targetFormat.sampleRate) Hz")
                converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
                if converter == nil {
                    logger.error("Failed to create AVAudioConverter")
                }
            }
            guard let converter else { return }

            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let capacity = max(1, AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio) + 1)
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: capacity
            ) else {
                logger.error("Failed to create conversion output buffer")
                return
            }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return pcmBuffer
            }

            if let error {
                logger.error("Audio conversion error: \(error.localizedDescription)")
            }

            guard status == .haveData, convertedBuffer.frameLength > 0 else {
                logger.debug("Audio conversion produced no output (status=\(status.rawValue))")
                return
            }
            outputBuffer = convertedBuffer
        }

        // Compute RMS level for waveform visualization
        if let rms = outputBuffer.rmsLevel() {
            // Normalize: typical speech RMS ~0.01–0.3, scale to 0–1
            let normalized = min(rms * 5.0, 1.0)
            levelContinuation.yield(normalized)
        }

        accumulateAndYield(outputBuffer)
    }

    /// Accumulates small PCM buffers into a larger one before yielding to the analyzer.
    private func accumulateAndYield(_ buffer: AVAudioPCMBuffer) {
        // Lazily create the accumulation buffer
        if accumulationBuffer == nil {
            accumulationBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: Self.accumulationFrameCount
            )
            accumulationBuffer?.frameLength = 0
            accumulatedFrames = 0
        }

        guard let accumBuf = accumulationBuffer,
              let srcFloat = buffer.floatChannelData,
              let dstFloat = accumBuf.floatChannelData else {
            // Fallback: yield directly if accumulation is not possible
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }

        let framesToCopy = min(buffer.frameLength, Self.accumulationFrameCount - accumulatedFrames)
        let channelCount = Int(targetFormat.channelCount)

        for ch in 0..<channelCount {
            let src = srcFloat[ch]
            let dst = dstFloat[ch].advanced(by: Int(accumulatedFrames))
            memcpy(dst, src, Int(framesToCopy) * MemoryLayout<Float>.size)
        }
        accumulatedFrames += framesToCopy
        accumBuf.frameLength = accumulatedFrames

        if accumulatedFrames >= Self.accumulationFrameCount {
            // Yield the full accumulation buffer
            continuation.yield(AnalyzerInput(buffer: accumBuf))

            // Reset for next accumulation
            accumulationBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: Self.accumulationFrameCount
            )
            accumulationBuffer?.frameLength = 0
            accumulatedFrames = 0

            // Handle leftover frames from this buffer that didn't fit
            let leftover = buffer.frameLength - framesToCopy
            if leftover > 0 {
                guard let newAccumBuf = accumulationBuffer,
                      let newDstFloat = newAccumBuf.floatChannelData else { return }
                for ch in 0..<channelCount {
                    let src = srcFloat[ch].advanced(by: Int(framesToCopy))
                    memcpy(newDstFloat[ch], src, Int(leftover) * MemoryLayout<Float>.size)
                }
                accumulatedFrames = leftover
                newAccumBuf.frameLength = leftover
            }
        }
    }

    /// Flushes any remaining accumulated audio to the analyzer.
    func flushAccumulationBuffer() {
        guard let accumBuf = accumulationBuffer, accumulatedFrames > 0 else { return }
        logger.info("Flushing accumulation buffer: \(self.accumulatedFrames) frames")
        continuation.yield(AnalyzerInput(buffer: accumBuf))
        accumulationBuffer = nil
        accumulatedFrames = 0
    }

    // MARK: - CMSampleBuffer to AVAudioPCMBuffer conversion

    private func cmSampleBufferToAVAudioPCMBuffer(
        _ sampleBuffer: CMSampleBuffer,
        sourceFormat: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: frameCount
        ) else { return nil }

        pcmBuffer.frameLength = frameCount

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                let abl = audioBufferList.unsafePointer.pointee
                let destABL = pcmBuffer.mutableAudioBufferList

                let srcBufferCount = Int(abl.mNumberBuffers)
                let dstBufferCount = Int(destABL.pointee.mNumberBuffers)
                let count = min(srcBufferCount, dstBufferCount)

                withUnsafePointer(to: &destABL.pointee.mBuffers) { dstBufPtr in
                    withUnsafePointer(to: abl.mBuffers) { srcBufPtr in
                        let srcBufs = UnsafeBufferPointer(
                            start: srcBufPtr,
                            count: srcBufferCount
                        )
                        let dstBufs = UnsafeMutableBufferPointer(
                            start: UnsafeMutablePointer(mutating: dstBufPtr),
                            count: dstBufferCount
                        )
                        for i in 0..<count {
                            let bytesToCopy = min(srcBufs[i].mDataByteSize, dstBufs[i].mDataByteSize)
                            if let srcData = srcBufs[i].mData, let dstData = dstBufs[i].mData {
                                memcpy(dstData, srcData, Int(bytesToCopy))
                            }
                        }
                    }
                }
            }
        } catch {
            logger.error("withAudioBufferList failed: \(error.localizedDescription)")
            return nil
        }

        return pcmBuffer
    }
}

enum AudioCaptureError: Error, LocalizedError {
    case alreadyCapturing
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing:
            return "Audio capture is already in progress."
        case .microphoneUnavailable:
            return "Microphone is not available."
        }
    }
}
// MARK: - AVAudioPCMBuffer RMS Computation

extension AVAudioPCMBuffer {
    /// Computes the RMS (root-mean-square) level of the first channel's audio samples.
    /// Returns a value suitable for visualization, or nil if no data is available.
    func rmsLevel() -> Float? {
        let count = Int(frameLength)
        guard count > 0 else { return nil }

        let sumOfSquares: Float
        if let floatData = floatChannelData {
            sumOfSquares = rmsSum(UnsafeBufferPointer(start: floatData[0], count: count), scale: 1.0)
        } else if let int16Data = int16ChannelData {
            sumOfSquares = rmsSum(UnsafeBufferPointer(start: int16Data[0], count: count), scale: Float(Int16.max))
        } else if let int32Data = int32ChannelData {
            sumOfSquares = rmsSum(UnsafeBufferPointer(start: int32Data[0], count: count), scale: Float(Int32.max))
        } else {
            return nil
        }

        return sqrt(sumOfSquares / Float(count))
    }

    /// Generic sum-of-squares computation over integer or float samples.
    private func rmsSum<T: BinaryInteger>(_ samples: UnsafeBufferPointer<T>, scale: Float) -> Float {
        var sum: Float = 0
        for s in samples {
            let f = Float(s) / scale
            sum += f * f
        }
        return sum
    }

    private func rmsSum(_ samples: UnsafeBufferPointer<Float>, scale: Float) -> Float {
        var sum: Float = 0
        for s in samples { sum += s * s }
        return sum
    }
}

