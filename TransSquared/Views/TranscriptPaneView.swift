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
    /// Whether playback is available for this pane (recording for source, TTS for translation).
    var canPlayback: Bool = false
    /// The entry ID currently being played back (for stop icon display).
    var playingEntryID: UUID?
    /// Called when the play button on a timestamp is tapped; passes elapsed time and entry ID.
    var onPlayFromTimestamp: ((TimeInterval, UUID) -> Void)?

    @State private var editingLineID: UUID?
    @State private var editText: String = ""
    @FocusState private var isEditing: Bool
    @State private var hoveredLineID: UUID?

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
                .onChange(of: lines.last?.text) {
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
                timestampColumn(line, isHighlighted: isHighlighted)
            }
            lineTextContent(line)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(isHighlighted ? Color.accentColor.opacity(0.15) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func timestampColumn(_ line: TranscriptLine, isHighlighted: Bool) -> some View {
        if let elapsed = line.elapsedTime {
            let showPlayButton = isHighlighted && canPlayback
                && hoveredLineID == line.id && line.sentenceID != nil
            ZStack {
                Text(elapsed.formattedMMSS)
                    .font(.system(size: fontSize * 0.75, design: .monospaced))
                    .foregroundStyle(isHighlighted ? .secondary : .tertiary)
                    .opacity(showPlayButton ? 0 : 1)

                if showPlayButton, let sentenceID = line.sentenceID {
                    Image(systemName: playingEntryID == sentenceID ? "stop.fill" : "play.fill")
                        .font(.system(size: fontSize * 0.65))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel(playingEntryID == sentenceID ? "Stop" : "Play")
                }
            }
            .frame(minWidth: 40, alignment: .trailing)
            .accessibilityElement()
            .accessibilityLabel(elapsed.formattedMMSS)
            .accessibilityAddTraits(canPlayback ? .isButton : [])
            .onHover { isHovered in
                hoveredLineID = isHovered ? line.id : nil
            }
            .onTapGesture {
                guard let sentenceID = line.sentenceID else { return }
                if isHighlighted && canPlayback {
                    onPlayFromTimestamp?(elapsed, sentenceID)
                } else {
                    onTimestampTapped?(sentenceID)
                }
            }
        } else {
            Text("00:00")
                .font(.system(size: fontSize * 0.75, design: .monospaced))
                .frame(minWidth: 40, alignment: .trailing)
                .hidden()
        }
    }

    @ViewBuilder
    private func lineTextContent(_ line: TranscriptLine) -> some View {
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
                .onSubmit { commitEdit(for: line) }
                .onExitCommand { cancelEdit() }
                .onChange(of: isEditing) { _, focused in
                    if !focused { commitEdit(for: line) }
                }
                .task { isEditing = true }
        } else if isEditable && !line.isPartial && !line.isSeparator {
            Text(line.text)
                .font(.system(size: fontSize))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture(count: 2) {
                    startEditing(line)
                }
        } else {
            styledLineText(line)
                .font(.system(size: fontSize))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func styledLineText(_ line: TranscriptLine) -> Text {
        if let prefix = line.finalizedPrefix {
            let suffix = String(line.text.dropFirst(prefix.count))
            return Text(prefix).foregroundStyle(.primary)
                + Text(suffix).foregroundStyle(.secondary).italic()
        } else if line.isPartial {
            return Text(line.text).foregroundStyle(.secondary).italic()
        } else {
            return Text(line.text).foregroundStyle(.primary)
        }
    }

    // MARK: - Editing Helpers

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
}
