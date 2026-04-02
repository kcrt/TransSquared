import AVFoundation
import Accelerate

// MARK: - AVAudioPCMBuffer RMS Computation

extension AVAudioPCMBuffer {
    /// Computes the RMS (root-mean-square) level of the first channel's audio samples.
    /// Uses vDSP (SIMD-optimized) for the common float32 path.
    /// Returns a value suitable for visualization, or nil if no data is available.
    func rmsLevel() -> Float? {
        let count = Int(frameLength)
        guard count > 0 else { return nil }

        // Fast path: float32 — use vDSP SIMD-optimized RMS
        if let floatData = floatChannelData {
            var rms: Float = 0
            vDSP_rmsqv(floatData[0], 1, &rms, vDSP_Length(count))
            return rms
        }

        // Fallback for integer formats (rarely hit in practice)
        let sumOfSquares: Float
        if let int16Data = int16ChannelData {
            sumOfSquares = rmsSum(UnsafeBufferPointer(start: int16Data[0], count: count), scale: Float(Int16.max))
        } else if let int32Data = int32ChannelData {
            sumOfSquares = rmsSum(UnsafeBufferPointer(start: int32Data[0], count: count), scale: Float(Int32.max))
        } else {
            return nil
        }

        return sqrt(sumOfSquares / Float(count))
    }

    /// Generic sum-of-squares computation over integer samples.
    private func rmsSum<T: BinaryInteger>(_ samples: UnsafeBufferPointer<T>, scale: Float) -> Float {
        var sum: Float = 0
        for s in samples {
            let f = Float(s) / scale
            sum += f * f
        }
        return sum
    }
}
