//
//  InlineEditingTests.swift
//  TransSquaredTests
//

import Foundation
import Testing
@testable import TransSquared

// MARK: - Inline Editing Tests

@MainActor
struct InlineEditingTests {

    // MARK: editSourceLine

    @Test func editSourceLine_updatesText() {
        let vm = makeTestViewModel()
        let sourceID = UUID()
        vm.entries = [TranscriptEntry(
            source: TransString(id: sourceID, text: "Old text", isPartial: false),
            isCommitted: false
        )]
        vm.editSourceLine(id: sourceID, newText: "New text")
        #expect(vm.entries[0].source.text == "New text")
    }

    @Test func editSourceLine_noOpWhenTextUnchanged() {
        let vm = makeTestViewModel()
        let sourceID = UUID()
        vm.entries = [TranscriptEntry(
            source: TransString(id: sourceID, text: "Same text", isPartial: false),
            isCommitted: false
        )]
        vm.editSourceLine(id: sourceID, newText: "Same text")
        // Text must remain exactly the same; the guard clause exits early
        #expect(vm.entries[0].source.text == "Same text")
    }

    @Test func editSourceLine_noOpForUnknownSourceID() {
        let vm = makeTestViewModel()
        vm.entries = [TranscriptEntry(
            source: TransString(text: "Original", isPartial: false),
            isCommitted: false
        )]
        // Pass a random UUID that does not match any entry's source.id
        vm.editSourceLine(id: UUID(), newText: "Changed")
        #expect(vm.entries[0].source.text == "Original")
    }

    @Test func editSourceLine_uncommittedEntry_doesNotEnqueueTranslation() {
        let vm = makeTestViewModel()
        let sourceID = UUID()
        vm.entries = [TranscriptEntry(
            source: TransString(id: sourceID, text: "Old", isPartial: false),
            isCommitted: false   // not yet committed → no re-translation
        )]
        vm.editSourceLine(id: sourceID, newText: "New")
        #expect(vm.translationSlots[0].queue.isEmpty)
    }

    @Test func editSourceLine_committedEntry_enqueuesRetranslation() {
        let vm = makeTestViewModel()
        let sourceID = UUID()
        let entryID = UUID()
        vm.entries = [TranscriptEntry(
            id: entryID,
            source: TransString(id: sourceID, text: "Old sentence", isPartial: false),
            isCommitted: true
        )]
        vm.rebuildEntryIndexMap()
        vm.editSourceLine(id: sourceID, newText: "New sentence")
        // A re-translation (non-partial) for the new text should be queued
        let finalItems = vm.translationSlots[0].queue.filter { !$0.isPartial }
        #expect(!finalItems.isEmpty)
        #expect(finalItems[0].sentence == "New sentence")
        #expect(finalItems[0].entryID == entryID)
    }

    @Test func editSourceLine_committedEntry_setsTranslationPlaceholder() {
        let vm = makeTestViewModel()
        let sourceID = UUID()
        let entryID = UUID()
        vm.entries = [TranscriptEntry(
            id: entryID,
            source: TransString(id: sourceID, text: "Old sentence", isPartial: false),
            isCommitted: true
        )]
        vm.rebuildEntryIndexMap()
        vm.editSourceLine(id: sourceID, newText: "New sentence")
        // Translation slot 0 should now have a partial (placeholder "…") translation
        let trans = vm.entries[0].translations[0]
        #expect(trans?.isPartial == true)
    }

    // MARK: editTranslationLine

    @Test func editTranslationLine_updatesText() {
        let vm = makeTestViewModel()
        let translationID = UUID()
        var entry = TranscriptEntry(isCommitted: true)
        entry.translations[0] = TransString(id: translationID, text: "Old translation", isPartial: false)
        vm.entries = [entry]
        vm.editTranslationLine(slot: 0, id: translationID, newText: "New translation")
        #expect(vm.entries[0].translations[0]?.text == "New translation")
    }

    @Test func editTranslationLine_noOpWhenTextUnchanged() {
        let vm = makeTestViewModel()
        let translationID = UUID()
        var entry = TranscriptEntry(isCommitted: true)
        entry.translations[0] = TransString(id: translationID, text: "Same translation", isPartial: false)
        vm.entries = [entry]
        vm.editTranslationLine(slot: 0, id: translationID, newText: "Same translation")
        #expect(vm.entries[0].translations[0]?.text == "Same translation")
    }

    @Test func editTranslationLine_noOpForUnknownTranslationID() {
        let vm = makeTestViewModel()
        var entry = TranscriptEntry(isCommitted: true)
        entry.translations[0] = TransString(text: "Original translation", isPartial: false)
        vm.entries = [entry]
        vm.editTranslationLine(slot: 0, id: UUID(), newText: "Changed")
        #expect(vm.entries[0].translations[0]?.text == "Original translation")
    }

    @Test func editTranslationLine_noOpForOutOfBoundsSlot() {
        let vm = makeTestViewModel()
        let translationID = UUID()
        var entry = TranscriptEntry(isCommitted: true)
        entry.translations[0] = TransString(id: translationID, text: "Original", isPartial: false)
        vm.entries = [entry]
        vm.editTranslationLine(slot: 99, id: translationID, newText: "Changed")
        // Slot 99 does not exist; slot 0's translation must be untouched
        #expect(vm.entries[0].translations[0]?.text == "Original")
    }

    @Test func editTranslationLine_doesNotAffectOtherSlots() {
        let vm = makeTestViewModel()
        vm.targetCount = 2
        vm.translationSlots = [TranslationSlot(), TranslationSlot()]
        let slot0ID = UUID()
        let slot1ID = UUID()
        var entry = TranscriptEntry(isCommitted: true)
        entry.translations[0] = TransString(id: slot0ID, text: "Slot 0 text", isPartial: false)
        entry.translations[1] = TransString(id: slot1ID, text: "Slot 1 text", isPartial: false)
        vm.entries = [entry]
        vm.editTranslationLine(slot: 0, id: slot0ID, newText: "Updated slot 0")
        #expect(vm.entries[0].translations[0]?.text == "Updated slot 0")
        #expect(vm.entries[0].translations[1]?.text == "Slot 1 text")
    }
}
