//
//  SessionViewModelEditingTests.swift
//  TransSquaredTests
//

import Foundation
import Testing
@testable import TransSquared

@MainActor
struct EditingTests {

    @Test func editSourceLineUpdatesText() {
        let vm = makeTestViewModel()
        let sourceID = UUID()
        vm.entries = [
            TranscriptEntry(
                source: TransString(id: sourceID, text: "Old text", isPartial: false),
                isCommitted: false
            )
        ]
        vm.rebuildEntryIndexMap()

        vm.editSourceLine(id: sourceID, newText: "New text")

        #expect(vm.entries[0].source.text == "New text")
    }

    @Test func editSourceLineNoOpWhenTextUnchanged() {
        let vm = makeTestViewModel()
        let sourceID = UUID()
        vm.entries = [
            TranscriptEntry(
                source: TransString(id: sourceID, text: "Same", isPartial: false),
                isCommitted: true
            )
        ]
        vm.rebuildEntryIndexMap()

        vm.editSourceLine(id: sourceID, newText: "Same")

        #expect(vm.entries[0].translations.isEmpty)
    }

    @Test func editSourceLineOnCommittedEntryTriggersRetranslation() {
        let vm = makeTestViewModel()
        vm.targetCount = 1
        vm.translationSlots = [TranslationSlot()]
        vm.translationConfigs = [nil]

        let sourceID = UUID()
        var entry = TranscriptEntry(
            source: TransString(id: sourceID, text: "Hello", isPartial: false),
            isCommitted: true
        )
        entry.translations[0] = TransString(text: "こんにちは", isPartial: false, finalizedAt: Date())
        vm.entries = [entry]
        vm.rebuildEntryIndexMap()

        vm.editSourceLine(id: sourceID, newText: "Goodbye")

        #expect(vm.entries[0].translations[0]?.isPartial == true)
        #expect(vm.entries[0].translations[0]?.text == "…")
        #expect(vm.translationSlots[0].queue.count == 1)
        #expect(vm.translationSlots[0].queue[0].sentence == "Goodbye")
    }

    @Test func editSourceLineIgnoresUnknownID() {
        let vm = makeTestViewModel()
        vm.entries = [
            TranscriptEntry(source: TransString(text: "Hello", isPartial: false))
        ]
        vm.rebuildEntryIndexMap()

        vm.editSourceLine(id: UUID(), newText: "Changed")
        #expect(vm.entries[0].source.text == "Hello")
    }

    @Test func editTranslationLineUpdatesText() {
        let vm = makeTestViewModel()
        let transID = UUID()
        var entry = TranscriptEntry(isCommitted: true)
        entry.translations[0] = TransString(id: transID, text: "Old translation", isPartial: false)
        vm.entries = [entry]

        vm.editTranslationLine(slot: 0, id: transID, newText: "New translation")

        #expect(vm.entries[0].translations[0]?.text == "New translation")
    }

    @Test func editTranslationLineNoOpWhenTextUnchanged() {
        let vm = makeTestViewModel()
        let transID = UUID()
        var entry = TranscriptEntry(isCommitted: true)
        entry.translations[0] = TransString(id: transID, text: "Same", isPartial: false)
        vm.entries = [entry]

        vm.editTranslationLine(slot: 0, id: transID, newText: "Same")
        #expect(vm.entries[0].translations[0]?.text == "Same")
    }

    @Test func editTranslationLineIgnoresUnknownID() {
        let vm = makeTestViewModel()
        var entry = TranscriptEntry(isCommitted: true)
        entry.translations[0] = TransString(text: "Hello", isPartial: false)
        vm.entries = [entry]

        vm.editTranslationLine(slot: 0, id: UUID(), newText: "Changed")
        #expect(vm.entries[0].translations[0]?.text == "Hello")
    }
}
