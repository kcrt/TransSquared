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
    private var converter: AVAudioConverter?
    private var bufferCount = 0

    // Accumulation buffer: collect small chunks before yielding to the analyzer.
    // 4800 frames @ 16 kHz = 300 ms — enough context for the speech recognizer.
    private static let accumulationFrameCount: AVAudioFrameCount = 4800
    private var accumulationBuffer: AVAudioPCMBuffer?
    private var accumulatedFrames: AVAudioFrameCount = 0

    // MARK: - Recording support
    /// Optional writer input for recording raw audio to m4a. Set before capture starts.
    var recordingInput: AVAssetWriterInput?
    /// The asset writer owning `recordingInput`. Used to call `startSession(atSourceTime:)` on the first buffer.
    var recordingWriter: AVAssetWriter?
    /// Tracks whether `startSession(atSourceTime:)` has been called on the writer.
    private var recordingSessionStarted = false

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

        // Forward raw CMSampleBuffer to the recorder (if active).
        // This runs on the serial captureQueue, so AVAssetWriterInput.append is safe.
        if let recordingInput, let recordingWriter {
            if !recordingSessionStarted {
                recordingWriter.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                recordingSessionStarted = true
            }
            if recordingInput.isReadyForMoreMediaData {
                recordingInput.append(sampleBuffer)
            }
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
            // Convert to decibels, then map to 0–1 for display.
            // Floor at –50 dB (silence); 0 dB (full-scale) maps to 1.0.
            let db = 20 * log10(max(rms, 1e-10))
            let floor: Float = -50
            let normalized = max(0, min(1, (db - floor) / -floor))
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
