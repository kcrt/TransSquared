@preconcurrency import AVFoundation
import CoreMedia
import Speech
import os

private let logger = Logger.app("AudioCaptureDelegate")

// MARK: - Delegate for handling audio sample buffers

final class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let targetFormat: AVAudioFormat
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    let levelContinuation: AsyncStream<Float>.Continuation

    // MARK: - Recording (delegated to AudioRecordingService)
    /// Set once at init and never mutated afterwards. The delegate is
    /// called from the serial capture queue, so immutability after init
    /// is sufficient for thread safety.
    let recordingService: AudioRecordingService?

    // MARK: - Pipeline state (initialized on first buffer via setupPipeline)
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var needsConversion = false
    private var conversionRatio: Double = 1.0
    private var pipelineReady = false

    /// When the source has more channels than the target, we manually extract
    /// channel 0 into this mono buffer before passing it to the converter.
    /// AVAudioConverter's built-in stereo→mono downmix produces silent output
    /// on certain virtual audio drivers (e.g. BlackHole).
    private var needsChannelExtraction = false
    private var monoSourceFormat: AVAudioFormat?

    // Accumulation buffer: collect small chunks before yielding to the analyzer.
    // 4800 frames @ 16 kHz = 300 ms — enough context for the speech recognizer.
    private static let accumulationFrameCount: AVAudioFrameCount = 4800
    private var accumulationBuffer: AVAudioPCMBuffer?
    private var accumulatedFrames: AVAudioFrameCount = 0

    init(targetFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation, levelContinuation: AsyncStream<Float>.Continuation, recordingService: AudioRecordingService? = nil) {
        self.targetFormat = targetFormat
        self.continuation = continuation
        self.levelContinuation = levelContinuation
        self.recordingService = recordingService
        super.init()
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let frameCount = sampleBuffer.numSamples
        guard frameCount > 0 else { return }

        // 1. Forward raw CMSampleBuffer to the recorder (if active).
        recordingService?.appendSampleBuffer(sampleBuffer)

        // 2. Initialize pipeline on first buffer.
        if !pipelineReady {
            guard setupPipeline(from: sampleBuffer) else { return }
        }
        guard let sourceFormat else { return }

        // 3. Convert CMSampleBuffer → AVAudioPCMBuffer
        guard let pcmBuffer = cmSampleBufferToAVAudioPCMBuffer(
            sampleBuffer,
            sourceFormat: sourceFormat,
            frameCount: AVAudioFrameCount(frameCount)
        ) else {
            logger.error("Failed to convert CMSampleBuffer to AVAudioPCMBuffer")
            return
        }

        // 4. Resample if needed, or pass through
        let outputBuffer: AVAudioPCMBuffer
        if needsConversion {
            guard let converted = convert(pcmBuffer) else { return }
            outputBuffer = converted
        } else {
            outputBuffer = pcmBuffer
        }

        // 5. Compute audio level for waveform visualization
        yieldAudioLevel(from: outputBuffer)

        // 6. Accumulate and yield to analyzer
        accumulateAndYield(outputBuffer)
    }

    // MARK: - First-buffer pipeline initialization

    /// Detects the source audio format from the first `CMSampleBuffer` and
    /// creates an `AVAudioConverter` if the source differs from the target.
    /// Returns `true` when the pipeline is ready for processing.
    private func setupPipeline(from sampleBuffer: CMSampleBuffer) -> Bool {
        guard let formatDesc = sampleBuffer.formatDescription else {
            logger.warning("Sample buffer has no format description")
            return false
        }

        // Create AVAudioFormat directly from the format description so the
        // actual sample format (Float32, Int16, etc.) and layout (interleaved
        // vs non-interleaved) are respected. Some devices (e.g. Razer Seiren
        // Mini) deliver Int16 instead of Float32.
        let srcFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)
        self.sourceFormat = srcFormat

        let formatMatch = srcFormat.sampleRate == targetFormat.sampleRate
            && srcFormat.channelCount == targetFormat.channelCount
            && srcFormat.commonFormat == targetFormat.commonFormat
            && srcFormat.isInterleaved == targetFormat.isInterleaved
        self.needsConversion = !formatMatch

        if needsConversion {
            self.conversionRatio = targetFormat.sampleRate / srcFormat.sampleRate

            // When the source has more channels than the target (e.g. stereo
            // → mono), we extract channel 0 manually and give the converter a
            // mono-to-mono job. AVAudioConverter's built-in channel downmix
            // produces silent output with certain drivers (e.g. BlackHole).
            let converterSrcFormat: AVAudioFormat
            if srcFormat.channelCount > targetFormat.channelCount {
                guard let monoFmt = AVAudioFormat(
                    commonFormat: srcFormat.commonFormat,
                    sampleRate: srcFormat.sampleRate,
                    channels: targetFormat.channelCount,
                    interleaved: false
                ) else {
                    logger.error("Failed to create mono source format")
                    return false
                }
                self.monoSourceFormat = monoFmt
                self.needsChannelExtraction = true
                converterSrcFormat = monoFmt
                logger.info("Channel extraction enabled: \(srcFormat.channelCount)ch → \(self.targetFormat.channelCount)ch (manual)")
            } else {
                converterSrcFormat = srcFormat
            }

            guard let conv = AVAudioConverter(from: converterSrcFormat, to: targetFormat) else {
                logger.error("Failed to create AVAudioConverter: \(converterSrcFormat) → \(self.targetFormat)")
                return false
            }
            self.converter = conv
            logger.info("Audio pipeline: \(srcFormat.sampleRate) Hz \(srcFormat.channelCount)ch \(srcFormat.commonFormat.rawValue) interleaved=\(srcFormat.isInterleaved) → \(self.targetFormat.sampleRate) Hz \(self.targetFormat.channelCount)ch")
        } else {
            logger.info("Audio pipeline: source matches target (\(srcFormat.sampleRate) Hz \(srcFormat.channelCount)ch)")
        }

        pipelineReady = true
        return true
    }

    // MARK: - Format conversion

    /// Resamples a PCM buffer from `sourceFormat` to `targetFormat`.
    /// When the source has more channels than the target, channel 0 is
    /// extracted first and the converter only performs sample rate conversion.
    private func convert(_ pcmBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }

        // If source is multi-channel, extract channel 0 into a mono buffer.
        let inputBuffer: AVAudioPCMBuffer
        if needsChannelExtraction, let monoFmt = monoSourceFormat,
           let srcFloat = pcmBuffer.floatChannelData {
            guard let mono = AVAudioPCMBuffer(
                pcmFormat: monoFmt,
                frameCapacity: pcmBuffer.frameLength
            ), let dstFloat = mono.floatChannelData else {
                return nil
            }
            mono.frameLength = pcmBuffer.frameLength
            memcpy(dstFloat[0], srcFloat[0], Int(pcmBuffer.frameLength) * MemoryLayout<Float>.size)
            inputBuffer = mono
        } else {
            inputBuffer = pcmBuffer
        }

        let capacity = max(1, AVAudioFrameCount(Double(inputBuffer.frameLength) * conversionRatio) + 1)
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            logger.error("Failed to create conversion output buffer")
            return nil
        }

        var error: NSError?
        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let error {
            logger.error("Audio conversion error: \(error.localizedDescription)")
        }

        guard status == .haveData, convertedBuffer.frameLength > 0 else {
            logger.debug("Audio conversion produced no output (status=\(status.rawValue))")
            return nil
        }
        return convertedBuffer
    }

    // MARK: - Audio level metering

    /// Computes RMS level and yields a normalized value (0–1) to the level stream.
    private func yieldAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let rms = buffer.rmsLevel() else { return }
        let db = 20 * log10(max(rms, 1e-10))
        let floor: Float = -50
        let normalized = max(0, min(1, (db - floor) / -floor))
        levelContinuation.yield(normalized)
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

        // Validate channel counts match actual buffer data to prevent out-of-bounds access
        let srcChannels = Int(buffer.format.channelCount)
        let dstChannels = Int(accumBuf.format.channelCount)
        let safeChannelCount = min(channelCount, srcChannels, dstChannels)

        guard framesToCopy > 0, safeChannelCount > 0,
              Int(accumulatedFrames) + Int(framesToCopy) <= Int(accumBuf.frameCapacity) else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }

        for ch in 0..<safeChannelCount {
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
                      let newDstFloat = newAccumBuf.floatChannelData,
                      Int(leftover) <= Int(newAccumBuf.frameCapacity) else { return }
                let newDstChannels = Int(newAccumBuf.format.channelCount)
                let safeLeftoverChannels = min(safeChannelCount, newDstChannels)
                for ch in 0..<safeLeftoverChannels {
                    let src = srcFloat[ch].advanced(by: Int(framesToCopy))
                    memcpy(newDstFloat[ch], src, Int(leftover) * MemoryLayout<Float>.size)
                }
                accumulatedFrames = leftover
                newAccumBuf.frameLength = leftover
            }
        }
    }

    /// Tells the recording service to mark its writer input as finished.
    func finishRecording() {
        recordingService?.finishWriterInput()
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
            try sampleBuffer.copyPCMData(
                fromRange: 0..<Int(frameCount),
                into: pcmBuffer.mutableAudioBufferList
            )
        } catch {
            logger.error("copyPCMData failed: \(error.localizedDescription)")
            return nil
        }

        return pcmBuffer
    }
}
