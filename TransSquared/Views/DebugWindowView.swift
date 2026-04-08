#if DEBUG
import SwiftUI

// MARK: - Sidebar Item

/// Navigation items for the debug inspector sidebar.
private enum DebugPage: Hashable {
    case health
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
    @State private var selection: DebugPage? = .health

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
                Label("Health Monitor", systemImage: "heart.text.clipboard")
                    .tag(DebugPage.health)

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
                                    Text("\(item.entry.source.text)\(Text(partial).foregroundStyle(.orange))")
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
        case .health:
            HealthMonitorDetailView(viewModel: viewModel)
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
            EntryDetailView(viewModel: viewModel, entryID: id)
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

// MARK: - Memory Monitor

/// Samples resident memory at a fixed 1-second interval, independent of SwiftUI view lifecycle.
/// Keeping this as a standalone `@Observable` class prevents `@State` resets caused by
/// parent view re-evaluations (which happen frequently when `SessionViewModel` changes).
@Observable
@MainActor
private final class MemoryMonitor {
    struct Sample {
        let date: Date
        let bytes: UInt64
    }

    private(set) var samples: [Sample] = []
    private var timer: Task<Void, Never>?
    static let maxSamples = 60

    var currentBytes: UInt64 { samples.last?.bytes ?? 0 }

    /// Memory growth rate in bytes/second, computed over the full sample window.
    var growthRate: Double {
        guard samples.count >= 2,
              let first = samples.first,
              let last = samples.last else { return 0 }
        let elapsed = last.date.timeIntervalSince(first.date)
        guard elapsed > 1 else { return 0 }
        return Double(Int64(last.bytes) - Int64(first.bytes)) / elapsed
    }

    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.recordSample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func recordSample() {
        guard let bytes = Self.residentMemoryBytes() else { return }
        samples.append(Sample(date: Date(), bytes: bytes))
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
    }

    private static func residentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rawPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rawPtr, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : nil
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / (1024 * 1024)
    if mb >= 1024 {
        return String(format: "%.1f GB", mb / 1024)
    }
    return String(format: "%.1f MB", mb)
}

private func formatGrowthRate(_ rate: Double) -> String {
    let absMB = abs(rate) / (1024 * 1024)
    let sign = rate >= 0 ? "+" : "-"
    if absMB >= 1 {
        return String(format: "%@%.1f MB/s", sign, absMB)
    }
    let absKB = abs(rate) / 1024
    return String(format: "%@%.0f KB/s", sign, absKB)
}

private func growthRateColor(_ rate: Double) -> Color {
    let mbPerSec = rate / (1024 * 1024)
    if mbPerSec > 1 { return .red }
    if mbPerSec > 0.1 { return .orange }
    return .secondary
}

// MARK: - Health Monitor Detail

private struct HealthMonitorDetailView: View {
    let viewModel: SessionViewModel
    @State private var monitor = MemoryMonitor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Health Monitor")
                        .font(.system(.title2, design: .monospaced, weight: .bold))
                    Spacer()
                    if monitor.growthRate > 1_000_000 {
                        Text("MEMORY ALERT")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.red.opacity(0.3))
                            .clipShape(Capsule())
                    }
                }

                // Memory Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Memory")
                            .font(.system(.headline, design: .monospaced))

                        Grid(alignment: .leading, verticalSpacing: 6) {
                            LabeledGridRow("Resident Memory", value: formatBytes(monitor.currentBytes))
                            LabeledGridRow("Growth Rate",
                                           value: formatGrowthRate(monitor.growthRate),
                                           color: growthRateColor(monitor.growthRate))
                            LabeledGridRow("Samples", value: "\(monitor.samples.count)/\(MemoryMonitor.maxSamples)")
                        }

                        // Sparkline of memory values
                        if monitor.samples.count >= 2 {
                            memorySparkline
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                // Entries Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Entries")
                            .font(.system(.headline, design: .monospaced))

                        let committed = viewModel.entries.filter { $0.isCommitted }.count
                        let separators = viewModel.entries.filter { $0.isSeparator }.count
                        let building = viewModel.entries.count - committed - separators

                        Grid(alignment: .leading, verticalSpacing: 6) {
                            LabeledGridRow("Total", value: "\(viewModel.entries.count)")
                            LabeledGridRow("Committed", value: "\(committed)")
                            LabeledGridRow("Building", value: "\(building)",
                                           color: building > 0 ? .orange : .secondary)
                            LabeledGridRow("Separators", value: "\(separators)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                // Translation Stats Section
                translationStatsSection
            }
            .padding()
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    // MARK: - Memory Sparkline

    @ViewBuilder
    private var memorySparkline: some View {
        let values = monitor.samples.map { Double($0.bytes) }
        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 1
        let range = max(maxVal - minVal, 1)

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text(formatBytes(UInt64(maxVal)))
                Spacer()
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)

            Canvas { context, size in
                guard values.count >= 2 else { return }
                var path = Path()
                for (i, val) in values.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = size.height * (1.0 - CGFloat((val - minVal) / range))
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(path, with: .color(growthRateColor(monitor.growthRate)), lineWidth: 1.5)
            }
            .frame(height: 40)
            .background(Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            HStack {
                Text(formatBytes(UInt64(minVal)))
                Spacer()
                Text("last \(monitor.samples.count)s")
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Translation Stats

    @ViewBuilder
    private var translationStatsSection: some View {
        ForEach(0..<viewModel.translationSlots.count, id: \.self) { slot in
            let langId = slot < viewModel.targetLanguageIdentifiers.count
                ? viewModel.targetLanguageIdentifiers[slot] : "?"
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Slot \(slot) (\(langId))")
                            .font(.system(.headline, design: .monospaced))
                        Spacer()
                        if viewModel.translationSlots[slot].isProcessing {
                            Circle().fill(.green).frame(width: 8, height: 8)
                        }
                    }

                    Grid(alignment: .leading, verticalSpacing: 6) {
                        LabeledGridRow("Queue Size", value: "\(viewModel.translationSlots[slot].queue.count)",
                                       color: viewModel.translationSlots[slot].queue.count > 5 ? .red : .primary)
                        LabeledGridRow("Success", value: "\(viewModel.debugTranslationSuccessCount[slot] ?? 0)")
                        LabeledGridRow("Failed", value: "\(viewModel.debugTranslationFailureCount[slot] ?? 0)",
                                       color: (viewModel.debugTranslationFailureCount[slot] ?? 0) > 0 ? .red : .secondary)
                        LabeledGridRow("Re-enqueued", value: "\(viewModel.debugTranslationReenqueueCount[slot] ?? 0)",
                                       color: (viewModel.debugTranslationReenqueueCount[slot] ?? 0) > 0 ? .orange : .secondary)
                        LabeledGridRow("Peak Queue", value: "\(viewModel.debugPeakQueueSize[slot] ?? 0)",
                                       color: (viewModel.debugPeakQueueSize[slot] ?? 0) > 10 ? .red : .primary)
                        LabeledGridRow("Recently Completed", value: "\(viewModel.translationSlots[slot].recentlyCompleted.count)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
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
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let visibleCompleted = slot.recentlyCompleted.filter {
                context.date.timeIntervalSince($0.completedAt) < 5
            }
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
                        LabeledGridRow("Config", value: slotIndex < viewModel.translationConfigs.count && viewModel.translationConfigs[slotIndex] != nil ? "Set" : "nil",
                                       color: slotIndex < viewModel.translationConfigs.count && viewModel.translationConfigs[slotIndex] != nil ? .green : .secondary)
                    }

                    // Currently translating
                    if let current = slot.currentItem {
                        sectionHeader("Translating", systemImage: "arrow.trianglehead.2.clockwise", color: .green)
                        translatingCard(item: current)
                    }

                    // Queue
                    if !slot.queue.isEmpty {
                        sectionHeader("Queue (\(slot.queue.count))", systemImage: "tray.full", color: .orange)
                        ForEach(Array(slot.queue.enumerated()), id: \.offset) { qIdx, item in
                            queueItemCard(index: qIdx, item: item)
                        }
                    }

                    // Recently completed (visible for 5 seconds)
                    if !visibleCompleted.isEmpty {
                        sectionHeader("Done", systemImage: "checkmark.circle", color: .green)
                        ForEach(visibleCompleted.reversed()) { completed in
                            completedCard(item: completed, now: context.date)
                        }
                    }

                    // Empty state
                    if slot.currentItem == nil && slot.queue.isEmpty && visibleCompleted.isEmpty {
                        GroupBox {
                            Text("Idle")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(8)
                        }
                    }
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(.headline, design: .monospaced))
            .foregroundStyle(color)
            .padding(.top, 8)
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
    private func translatingCard(item: TranslationQueueItem) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    partialFinalBadge(isPartial: item.isPartial)
                    Spacer()
                    itemMeta(entryID: item.entryID, elapsedTime: item.elapsedTime)
                }
                Text(item.sentence)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(2)
        }
    }

    @ViewBuilder
    private func queueItemCard(index: Int, item: TranslationQueueItem) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("[\(index)]")
                        .foregroundStyle(.secondary)
                    partialFinalBadge(isPartial: item.isPartial)
                    Spacer()
                    itemMeta(entryID: item.entryID, elapsedTime: item.elapsedTime)
                }
                Text(item.sentence)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(2)
        }
    }

    @ViewBuilder
    private func completedCard(item: CompletedTranslationItem, now: Date) -> some View {
        let elapsed = now.timeIntervalSince(item.completedAt)
        // Fully visible for 3s, fade out over the last 2s.
        let opacity = max(0, min(1, (5 - elapsed) / 2))
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    partialFinalBadge(isPartial: item.source.isPartial)
                    Spacer()
                    itemMeta(entryID: item.source.entryID, elapsedTime: item.source.elapsedTime)
                }
                Text(item.source.sentence)
                    .foregroundStyle(.secondary)
                Text(item.resultText)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(2)
        }
        .opacity(opacity)
    }

    // MARK: - Shared Badge Helpers

    @ViewBuilder
    private func partialFinalBadge(isPartial: Bool) -> some View {
        Text(isPartial ? "PARTIAL" : "FINAL")
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isPartial ? Color.yellow.opacity(0.3) : Color.blue.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func itemMeta(entryID: UUID, elapsedTime: TimeInterval?) -> some View {
        HStack(spacing: 6) {
            Text(entryID.uuidString.prefix(8))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if let elapsed = elapsedTime {
                Text(String(format: "%.1fs", elapsed))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
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
    let entryID: UUID

    private var entryIndex: Int? { viewModel.entryIndex(for: entryID) }
    private var entry: TranscriptEntry? { entryIndex.map { viewModel.entries[$0] } }

    var body: some View {
        if let entry, let entryIndex {
            entryContent(entry: entry, index: entryIndex)
        } else {
            Text("Entry not found")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func entryContent(entry: TranscriptEntry, index: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Entry #\(index)")
                        .font(.system(.title2, design: .monospaced, weight: .bold))
                    Spacer()
                    entryStateBadge(entry)
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
    private func entryStateBadge(_ entry: TranscriptEntry) -> some View {
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
        let entry1 = TranscriptEntry(
            source: TransString(text: "こんにちは、今日はいい天気ですね。", isPartial: false),
            translations: [
                0: TransString(text: "Hello, nice weather today.", isPartial: false, finalizedAt: Date())
            ],
            elapsedTime: 5.0,
            duration: 2.3,
            isCommitted: true
        )
        vm.entries.append(entry1)

        let entry2 = TranscriptEntry(
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
        slot.currentItem = TranslationQueueItem(sentence: "現在翻訳中の文です。", entryID: entry1.id, isPartial: false, elapsedTime: 7.0)
        slot.queue = [
            TranslationQueueItem(sentence: "テスト文です。", entryID: entry1.id, isPartial: false, elapsedTime: 5.0),
            TranslationQueueItem(sentence: "パーシャルテスト", entryID: entry2.id, isPartial: true, elapsedTime: 12.0),
        ]
        slot.recentlyCompleted = [
            CompletedTranslationItem(source: TranslationQueueItem(sentence: "こんにちは", entryID: entry1.id, isPartial: false, elapsedTime: 3.0),
                                     resultText: "Hello", completedAt: Date().addingTimeInterval(-2)),
        ]
        vm.translationSlots = [slot]

        vm.pendingSentenceBuffer = "途中の文章がここに"
    }()

    return DebugWindowView(viewModel: vm)
        .frame(width: 850, height: 650)
}
#endif
