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

            let isExpired = line.finalizedAt.map { now.timeIntervalSince($0) >= Self.expirationInterval } ?? false
            if isExpired { break }
            result.append(line)
        }
        return result.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if !visibleLines.isEmpty {
                VStack(spacing: 2) {
                    ForEach(visibleLines) { line in
                        styledLineText(line)
                            .font(.system(size: fontSize, weight: .medium))
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

    private func styledLineText(_ line: TranscriptLine) -> Text {
        if let prefix = line.finalizedPrefix {
            let suffix = String(line.text.dropFirst(prefix.count))
            return Text(prefix).foregroundStyle(.white)
                + Text(suffix).foregroundStyle(.white.opacity(0.7)).italic()
        } else if line.isPartial {
            return Text(line.text).foregroundStyle(.white.opacity(0.7)).italic()
        } else {
            return Text(line.text).foregroundStyle(.white)
        }
    }
}
