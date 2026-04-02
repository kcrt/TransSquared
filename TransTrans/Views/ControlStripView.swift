import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Save Transcript Menu Items (shared between context menu and toolbar)

/// Reusable menu content for save transcript actions.
struct SaveTranscriptMenuItems: View {
    let viewModel: SessionViewModel

    var body: some View {
        Button("Original") {
            viewModel.saveTranscript(contentType: .original)
        }
        Button("Translation") {
            viewModel.saveTranscript(contentType: .translation)
        }
        Button("Both (Interleaved)") {
            viewModel.saveTranscript(contentType: .both)
        }
    }
}

// MARK: - Checkmark Menu Item Label

/// A menu button label that shows a checkmark when selected.
struct CheckmarkLabel: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

// MARK: - Audio Waveform Visualization

struct AudioWaveformView: View {
    var levels: [Float]
    var isActive: Bool

    private let barCount = 20
    private let barSpacing: CGFloat = 1

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                let level = index < levels.count ? CGFloat(levels[index]) : 0
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(barColor(level: level))
                    .frame(width: 1, height: max(2, level * 28))
            }
        }
        .opacity(isActive ? 1.0 : 0.3)
        .animation(.easeOut(duration: 0.08), value: levels)
    }

    private func barColor(level: CGFloat) -> Color {
        if !isActive { return .secondary }
        if level > 0.7 { return .red }
        if level > 0.4 { return .orange }
        return .green
    }
}
