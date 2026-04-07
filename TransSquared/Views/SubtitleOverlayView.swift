import SwiftUI

/// Container view that bridges `SessionViewModel` into `SubtitleOverlayView`.
///
/// Uses `TimelineView` to periodically refresh `now` so expired subtitles are removed,
/// while SwiftUI's `@Observable` tracking automatically re-renders when ViewModel
/// data (entries, fontSize) changes — no manual `withObservationTracking` needed.
struct SubtitleContainerView: View {
    var viewModel: SessionViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            SubtitleOverlayView(
                lines: viewModel.translationLines(forSlot: 0),
                fontSize: viewModel.fontSize,
                now: context.date
            )
        }
    }
}

/// A subtitle-style overlay that displays recent translation lines at the bottom of the screen.
/// Designed to look like movie subtitles: text centered on a semi-transparent background.
struct SubtitleOverlayView: View {
    var lines: [TranscriptLine]
    var fontSize: CGFloat
    var now: Date

    /// Duration in seconds before a finalized subtitle line disappears.
    private static let expirationInterval: TimeInterval = 30

    /// Maximum number of subtitle lines shown at once.
    private static let maxVisibleLines = 5

    private var visibleLines: [TranscriptLine] {
        // Scan from the end — lines are chronological, so once we hit an expired
        // finalized line all earlier lines are also expired. This is O(k) where k
        // is the number of visible lines, not O(n) for the entire history.
        var result: [TranscriptLine] = []
        for line in lines.reversed() {
            if result.count >= Self.maxVisibleLines { break }
            if line.isSeparator { continue }
            if line.isPartial {
                result.append(line)
                continue
            }
            guard let finalizedAt = line.finalizedAt else {
                result.append(line)
                continue
            }
            if now.timeIntervalSince(finalizedAt) < Self.expirationInterval {
                result.append(line)
            } else {
                break
            }
        }
        return result.reversed()
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
        .accessibilityLabel("Subtitle overlay")
        .accessibilityHint("Press Command-D to dismiss")
    }
}
