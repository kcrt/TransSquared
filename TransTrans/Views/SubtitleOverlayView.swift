import SwiftUI

/// A subtitle-style overlay that displays recent translation lines at the bottom of the screen.
/// Designed to look like movie subtitles: text centered on a semi-transparent background.
struct SubtitleOverlayView: View {
    var lines: [TranscriptLine]
    var fontSize: CGFloat
    var now: Date
    var onDismiss: (() -> Void)?

    /// Duration in seconds before a finalized subtitle line disappears.
    private static let expirationInterval: TimeInterval = 30

    private var visibleLines: [TranscriptLine] {
        lines.filter { line in
            // Never show separator lines in subtitle mode
            if line.isSeparator { return false }
            // Always show partial (in-progress) lines
            if line.isPartial { return true }
            // Show finalized lines that haven't expired yet
            guard let finalizedAt = line.finalizedAt else { return true }
            return now.timeIntervalSince(finalizedAt) < Self.expirationInterval
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if !visibleLines.isEmpty {
                VStack(spacing: 2) {
                    ForEach(visibleLines) { line in
                        Text(line.text)
                            .font(.system(size: fontSize, weight: .medium))
                            .foregroundStyle(line.isPartial ? .white.opacity(0.7) : .white)
                            .italic(line.isPartial)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.black.opacity(0.6))
                )
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            onDismiss?()
        }
    }
}
