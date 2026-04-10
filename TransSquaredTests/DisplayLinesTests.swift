//
//  DisplayLinesTests.swift
//  TransSquaredTests
//

import Foundation
import Testing
@testable import TransSquared

// MARK: - Display Lines Recomputation Tests

@MainActor
struct DisplayLinesTests {

    // MARK: sourceLines derivation

    @Test func emptyEntries_producesEmptySourceLines() {
        let vm = makeTestViewModel()
        vm.recomputeDisplayLines()
        #expect(vm.sourceLines.isEmpty)
    }

    @Test func singleCommittedEntry_producesOneSourceLine() {
        let vm = makeTestViewModel()
        vm.entries = [
            TranscriptEntry(source: TransString(text: "Hello", isPartial: false), isCommitted: true),
        ]
        vm.recomputeDisplayLines()
        #expect(vm.sourceLines.count == 1)
        #expect(vm.sourceLines[0].text == "Hello")
        #expect(vm.sourceLines[0].isPartial == false)
    }

    @Test func multipleEntries_eachProducesOneSourceLine() {
        let vm = makeTestViewModel()
        vm.entries = [
            TranscriptEntry(source: TransString(text: "Line 1", isPartial: false), isCommitted: true),
            TranscriptEntry(source: TransString(text: "Line 2", isPartial: false), isCommitted: true),
            TranscriptEntry(source: TransString(text: "Line 3", isPartial: false), isCommitted: true),
        ]
        vm.recomputeDisplayLines()
        #expect(vm.sourceLines.count == 3)
        #expect(vm.sourceLines.map(\.text) == ["Line 1", "Line 2", "Line 3"])
    }

    @Test func partialEntry_appearsAsPartialSourceLine() {
        let vm = makeTestViewModel()
        vm.entries = [TranscriptEntry(pendingPartial: "typing...")]
        vm.recomputeDisplayLines()
        #expect(vm.sourceLines.count == 1)
        #expect(vm.sourceLines[0].isPartial == true)
        #expect(vm.sourceLines[0].text == "typing...")
    }

    @Test func separatorEntry_producesASourceSeparatorLine() {
        let vm = makeTestViewModel()
        vm.entries = [
            TranscriptEntry(source: TransString(text: "Before", isPartial: false), isCommitted: true),
            TranscriptEntry(isSeparator: true),
            TranscriptEntry(source: TransString(text: "After", isPartial: false), isCommitted: true),
        ]
        vm.recomputeDisplayLines()
        #expect(vm.sourceLines.count == 3)
        #expect(vm.sourceLines[1].isSeparator == true)
    }

    @Test func emptyEntry_producesNoSourceLine() {
        let vm = makeTestViewModel()
        vm.entries = [TranscriptEntry()]   // empty source, no partial
        vm.recomputeDisplayLines()
        #expect(vm.sourceLines.isEmpty)
    }

    // MARK: translationLinesPerSlot derivation

    @Test func translationLinesPerSlot_countMatchesTargetCount() {
        let vm = makeTestViewModel()
        vm.targetCount = 2
        vm.translationSlots = [TranslationSlot(), TranslationSlot()]
        vm.entries = [
            TranscriptEntry(source: TransString(text: "Hello", isPartial: false), isCommitted: true),
        ]
        vm.recomputeDisplayLines()
        #expect(vm.translationLinesPerSlot.count == 2)
    }

    @Test func translationLines_emptyWhenNoTranslation() {
        let vm = makeTestViewModel()
        vm.entries = [
            TranscriptEntry(source: TransString(text: "Hello", isPartial: false), isCommitted: true),
        ]
        vm.recomputeDisplayLines()
        // No translation set for slot 0 — the compactMap should filter out nils
        #expect(vm.translationLinesPerSlot[0].isEmpty)
    }

    @Test func translationLines_populatedWhenTranslationPresent() {
        let vm = makeTestViewModel()
        var entry = TranscriptEntry(source: TransString(text: "Hello", isPartial: false), isCommitted: true)
        entry.translations[0] = TransString(text: "こんにちは", isPartial: false)
        vm.entries = [entry]
        vm.recomputeDisplayLines()
        let slot0 = vm.translationLinesPerSlot[0]
        #expect(slot0.count == 1)
        #expect(slot0[0].text == "こんにちは")
    }

    @Test func separatorEntry_appearsAsSeparatorInTranslationLines() {
        let vm = makeTestViewModel()
        vm.entries = [
            TranscriptEntry(isSeparator: true),
        ]
        vm.recomputeDisplayLines()
        let slot0 = vm.translationLinesPerSlot[0]
        #expect(slot0.count == 1)
        #expect(slot0[0].isSeparator == true)
    }

    @Test func translationLines_mixedTranslatedAndUntranslated() {
        let vm = makeTestViewModel()
        var translated = TranscriptEntry(source: TransString(text: "Hello", isPartial: false), isCommitted: true)
        translated.translations[0] = TransString(text: "こんにちは", isPartial: false)
        let untranslated = TranscriptEntry(source: TransString(text: "World", isPartial: false), isCommitted: true)
        vm.entries = [translated, untranslated]
        vm.recomputeDisplayLines()
        // Only the translated entry contributes a translation line
        #expect(vm.translationLinesPerSlot[0].count == 1)
        #expect(vm.translationLinesPerSlot[0][0].text == "こんにちは")
    }

    // MARK: translationLines(forSlot:)

    @Test func translationLines_forSlot_outOfBoundsReturnsEmpty() {
        let vm = makeTestViewModel()
        vm.recomputeDisplayLines()
        let lines = vm.translationLines(forSlot: 99)
        #expect(lines.isEmpty)
    }

    @Test func translationLines_forSlot_validSlotReturnsCorrectLines() {
        let vm = makeTestViewModel()
        var entry = TranscriptEntry(source: TransString(text: "Hello", isPartial: false), isCommitted: true)
        entry.translations[0] = TransString(text: "Translated", isPartial: false)
        vm.entries = [entry]
        vm.recomputeDisplayLines()
        let lines = vm.translationLines(forSlot: 0)
        #expect(lines.count == 1)
        #expect(lines[0].text == "Translated")
    }

    // MARK: idempotency

    @Test func recomputeDisplayLines_isIdempotent() {
        let vm = makeTestViewModel()
        vm.entries = [
            TranscriptEntry(source: TransString(text: "Hello", isPartial: false), isCommitted: true),
        ]
        vm.recomputeDisplayLines()
        let firstSourceLines = vm.sourceLines
        vm.recomputeDisplayLines()
        #expect(vm.sourceLines == firstSourceLines)
    }
}
