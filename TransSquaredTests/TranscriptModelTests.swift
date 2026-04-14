//
//  TranscriptModelTests.swift
//  TransSquaredTests
//

import Foundation
import Testing
@testable import TransSquared

// MARK: - TransString Tests

struct TransStringTests {

    @Test func defaultValues() {
        let s = TransString(text: "Hello", isPartial: false)
        #expect(s.text == "Hello")
        #expect(s.isPartial == false)
        #expect(s.finalizedAt == nil)
    }

    @Test func partialString() {
        let s = TransString(text: "typing...", isPartial: true)
        #expect(s.isPartial == true)
    }

    @Test func uniqueIDs() {
        let a = TransString(text: "A", isPartial: false)
        let b = TransString(text: "B", isPartial: false)
        #expect(a.id != b.id)
    }

    @Test func customID() {
        let customID = UUID()
        let s = TransString(id: customID, text: "Test", isPartial: false)
        #expect(s.id == customID)
    }
}

// MARK: - TranscriptEntry Tests

struct TranscriptEntryTests {

    @Test func defaultValues() {
        let entry = TranscriptEntry()
        #expect(entry.source.text.isEmpty)
        #expect(entry.pendingPartial == nil)
        #expect(entry.translations.isEmpty)
        #expect(entry.elapsedTime == nil)
        #expect(entry.duration == nil)
        #expect(entry.isSeparator == false)
        #expect(entry.isCommitted == false)
    }

    @Test func separatorEntry() {
        let entry = TranscriptEntry(isSeparator: true)
        #expect(entry.isSeparator == true)
    }

    @Test func sourceTranscriptLinesCommitted() {
        let entry = TranscriptEntry(
            source: TransString(text: "Hello world.", isPartial: false),
            elapsedTime: 10.0,
            duration: 2.0,
            isCommitted: true
        )
        let lines = entry.sourceTranscriptLines()
        #expect(lines.count == 1)
        #expect(lines[0].text == "Hello world.")
        #expect(lines[0].isPartial == false)
        #expect(lines[0].elapsedTime == 10.0)
        #expect(lines[0].sentenceID == entry.id)
    }

    @Test func sourceTranscriptLinesWithPendingPartialShowsCombinedLine() {
        let entry = TranscriptEntry(
            source: TransString(text: "Hello.", isPartial: false),
            pendingPartial: " How are"
        )
        let lines = entry.sourceTranscriptLines()
        #expect(lines.count == 1)
        #expect(lines[0].text == "Hello. How are")
        #expect(lines[0].isPartial == true)
        #expect(lines[0].finalizedPrefix == "Hello.")
    }

    @Test func sourceTranscriptLinesPartialOnly() {
        let entry = TranscriptEntry(pendingPartial: "Hello")
        let lines = entry.sourceTranscriptLines()
        #expect(lines.count == 1)
        #expect(lines[0].text == "Hello")
        #expect(lines[0].isPartial == true)
    }

    @Test func sourceTranscriptLinesEmptyReturnsEmpty() {
        let entry = TranscriptEntry()
        let lines = entry.sourceTranscriptLines()
        #expect(lines.isEmpty)
    }

    @Test func sourceTranscriptLinesUncommittedHasNoSentenceID() {
        let entry = TranscriptEntry(
            source: TransString(text: "Hello", isPartial: false),
            isCommitted: false
        )
        let lines = entry.sourceTranscriptLines()
        #expect(lines[0].sentenceID == nil)
    }

    @Test func separatorProducesSeparatorLine() {
        let entry = TranscriptEntry(isSeparator: true)
        let lines = entry.sourceTranscriptLines()
        #expect(lines.count == 1)
        #expect(lines[0].isSeparator == true)
    }

    @Test func translationTranscriptLine() {
        var entry = TranscriptEntry(isCommitted: true)
        entry.translations[0] = TransString(text: "Translated", isPartial: false, finalizedAt: Date())
        let line = entry.translationTranscriptLine(forSlot: 0)
        #expect(line != nil)
        #expect(line?.text == "Translated")
        #expect(line?.sentenceID == entry.id)
    }

    @Test func translationTranscriptLineNil() {
        let entry = TranscriptEntry()
        let line = entry.translationTranscriptLine(forSlot: 0)
        #expect(line == nil)
    }
}

// MARK: - TranscriptLine Tests

struct TranscriptLineTests {

    @Test func defaultValues() {
        let line = TranscriptLine(text: "Hello", isPartial: false)
        #expect(line.text == "Hello")
        #expect(line.isPartial == false)
        #expect(line.isSeparator == false)
        #expect(line.finalizedAt == nil)
    }

    @Test func partialLine() {
        let line = TranscriptLine(text: "typing...", isPartial: true)
        #expect(line.isPartial == true)
        #expect(line.finalizedAt == nil)
    }

    @Test func separatorLine() {
        let line = TranscriptLine(text: "", isPartial: false, isSeparator: true)
        #expect(line.isSeparator == true)
    }

    @Test func finalizedAtIsSet() {
        let now = Date()
        let line = TranscriptLine(text: "Done", isPartial: false, finalizedAt: now)
        #expect(line.finalizedAt == now)
    }

    @Test func uniqueIDs() {
        let a = TranscriptLine(text: "A", isPartial: false)
        let b = TranscriptLine(text: "B", isPartial: false)
        #expect(a.id != b.id)
    }

    @Test func customID() {
        let customID = UUID()
        let line = TranscriptLine(id: customID, text: "Test", isPartial: false)
        #expect(line.id == customID)
    }
}

// MARK: - FinalizedLines Tests

struct FinalizedLinesTests {

    @Test func filtersOutPartialLines() {
        let lines: [TranscriptLine] = [
            TranscriptLine(text: "Final", isPartial: false),
            TranscriptLine(text: "Partial", isPartial: true),
            TranscriptLine(text: "Final2", isPartial: false),
        ]
        let finalized = lines.finalizedLines
        #expect(finalized.count == 2)
        #expect(finalized[0].text == "Final")
        #expect(finalized[1].text == "Final2")
    }

    @Test func filtersOutSeparatorLines() {
        let lines: [TranscriptLine] = [
            TranscriptLine(text: "Line1", isPartial: false),
            TranscriptLine(text: "", isPartial: false, isSeparator: true),
            TranscriptLine(text: "Line2", isPartial: false),
        ]
        let finalized = lines.finalizedLines
        #expect(finalized.count == 2)
        #expect(finalized[0].text == "Line1")
        #expect(finalized[1].text == "Line2")
    }

    @Test func filtersOutBothPartialAndSeparator() {
        let lines: [TranscriptLine] = [
            TranscriptLine(text: "Good", isPartial: false),
            TranscriptLine(text: "Partial", isPartial: true),
            TranscriptLine(text: "", isPartial: false, isSeparator: true),
        ]
        let finalized = lines.finalizedLines
        #expect(finalized.count == 1)
        #expect(finalized[0].text == "Good")
    }

    @Test func emptyArrayReturnsEmpty() {
        let lines: [TranscriptLine] = []
        #expect(lines.finalizedLines.isEmpty)
    }
}

// MARK: - AutoReplacement Model Tests

@MainActor
struct AutoReplacementTests {

    @Test func codableRoundTrip() throws {
        let original = AutoReplacement(from: "teh", to: "the")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AutoReplacement.self, from: data)
        #expect(decoded.from == original.from)
        #expect(decoded.to == original.to)
        #expect(decoded.id == original.id)
    }

    @Test func equatable() {
        let a = AutoReplacement(from: "foo", to: "bar")
        let b = a  // same value
        #expect(a == b)
    }

    @Test func notEqualWithDifferentValues() {
        let a = AutoReplacement(from: "foo", to: "bar")
        let b = AutoReplacement(from: "foo", to: "baz")
        #expect(a != b)
    }
}

// MARK: - TranslationSlot Tests

struct TranslationSlotTests {

    @Test func resetClearsState() {
        var slot = TranslationSlot()
        slot.queue.append(TranslationQueueItem(sentence: "test", entryID: UUID(), isPartial: false, elapsedTime: nil))
        slot.partialEntryID = UUID()

        slot.reset()

        #expect(slot.queue.isEmpty)
        #expect(slot.partialEntryID == nil)
    }

    @Test func defaultValues() {
        let slot = TranslationSlot()
        #expect(slot.queue.isEmpty)
        #expect(slot.partialEntryID == nil)
    }
}

// MARK: - TranslationQueueItem Tests

struct TranslationQueueItemTests {

    @Test func propertiesAreStored() {
        let entryID = UUID()
        let item = TranslationQueueItem(sentence: "Hello", entryID: entryID, isPartial: true, elapsedTime: 5.0)
        #expect(item.sentence == "Hello")
        #expect(item.entryID == entryID)
        #expect(item.isPartial == true)
        #expect(item.elapsedTime == 5.0)
    }
}

// MARK: - TranslationSlot Partial State Tests

struct TranslationSlotPartialStateTests {

    @Test func resetPartialStateClearsFields() {
        var slot = TranslationSlot()
        slot.partialEntryID = UUID()
        slot.pendingPartialText = "Hello"
        slot.pendingPartialElapsedTime = 5.0

        slot.resetPartialState()

        #expect(slot.partialEntryID == nil)
        #expect(slot.pendingPartialText == nil)
        #expect(slot.pendingPartialElapsedTime == nil)
        #expect(slot.partialTranslationTimer == nil)
    }

    @Test func resetClearsEverythingIncludingQueue() {
        var slot = TranslationSlot()
        slot.queue.append(TranslationQueueItem(sentence: "A", entryID: UUID(), isPartial: false, elapsedTime: nil))
        slot.isProcessing = true
        slot.currentItem = TranslationQueueItem(sentence: "B", entryID: UUID(), isPartial: false, elapsedTime: nil)
        slot.recentlyCompleted.append(CompletedTranslationItem(source: TranslationQueueItem(sentence: "C", entryID: UUID(), isPartial: false, elapsedTime: nil), resultText: "D", completedAt: Date()))

        slot.reset()

        #expect(slot.queue.isEmpty)
        #expect(slot.isProcessing == false)
        #expect(slot.currentItem == nil)
        #expect(slot.recentlyCompleted.isEmpty)
        #expect(slot.partialEntryID == nil)
    }
}

// MARK: - SourceTranscriptLines Combined Line Tests

struct SourceTranscriptLinesCombinedTests {

    @Test func combinedFinalizedAndPartialProducesSingleLine() {
        let entry = TranscriptEntry(
            source: TransString(text: "Hello. ", isPartial: false),
            pendingPartial: "How are",
            elapsedTime: 5.0,
            duration: 2.0
        )
        let lines = entry.sourceTranscriptLines()
        #expect(lines.count == 1)
        #expect(lines[0].text == "Hello. How are")
        #expect(lines[0].isPartial == true)
        #expect(lines[0].finalizedPrefix == "Hello. ")
        #expect(lines[0].elapsedTime == 5.0)
        #expect(lines[0].duration == 2.0)
    }

    @Test func purePartialHasNoFinalizedPrefix() {
        let entry = TranscriptEntry(pendingPartial: "typing")
        let lines = entry.sourceTranscriptLines()
        #expect(lines.count == 1)
        #expect(lines[0].finalizedPrefix == nil)
    }

    @Test func committedEntryHasSentenceID() {
        let entry = TranscriptEntry(
            source: TransString(text: "Done.", isPartial: false),
            isCommitted: true
        )
        let lines = entry.sourceTranscriptLines()
        #expect(lines[0].sentenceID == entry.id)
    }

    @Test func uncommittedEntryHasNoSentenceID() {
        let entry = TranscriptEntry(
            source: TransString(text: "Not done", isPartial: false),
            isCommitted: false
        )
        let lines = entry.sourceTranscriptLines()
        #expect(lines[0].sentenceID == nil)
    }

    @Test func emptyPartialIsIgnored() {
        let entry = TranscriptEntry(
            source: TransString(text: "Hello", isPartial: false),
            pendingPartial: ""
        )
        let lines = entry.sourceTranscriptLines()
        #expect(lines.count == 1)
        #expect(lines[0].text == "Hello")
        #expect(lines[0].isPartial == false)
    }
}

// MARK: - TranscriptLine Equatable Tests

struct TranscriptLineEquatableTests {

    @Test func equalLinesAreEqual() {
        let id = UUID()
        let a = TranscriptLine(id: id, text: "Hello", isPartial: false, elapsedTime: 1.0)
        let b = TranscriptLine(id: id, text: "Hello", isPartial: false, elapsedTime: 1.0)
        #expect(a == b)
    }

    @Test func differentTextNotEqual() {
        let id = UUID()
        let a = TranscriptLine(id: id, text: "Hello", isPartial: false)
        let b = TranscriptLine(id: id, text: "World", isPartial: false)
        #expect(a != b)
    }

    @Test func differentPartialNotEqual() {
        let id = UUID()
        let a = TranscriptLine(id: id, text: "Hello", isPartial: false)
        let b = TranscriptLine(id: id, text: "Hello", isPartial: true)
        #expect(a != b)
    }
}

// MARK: - DisplayMode Tests

struct DisplayModeTests {

    @Test func allCases() {
        #expect(DisplayMode.allCases.count == 2)
        #expect(DisplayMode.allCases.contains(.normal))
        #expect(DisplayMode.allCases.contains(.subtitle))
    }

    @Test func rawValues() {
        #expect(DisplayMode.normal.rawValue == "normal")
        #expect(DisplayMode.subtitle.rawValue == "subtitle")
    }
}

// MARK: - RecordingSegment Tests

struct RecordingSegmentTests {

    @Test func storesURLAndOffset() {
        let url = URL(fileURLWithPath: "/tmp/test.m4a")
        let segment = RecordingSegment(url: url, elapsedTimeOffset: 10.0)
        #expect(segment.url == url)
        #expect(segment.elapsedTimeOffset == 10.0)
    }
}
