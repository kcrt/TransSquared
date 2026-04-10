//
//  TranslationQueueTests.swift
//  TransSquaredTests
//

import Foundation
import Testing
@testable import TransSquared

// MARK: - Translation Queue Tests

@MainActor
struct TranslationQueueTests {

    // MARK: enqueueTranslation

    @Test func enqueueTranslation_addsItemToSlotQueue() {
        let vm = makeTestViewModel()
        let entryID = UUID()
        let item = TranslationQueueItem(sentence: "Hello", entryID: entryID, isPartial: false, elapsedTime: nil)
        vm.enqueueTranslation(slot: 0, item: item)
        #expect(vm.translationSlots[0].queue.count == 1)
        #expect(vm.translationSlots[0].queue[0].sentence == "Hello")
        #expect(vm.translationSlots[0].queue[0].entryID == entryID)
    }

    @Test func enqueueTranslation_appendsMultipleItems() {
        let vm = makeTestViewModel()
        for i in 0..<3 {
            vm.enqueueTranslation(slot: 0, item: TranslationQueueItem(
                sentence: "Sentence \(i)", entryID: UUID(), isPartial: false, elapsedTime: nil
            ))
        }
        #expect(vm.translationSlots[0].queue.count == 3)
    }

    @Test func enqueueTranslation_ignoresOutOfBoundsSlot() {
        let vm = makeTestViewModel()
        vm.enqueueTranslation(slot: 99, item: TranslationQueueItem(
            sentence: "Hello", entryID: UUID(), isPartial: false, elapsedTime: nil
        ))
        // Default has only slot 0 — slot 99 must be silently ignored
        #expect(vm.translationSlots.count == 1)
        #expect(vm.translationSlots[0].queue.isEmpty)
    }

    @Test func enqueueTranslation_partialItemIsTaggedCorrectly() {
        let vm = makeTestViewModel()
        let item = TranslationQueueItem(sentence: "typing", entryID: UUID(), isPartial: true, elapsedTime: 5.0)
        vm.enqueueTranslation(slot: 0, item: item)
        #expect(vm.translationSlots[0].queue[0].isPartial == true)
        #expect(vm.translationSlots[0].queue[0].elapsedTime == 5.0)
    }

    // MARK: commitSentence

    @Test func commitSentence_incrementsSegmentIndex() {
        let vm = makeTestViewModel()
        _ = vm.ensureCurrentEntry()
        vm.commitSentence("Hello world.")
        #expect(vm.segmentIndex == 1)
    }

    @Test func commitSentence_marksCurrentEntryAsCommitted() {
        let vm = makeTestViewModel()
        let idx = vm.ensureCurrentEntry()
        let entryID = vm.entries[idx].id
        vm.commitSentence("A committed sentence.")
        guard let committedIdx = vm.entryIndex(for: entryID) else {
            Issue.record("Entry not found after commitSentence")
            return
        }
        #expect(vm.entries[committedIdx].isCommitted == true)
        #expect(vm.entries[committedIdx].pendingPartial == nil)
    }

    @Test func commitSentence_emptyString_doesNothing() {
        let vm = makeTestViewModel()
        vm.commitSentence("")
        #expect(vm.segmentIndex == 0)
        #expect(vm.entries.isEmpty)
    }

    @Test func commitSentence_carriesOverPendingPartialToNewEntry() {
        let vm = makeTestViewModel()
        let idx = vm.ensureCurrentEntry()
        vm.entries[idx].pendingPartial = "carry me"
        vm.commitSentence("First sentence.")
        // A new entry must have been created to hold the carry-over partial
        #expect(vm.entries.count == 2)
        #expect(vm.entries[1].pendingPartial == "carry me")
    }

    @Test func commitSentence_emptyPendingPartial_doesNotCreateExtraEntry() {
        let vm = makeTestViewModel()
        let idx = vm.ensureCurrentEntry()
        vm.entries[idx].pendingPartial = nil   // no carry-over
        vm.commitSentence("Only sentence.")
        // Only the original committed entry; no extra entry
        #expect(vm.entries.count == 1)
    }

    @Test func commitSentence_enqueuesFinalTranslationItem() {
        let vm = makeTestViewModel()
        _ = vm.ensureCurrentEntry()
        vm.commitSentence("Hello")
        let finalItems = vm.translationSlots[0].queue.filter { !$0.isPartial }
        #expect(finalItems.count == 1)
        #expect(finalItems[0].sentence == "Hello")
        #expect(finalItems[0].isPartial == false)
    }

    @Test func commitSentence_multipleCallsAccumulateSegmentIndex() {
        let vm = makeTestViewModel()
        _ = vm.ensureCurrentEntry()
        vm.commitSentence("One.")
        // Ensure there's an uncommitted entry for the second commit
        _ = vm.ensureCurrentEntry()
        vm.commitSentence("Two.")
        #expect(vm.segmentIndex == 2)
    }

    @Test func commitSentence_noCurrentEntry_warnsAndSkips() {
        let vm = makeTestViewModel()
        // No entries at all — commitSentence should handle the missing entry gracefully
        vm.commitSentence("Orphan sentence")
        // segmentIndex is incremented before the guard, so it becomes 1
        #expect(vm.segmentIndex == 1)
        // But no entries should be created by commitSentence itself
        #expect(vm.entries.isEmpty)
    }
}
