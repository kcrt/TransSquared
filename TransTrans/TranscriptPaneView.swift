import SwiftUI

/// A reusable scrollable pane that displays transcript lines with auto-scroll.
/// Used by both the source (transcription) and target (translation) panes.
struct TranscriptPaneView: View {
    var lines: [TranscriptLine]
    var fontSize: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.system(size: fontSize))
                            .foregroundStyle(line.isPartial ? .secondary : .primary)
                            .italic(line.isPartial)
                            .id(line.id)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
