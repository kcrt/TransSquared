import Foundation
import os

/// Manages audio level samples for waveform visualization.
///
/// Extracted from `SessionViewModel` to reduce observation churn — audio level
/// updates fire many times per second and should only invalidate views that
/// actually display the waveform, not the entire ViewModel observer graph.
@Observable
@MainActor
final class AudioLevelMonitor {

    /// Number of audio level samples kept for waveform visualization.
    static let sampleCount = 20

    /// Ordered audio level samples for waveform visualization (oldest → newest, 0.0–1.0).
    private(set) var levels = Array(repeating: Float(0), count: sampleCount)

    @ObservationIgnored private var ringBuffer = Array(repeating: Float(0), count: sampleCount)
    @ObservationIgnored private var writeIndex = 0

    /// Writes a new level into the ring buffer and rebuilds the cached ordered array.
    func append(_ level: Float) {
        ringBuffer[writeIndex % Self.sampleCount] = level
        writeIndex += 1
        let n = Self.sampleCount
        let start = writeIndex % n
        if start == 0 {
            levels = ringBuffer
        } else {
            // Single allocation instead of two slices + concatenation.
            levels = Array(unsafeUninitializedCapacity: n) { buffer, count in
                let tail = n - start
                for i in 0..<tail { buffer[i] = ringBuffer[start + i] }
                for i in 0..<start { buffer[tail + i] = ringBuffer[i] }
                count = n
            }
        }
    }

    /// Resets all levels to zero.
    func reset() {
        levels = Array(repeating: 0, count: Self.sampleCount)
        ringBuffer = Array(repeating: 0, count: Self.sampleCount)
        writeIndex = 0
    }
}
