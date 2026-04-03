import SwiftUI

/// A reusable scrollable pane that displays transcript lines with auto-scroll.
/// Used by both the source (transcription) and target (translation) panes.
struct TranscriptPaneView: View {
    var lines: [TranscriptLine]
    var fontSize: CGFloat
    var placeholder: String?
    var showElapsedTime: Bool = false
    var isEditable: Bool = false
    var onLineEdited: ((UUID, String) -> Void)?
    /// Called when a timestamp is tapped; passes the sentenceID of the tapped line.
    var onTimestampTapped: ((UUID) -> Void)?
    /// The sentenceID currently highlighted across all panes.
    var highlightedSentenceID: UUID?

    @State private var editingLineID: UUID?
    @State private var editText: String = ""
    @FocusState private var isEditing: Bool

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
                                lineRow(line)
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

    @ViewBuilder
    private func lineRow(_ line: TranscriptLine) -> some View {
        let isHighlighted = highlightedSentenceID != nil && line.sentenceID == highlightedSentenceID
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if showElapsedTime {
                if let elapsed = line.elapsedTime {
                    Text(formatElapsedTime(elapsed))
                        .font(.system(size: fontSize * 0.75, design: .monospaced))
                        .foregroundStyle(isHighlighted ? .secondary : .tertiary)
                        .frame(minWidth: 40, alignment: .trailing)
                        .onTapGesture {
                            if let sentenceID = line.sentenceID {
                                onTimestampTapped?(sentenceID)
                            }
                        }
                } else {
                    // Reserve column space for alignment when no timestamp is available.
                    Text("00:00")
                        .font(.system(size: fontSize * 0.75, design: .monospaced))
                        .frame(minWidth: 40, alignment: .trailing)
                        .hidden()
                }
            }

            if isEditable && editingLineID == line.id {
                TextField("", text: $editText, axis: .vertical)
                    .font(.system(size: fontSize))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($isEditing)
                    .onSubmit {
                        commitEdit(for: line)
                    }
                    .onExitCommand {
                        cancelEdit()
                    }
                    .onChange(of: isEditing) { _, focused in
                        if !focused {
                            commitEdit(for: line)
                        }
                    }
                    .task {
                        isEditing = true
                    }
            } else if isEditable && !line.isPartial && !line.isSeparator {
                Text(line.text)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) {
                        startEditing(line)
                    }
            } else {
                Text(line.text)
                    .font(.system(size: fontSize))
                    .foregroundStyle(line.isPartial ? .secondary : .primary)
                    .italic(line.isPartial)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(isHighlighted ? Color.accentColor.opacity(0.15) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func startEditing(_ line: TranscriptLine) {
        editText = line.text
        editingLineID = line.id
    }

    private func commitEdit(for line: TranscriptLine) {
        guard editingLineID == line.id else { return }
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != line.text {
            onLineEdited?(line.id, trimmed)
        }
        editingLineID = nil
        editText = ""
    }

    private func cancelEdit() {
        editingLineID = nil
        editText = ""
    }

    /// Formats elapsed seconds as MM:SS (e.g., "03:45").
    private func formatElapsedTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
