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

    /// Appends a new level sample, keeping only the most recent `sampleCount` values.
    func append(_ level: Float) {
        levels.append(level)
        if levels.count > Self.sampleCount {
            levels.removeFirst()
        }
    }

    /// Resets all levels to zero.
    func reset() {
        levels = Array(repeating: 0, count: Self.sampleCount)
    }
}
