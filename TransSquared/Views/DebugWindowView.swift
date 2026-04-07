#if DEBUG
import SwiftUI

/// Debug window that visualizes the internal state of queues, translation slots, and transcript entries.
struct DebugWindowView: View {
    let viewModel: SessionViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sessionStateSection
                sentenceBufferSection
                translationSlotsSection
                entriesSummarySection
            }
            .padding()
        }
        .frame(minWidth: 500, idealWidth: 700, minHeight: 400, idealHeight: 600)
        .font(.system(.body, design: .monospaced))
    }

    // MARK: - Session State

    @ViewBuilder
    private var sessionStateSection: some View {
        DebugSection(title: "Session State") {
            LabeledRow("Active", value: viewModel.isSessionActive ? "YES" : "NO",
                        color: viewModel.isSessionActive ? .green : .secondary)
            LabeledRow("Display Mode", value: viewModel.displayMode.rawValue)
            LabeledRow("Source Locale", value: viewModel.sourceLocaleIdentifier)
            LabeledRow("Target Count", value: "\(viewModel.targetCount)")
            LabeledRow("Target Languages",
                        value: viewModel.targetLanguageIdentifiers.prefix(viewModel.targetCount).joined(separator: ", "))
            LabeledRow("Elapsed Time", value: String(format: "%.1fs", viewModel.currentElapsedTime))
            LabeledRow("Accumulated", value: String(format: "%.1fs", viewModel.accumulatedElapsedTime))
            LabeledRow("Session Start", value: viewModel.sessionStartDate.map { "\($0.formatted(.dateTime.hour().minute().second()))" } ?? "—")
            LabeledRow("Segment Index", value: "\(viewModel.segmentIndex)")
            LabeledRow("Entry Count", value: "\(viewModel.entries.count)")
            LabeledRow("Audio Level", value: String(format: "%.2f", viewModel.audioLevelMonitor.levels.last ?? 0))
        }
    }

    // MARK: - Sentence Buffer

    @ViewBuilder
    private var sentenceBufferSection: some View {
        DebugSection(title: "Sentence Buffer") {
            if viewModel.pendingSentenceBuffer.isEmpty {
                Text("(empty)")
                    .foregroundStyle(.secondary)
            } else {
                Text(viewModel.pendingSentenceBuffer)
                    .textSelection(.enabled)
            }
            LabeledRow("Boundary Gen", value: "\(viewModel.sentenceBoundaryGeneration)")
            LabeledRow("Boundary Timer", value: viewModel.sentenceBoundaryTimer != nil ? "Active" : "nil",
                        color: viewModel.sentenceBoundaryTimer != nil ? .orange : .secondary)
        }
    }

    // MARK: - Translation Slots

    @ViewBuilder
    private var translationSlotsSection: some View {
        DebugSection(title: "Translation Slots (\(viewModel.translationSlots.count))") {
            ForEach(Array(viewModel.translationSlots.enumerated()), id: \.offset) { index, slot in
                translationSlotView(index: index, slot: slot)
                if index < viewModel.translationSlots.count - 1 {
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func translationSlotView(index: Int, slot: TranslationSlot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Slot \(index)")
                    .font(.system(.headline, design: .monospaced))
                if index < viewModel.targetLanguageIdentifiers.count {
                    Text("(\(viewModel.targetLanguageIdentifiers[index]))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge(isProcessing: slot.isProcessing, queueCount: slot.queue.count)
            }

            LabeledRow("Processing", value: slot.isProcessing ? "YES" : "NO",
                        color: slot.isProcessing ? .green : .secondary)
            LabeledRow("Queue Size", value: "\(slot.queue.count)",
                        color: slot.queue.isEmpty ? .secondary : .orange)
            LabeledRow("Partial Entry ID", value: slot.partialEntryID?.uuidString.prefix(8).description ?? "—")
            LabeledRow("Pending Partial", value: slot.pendingPartialText ?? "—")
            LabeledRow("Debounce Gen", value: "\(slot.partialDebounceGeneration)")
            LabeledRow("Timer Active", value: slot.partialTranslationTimer != nil ? "YES" : "NO",
                        color: slot.partialTranslationTimer != nil ? .orange : .secondary)
            LabeledRow("Config", value: slot.config != nil ? "Set" : "nil",
                        color: slot.config != nil ? .green : .secondary)

            if !slot.queue.isEmpty {
                Text("Queue Items:")
                    .font(.system(.subheadline, design: .monospaced))
                    .padding(.top, 4)
                ForEach(Array(slot.queue.enumerated()), id: \.offset) { qIdx, item in
                    queueItemView(index: qIdx, item: item)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func queueItemView(index: Int, item: TranslationQueueItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("[\(index)]")
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.isPartial ? "PARTIAL" : "FINAL")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(item.isPartial ? Color.yellow.opacity(0.3) : Color.blue.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text(item.entryID.uuidString.prefix(8))
                        .foregroundStyle(.secondary)
                        .font(.system(.caption, design: .monospaced))
                    if let elapsed = item.elapsedTime {
                        Text(String(format: "%.1fs", elapsed))
                            .foregroundStyle(.secondary)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                Text(item.sentence)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, 16)
    }

    // MARK: - Entries Summary

    @ViewBuilder
    private var entriesSummarySection: some View {
        DebugSection(title: "Entries (\(viewModel.entries.count))") {
            if viewModel.entries.isEmpty {
                Text("(no entries)")
                    .foregroundStyle(.secondary)
            } else {
                // Show last 20 entries
                let displayEntries = viewModel.entries.suffix(20)
                let startIndex = viewModel.entries.count - displayEntries.count
                if startIndex > 0 {
                    Text("... \(startIndex) earlier entries omitted ...")
                        .foregroundStyle(.secondary)
                        .italic()
                }
                ForEach(Array(displayEntries.enumerated()), id: \.offset) { offset, entry in
                    entryRow(index: startIndex + offset, entry: entry)
                    if offset < displayEntries.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func entryRow(index: Int, entry: TranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("#\(index)")
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
                Text(entry.id.uuidString.prefix(8))
                    .foregroundStyle(.secondary)
                    .font(.system(.caption, design: .monospaced))
                if entry.isSeparator {
                    Text("SEPARATOR")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.gray.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                if entry.isCommitted {
                    Text("COMMITTED")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                if !entry.isCommitted && !entry.isSeparator {
                    Text("BUILDING")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.yellow.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                if let elapsed = entry.elapsedTime {
                    Text(elapsed.formattedMMSS)
                        .foregroundStyle(.secondary)
                        .font(.system(.caption, design: .monospaced))
                }
                if let duration = entry.duration {
                    Text(String(format: "(%.1fs)", duration))
                        .foregroundStyle(.secondary)
                        .font(.system(.caption, design: .monospaced))
                }
            }

            if !entry.isSeparator {
                if !entry.source.text.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        Text("SRC")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.blue)
                            .frame(width: 30)
                        Text(entry.source.text)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, 46)
                }
                if let partial = entry.pendingPartial, !partial.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        Text("PTL")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.orange)
                            .frame(width: 30)
                        Text(partial)
                            .lineLimit(2)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, 46)
                }
                ForEach(Array(entry.translations.sorted(by: { $0.key < $1.key })), id: \.key) { slot, trans in
                    HStack(alignment: .top, spacing: 4) {
                        Text("T\(slot)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(trans.isPartial ? .orange : .green)
                            .frame(width: 30)
                        Text(trans.text)
                            .lineLimit(2)
                            .foregroundStyle(trans.isPartial ? .orange : .primary)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, 46)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusBadge(isProcessing: Bool, queueCount: Int) -> some View {
        HStack(spacing: 4) {
            if isProcessing {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Processing")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green)
            }
            if queueCount > 0 {
                Text("\(queueCount) queued")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

// MARK: - Reusable Components

private struct DebugSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.title3, design: .monospaced, weight: .bold))
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    var color: Color = .primary

    init(_ label: String, value: String, color: Color = .primary) {
        self.label = label
        self.value = value
        self.color = color
    }

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .trailing)
            Text(value)
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }
}
#endif
