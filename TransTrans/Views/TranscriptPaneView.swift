import SwiftUI

/// A reusable scrollable pane that displays transcript lines with auto-scroll.
/// Used by both the source (transcription) and target (translation) panes.
struct TranscriptPaneView: View {
    var lines: [TranscriptLine]
    var fontSize: CGFloat
    var placeholder: String?
    var showElapsedTime: Bool = false

    var body: some View {
        if lines.isEmpty, let placeholder {
            Text(placeholder)
                .font(.system(size: fontSize))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(lines) { line in
                            if line.isSeparator {
                                Divider()
                                    .padding(.vertical, 4)
                                    .id(line.id)
                            } else {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    if showElapsedTime, let elapsed = line.elapsedTime {
                                        Text(formatElapsedTime(elapsed))
                                            .font(.system(size: fontSize * 0.75, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .frame(minWidth: 40, alignment: .trailing)
                                    }
                                    Text(line.text)
                                        .font(.system(size: fontSize))
                                        .foregroundStyle(line.isPartial ? .secondary : .primary)
                                        .italic(line.isPartial)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .id(line.id)
                            }
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.hidden)
                .onChange(of: lines.count) {
                    if let lastLine = lines.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastLine.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    /// Formats elapsed seconds as MM:SS (e.g., "03:45").
    private func formatElapsedTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
