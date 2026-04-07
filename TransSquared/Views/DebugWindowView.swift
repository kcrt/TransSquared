#if DEBUG
import SwiftUI

// MARK: - Sidebar Item

/// Navigation items for the debug inspector sidebar.
private enum DebugPage: Hashable {
    case session
    case sentenceBuffer
    case slot(Int)
    case entries
    case entry(UUID)
}

// MARK: - Main View

/// Debug window that visualizes the internal state of queues, translation slots, and transcript entries.
struct DebugWindowView: View {
    let viewModel: SessionViewModel
    @State private var selection: DebugPage? = .session

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
                .font(.system(.body, design: .monospaced))
        }
        .frame(minWidth: 650, idealWidth: 850, minHeight: 450, idealHeight: 650)
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $selection) {
            Section("Overview") {
                Label {
                    HStack {
                        Text("Session")
                        Spacer()
                        Circle()
                            .fill(viewModel.isSessionActive ? .green : .gray)
                            .frame(width: 8, height: 8)
                    }
                } icon: {
                    Image(systemName: "play.circle")
                }
                .tag(DebugPage.session)

                Label {
                    HStack {
                        Text("Sentence Buffer")
                        Spacer()
                        if !viewModel.pendingSentenceBuffer.isEmpty {
                            Text("\(viewModel.pendingSentenceBuffer.count)")
                                .font(.caption)
                                .monospacedDigit()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.orange.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "text.alignleft")
                }
                .tag(DebugPage.sentenceBuffer)
            }

            Section("Translation Slots") {
                ForEach(Array(viewModel.translationSlots.enumerated()), id: \.offset) { index, slot in
                    Label {
                        HStack {
                            if index < viewModel.targetLanguageIdentifiers.count {
                                Text("Slot \(index) (\(viewModel.targetLanguageIdentifiers[index]))")
                            } else {
                                Text("Slot \(index)")
                            }
                            Spacer()
                            if slot.isProcessing {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 8, height: 8)
                            }
                            if !slot.queue.isEmpty {
                                Text("\(slot.queue.count)")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.orange.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                        }
                    } icon: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .tag(DebugPage.slot(index))
                }
            }

            Section("Entries (\(viewModel.entries.count))") {
                Label("All Entries", systemImage: "list.bullet")
                    .tag(DebugPage.entries)

                // Show last 30 entries in sidebar for quick navigation
                ForEach(sidebarEntries, id: \.entry.id) { item in
                    Label {
                        HStack(spacing: 4) {
                            Text("#\(item.index)")
                                .foregroundStyle(.secondary)
                            if item.entry.isSeparator {
                                Text("———")
                                    .foregroundStyle(.tertiary)
                            } else if !item.entry.source.text.isEmpty {
                                if let partial = item.entry.pendingPartial, !partial.isEmpty {
                                    (Text(item.entry.source.text) + Text(partial).foregroundStyle(.orange))
                                        .lineLimit(1)
                                } else {
                                    Text(item.entry.source.text)
                                        .lineLimit(1)
                                }
                            } else {
                                Text(item.entry.pendingPartial ?? "…")
                                    .lineLimit(1)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            entryBadge(item.entry)
                        }
                    } icon: {
                        Image(systemName: item.entry.isSeparator ? "minus" :
                                item.entry.isCommitted ? "checkmark.circle.fill" : "pencil.circle")
                            .foregroundColor(item.entry.isSeparator ? .gray :
                                                item.entry.isCommitted ? .green : .orange)
                    }
                    .tag(DebugPage.entry(item.entry.id))
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220)
    }

    // MARK: - Sidebar Data

    private struct IndexedEntry {
        let index: Int
        let entry: TranscriptEntry
    }

    private var sidebarEntries: [IndexedEntry] {
        let recent = viewModel.entries.suffix(30)
        let startIdx = viewModel.entries.count - recent.count
        return recent.enumerated().map { IndexedEntry(index: startIdx + $0.offset, entry: $0.element) }
    }

    // MARK: - Detail Router

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .session:
            SessionDetailView(viewModel: viewModel)
        case .sentenceBuffer:
            SentenceBufferDetailView(viewModel: viewModel)
        case .slot(let index):
            if index < viewModel.translationSlots.count {
                SlotDetailView(viewModel: viewModel, slotIndex: index)
            } else {
                Text("Slot not found")
                    .foregroundStyle(.secondary)
            }
        case .entries:
            EntriesListDetailView(viewModel: viewModel, onSelectEntry: { id in
                selection = .entry(id)
            })
        case .entry(let id):
            if let idx = viewModel.entryIndex(for: id) {
                EntryDetailView(viewModel: viewModel, entryIndex: idx)
            } else {
                Text("Entry not found")
                    .foregroundStyle(.secondary)
            }
        case nil:
            Text("Select an item from the sidebar")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sidebar Helpers

    @ViewBuilder
    private func entryBadge(_ entry: TranscriptEntry) -> some View {
        if entry.isSeparator {
            EmptyView()
        } else if !entry.isCommitted {
            Image(systemName: "circle.dotted")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Session Detail

private struct SessionDetailView: View {
    let viewModel: SessionViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Session State")
                    .font(.system(.title2, design: .monospaced, weight: .bold))

                Grid(alignment: .leading, verticalSpacing: 6) {
                    LabeledGridRow("Active", value: viewModel.isSessionActive ? "YES" : "NO",
                                   color: viewModel.isSessionActive ? .green : .secondary)
                    LabeledGridRow("Display Mode", value: viewModel.displayMode.rawValue)
                    Divider()
                    LabeledGridRow("Source Locale", value: viewModel.sourceLocaleIdentifier)
                    LabeledGridRow("Target Count", value: "\(viewModel.targetCount)")
                    LabeledGridRow("Target Languages",
                                   value: viewModel.targetLanguageIdentifiers.prefix(viewModel.targetCount).joined(separator: ", "))
                    Divider()
                    LabeledGridRow("Elapsed Time", value: String(format: "%.1fs", viewModel.currentElapsedTime))
                    LabeledGridRow("Accumulated", value: String(format: "%.1fs", viewModel.accumulatedElapsedTime))
                    LabeledGridRow("Session Start",
                                   value: viewModel.sessionStartDate.map { "\($0.formatted(.dateTime.hour().minute().second()))" } ?? "—")
                    LabeledGridRow("Segment Index", value: "\(viewModel.segmentIndex)")
                    Divider()
                    LabeledGridRow("Entry Count", value: "\(viewModel.entries.count)")
                    LabeledGridRow("Audio Level", value: String(format: "%.2f", viewModel.audioLevelMonitor.levels.last ?? 0))
                    LabeledGridRow("Recording Segments", value: "\(viewModel.recordingSegments.count)")
                    LabeledGridRow("File Transcribing", value: viewModel.isTranscribingFile ? "YES" : "NO",
                                   color: viewModel.isTranscribingFile ? .orange : .secondary)
                }
            }
            .padding()
        }
    }
}

// MARK: - Sentence Buffer Detail

private struct SentenceBufferDetailView: View {
    let viewModel: SessionViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sentence Buffer")
                    .font(.system(.title2, design: .monospaced, weight: .bold))

                GroupBox("Buffer Content") {
                    if viewModel.pendingSentenceBuffer.isEmpty {
                        Text("(empty)")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    } else {
                        Text(viewModel.pendingSentenceBuffer)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    }
                }

                Grid(alignment: .leading, verticalSpacing: 6) {
                    LabeledGridRow("Buffer Length", value: "\(viewModel.pendingSentenceBuffer.count) chars")
                    LabeledGridRow("Boundary Generation", value: "\(viewModel.sentenceBoundaryGeneration)")
                    LabeledGridRow("Boundary Timer", value: viewModel.sentenceBoundaryTimer != nil ? "Active" : "nil",
                                   color: viewModel.sentenceBoundaryTimer != nil ? .orange : .secondary)
                    LabeledGridRow("Boundary Seconds", value: String(format: "%.1fs", viewModel.sentenceBoundarySeconds))
                }
            }
            .padding()
        }
    }
}

// MARK: - Slot Detail

private struct SlotDetailView: View {
    let viewModel: SessionViewModel
    let slotIndex: Int

    private var slot: TranslationSlot { viewModel.translationSlots[slotIndex] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Slot \(slotIndex)")
                        .font(.system(.title2, design: .monospaced, weight: .bold))
                    if slotIndex < viewModel.targetLanguageIdentifiers.count {
                        Text("(\(viewModel.targetLanguageIdentifiers[slotIndex]))")
                            .font(.system(.title3, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusBadge
                }

                Grid(alignment: .leading, verticalSpacing: 6) {
                    LabeledGridRow("Processing", value: slot.isProcessing ? "YES" : "NO",
                                   color: slot.isProcessing ? .green : .secondary)
                    LabeledGridRow("Queue Size", value: "\(slot.queue.count)",
                                   color: slot.queue.isEmpty ? .secondary : .orange)
                    Divider()
                    LabeledGridRow("Partial Entry ID",
                                   value: slot.partialEntryID?.uuidString.prefix(8).description ?? "—")
                    LabeledGridRow("Pending Partial", value: slot.pendingPartialText ?? "—")
                    LabeledGridRow("Pending Elapsed",
                                   value: slot.pendingPartialElapsedTime.map { String(format: "%.1fs", $0) } ?? "—")
                    LabeledGridRow("Debounce Gen", value: "\(slot.partialDebounceGeneration)")
                    LabeledGridRow("Timer Active", value: slot.partialTranslationTimer != nil ? "YES" : "NO",
                                   color: slot.partialTranslationTimer != nil ? .orange : .secondary)
                    Divider()
                    LabeledGridRow("Config", value: slot.config != nil ? "Set" : "nil",
                                   color: slot.config != nil ? .green : .secondary)
                }

                if !slot.queue.isEmpty {
                    Text("Queue Items")
                        .font(.system(.headline, design: .monospaced))
                        .padding(.top, 8)

                    ForEach(Array(slot.queue.enumerated()), id: \.offset) { qIdx, item in
                        queueItemCard(index: qIdx, item: item)
                    }
                } else {
                    GroupBox {
                        Text("Queue is empty")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 6) {
            if slot.isProcessing {
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Processing").foregroundStyle(.green)
                }
                .font(.system(.caption, design: .monospaced))
            }
            if !slot.queue.isEmpty {
                Text("\(slot.queue.count) queued")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
    }

    @ViewBuilder
    private func queueItemCard(index: Int, item: TranslationQueueItem) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("[\(index)]")
                        .foregroundStyle(.secondary)
                    Text(item.isPartial ? "PARTIAL" : "FINAL")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(item.isPartial ? Color.yellow.opacity(0.3) : Color.blue.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Spacer()
                    Text(item.entryID.uuidString.prefix(8))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let elapsed = item.elapsedTime {
                        Text(String(format: "%.1fs", elapsed))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.sentence)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(2)
        }
    }
}

// MARK: - Entries List Detail

private struct EntriesListDetailView: View {
    let viewModel: SessionViewModel
    var onSelectEntry: (UUID) -> Void

    var body: some View {
        if viewModel.entries.isEmpty {
            ContentUnavailableView("No Entries", systemImage: "doc.text",
                                   description: Text("Entries will appear here during transcription."))
        } else {
            List {
                ForEach(Array(viewModel.entries.enumerated()), id: \.element.id) { index, entry in
                    Button {
                        onSelectEntry(entry.id)
                    } label: {
                        entryRow(index: index, entry: entry)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func entryRow(index: Int, entry: TranscriptEntry) -> some View {
        HStack(spacing: 8) {
            Text("#\(index)")
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
                .monospacedDigit()

            if entry.isSeparator {
                Text("——— separator ———")
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        entryStateBadge(entry)
                        if let elapsed = entry.elapsedTime {
                            Text(elapsed.formattedMMSS)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if let duration = entry.duration {
                            Text(String(format: "(%.1fs)", duration))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.id.uuidString.prefix(8))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.quaternary)
                    }
                    if !entry.source.text.isEmpty {
                        Text(entry.source.text)
                            .lineLimit(1)
                    }
                    if let partial = entry.pendingPartial, !partial.isEmpty {
                        Text(partial)
                            .lineLimit(1)
                            .foregroundStyle(.orange)
                    }
                    if entry.source.text.isEmpty && (entry.pendingPartial ?? "").isEmpty {
                        Text("…")
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    if !entry.translations.isEmpty {
                        let slots = entry.translations.keys.sorted()
                        Text("T[\(slots.map(String.init).joined(separator: ","))]: \(entry.translations[slots[0]]?.text ?? "")")
                            .lineLimit(1)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func entryStateBadge(_ entry: TranscriptEntry) -> some View {
        Text(entry.isCommitted ? "COMMITTED" : "BUILDING")
            .font(.system(.caption2, design: .monospaced, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(entry.isCommitted ? Color.green.opacity(0.3) : Color.yellow.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Entry Detail

private struct EntryDetailView: View {
    let viewModel: SessionViewModel
    let entryIndex: Int

    private var entry: TranscriptEntry { viewModel.entries[entryIndex] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Entry #\(entryIndex)")
                        .font(.system(.title2, design: .monospaced, weight: .bold))
                    Spacer()
                    entryStateBadge
                }

                Grid(alignment: .leading, verticalSpacing: 6) {
                    LabeledGridRow("ID", value: entry.id.uuidString)
                    LabeledGridRow("Separator", value: entry.isSeparator ? "YES" : "NO")
                    LabeledGridRow("Committed", value: entry.isCommitted ? "YES" : "NO",
                                   color: entry.isCommitted ? .green : .orange)
                    Divider()
                    LabeledGridRow("Elapsed Time",
                                   value: entry.elapsedTime.map { String(format: "%.2fs (%@)", $0, $0.formattedMMSS) } ?? "—")
                    LabeledGridRow("Duration",
                                   value: entry.duration.map { String(format: "%.2fs", $0) } ?? "—")
                }

                if !entry.isSeparator {
                    GroupBox("Source Text") {
                        VStack(alignment: .leading, spacing: 4) {
                            if entry.source.text.isEmpty {
                                Text("(empty)")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(entry.source.text)
                                    .textSelection(.enabled)
                            }
                            HStack {
                                Text("ID: \(entry.source.id.uuidString.prefix(8))")
                                Text("Partial: \(entry.source.isPartial ? "YES" : "NO")")
                            }
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }

                    if let partial = entry.pendingPartial, !partial.isEmpty {
                        GroupBox("Pending Partial") {
                            Text(partial)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(4)
                        }
                    }

                    if !entry.translations.isEmpty {
                        Text("Translations")
                            .font(.system(.headline, design: .monospaced))
                            .padding(.top, 4)

                        ForEach(entry.translations.keys.sorted(), id: \.self) { slot in
                            if let trans = entry.translations[slot] {
                                translationCard(slot: slot, trans: trans)
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var entryStateBadge: some View {
        let label = entry.isSeparator ? "SEPARATOR" : (entry.isCommitted ? "COMMITTED" : "BUILDING")
        let color: Color = entry.isSeparator ? .gray : (entry.isCommitted ? .green : .yellow)
        Text(label)
            .font(.system(.caption, design: .monospaced, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func translationCard(slot: Int, trans: TransString) -> some View {
        let langId = slot < viewModel.targetLanguageIdentifiers.count
            ? viewModel.targetLanguageIdentifiers[slot] : "?"
        GroupBox("Slot \(slot) — \(langId)") {
            VStack(alignment: .leading, spacing: 4) {
                Text(trans.text)
                    .foregroundStyle(trans.isPartial ? .orange : .primary)
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    Text("ID: \(trans.id.uuidString.prefix(8))")
                    Text(trans.isPartial ? "PARTIAL" : "FINAL")
                        .foregroundStyle(trans.isPartial ? .orange : .green)
                    if let finalizedAt = trans.finalizedAt {
                        Text("Finalized: \(finalizedAt.formatted(.dateTime.hour().minute().second()))")
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

// MARK: - Reusable Components

private struct LabeledGridRow: View {
    let label: String
    let value: String
    var color: Color = .primary

    init(_ label: String, value: String, color: Color = .primary) {
        self.label = label
        self.value = value
        self.color = color
    }

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
        }
    }
}

// MARK: - Debug Window Controller

/// Manages the debug inspector window as a standard utility panel.
@MainActor
final class DebugWindowController {
    private var window: NSWindow?

    func toggle(viewModel: SessionViewModel) {
        if let window, window.isVisible {
            close()
        } else {
            show(viewModel: viewModel)
        }
    }

    func show(viewModel: SessionViewModel) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Debug Inspector"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.contentView = NSHostingView(
            rootView: DebugWindowView(viewModel: viewModel)
        )
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        self.window = panel
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }
}

// MARK: - Preview

#Preview("Debug Inspector") {
    let vm = SessionViewModel()

    // Populate sample data for preview
    let _ = {
        // Add some entries
        var entry1 = TranscriptEntry(
            source: TransString(text: "こんにちは、今日はいい天気ですね。", isPartial: false),
            translations: [
                0: TransString(text: "Hello, nice weather today.", isPartial: false, finalizedAt: Date())
            ],
            elapsedTime: 5.0,
            duration: 2.3,
            isCommitted: true
        )
        vm.entries.append(entry1)

        var entry2 = TranscriptEntry(
            source: TransString(text: "明日の予定は", isPartial: false),
            pendingPartial: "どうなっていますか",
            translations: [
                0: TransString(text: "What are the plans for...", isPartial: true)
            ],
            elapsedTime: 12.0
        )
        vm.entries.append(entry2)
        vm.rebuildEntryIndexMap()

        // Set up translation slot with queue items
        var slot = TranslationSlot()
        slot.isProcessing = true
        slot.queue = [
            TranslationQueueItem(sentence: "テスト文です。", entryID: entry1.id, isPartial: false, elapsedTime: 5.0),
            TranslationQueueItem(sentence: "パーシャルテスト", entryID: entry2.id, isPartial: true, elapsedTime: 12.0),
        ]
        slot.pendingPartialText = "デバウンス待ち"
        slot.partialDebounceGeneration = 3
        vm.translationSlots = [slot]

        vm.pendingSentenceBuffer = "途中の文章がここに"
    }()

    return DebugWindowView(viewModel: vm)
        .frame(width: 850, height: 650)
}
#endif
