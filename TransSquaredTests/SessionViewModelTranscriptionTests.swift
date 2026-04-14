//
//  SessionViewModelTranscriptionTests.swift
//  TransSquaredTests
//

import Foundation
import Testing
@testable import TransSquared

// MARK: - Auto-Replacement Logic Tests

@MainActor
struct AutoReplacementLogicTests {

    @Test func singleRule() {
        let vm = makeTestViewModel()
        vm.autoReplacementsByLocale[vm.sourceLocaleIdentifier] = [
            AutoReplacement(from: "teh", to: "the")
        ]
        #expect(vm.applyAutoReplacements("teh quick fox") == "the quick fox")
    }

    @Test func multipleRules() {
        let vm = makeTestViewModel()
        vm.autoReplacementsByLocale[vm.sourceLocaleIdentifier] = [
            AutoReplacement(from: "teh", to: "the"),
            AutoReplacement(from: "quik", to: "quick"),
        ]
        #expect(vm.applyAutoReplacements("teh quik fox") == "the quick fox")
    }

    @Test func emptyFromIsSkipped() {
        let vm = makeTestViewModel()
        vm.autoReplacementsByLocale[vm.sourceLocaleIdentifier] = [
            AutoReplacement(from: "", to: "anything"),
            AutoReplacement(from: "cat", to: "dog"),
        ]
        #expect(vm.applyAutoReplacements("a cat") == "a dog")
    }

    @Test func noRulesReturnsOriginal() {
        let vm = makeTestViewModel()
        vm.autoReplacementsByLocale[vm.sourceLocaleIdentifier] = []
        #expect(vm.applyAutoReplacements("hello world") == "hello world")
    }

    @Test func rulesAreScopedPerLocale() {
        let vm = makeTestViewModel()
        vm.sourceLocaleIdentifier = "en_US"
        vm.autoReplacementsByLocale["en_US"] = [
            AutoReplacement(from: "colour", to: "color")
        ]
        vm.autoReplacementsByLocale["ja_JP"] = [
            AutoReplacement(from: "colour", to: "カラー")
        ]
        #expect(vm.applyAutoReplacements("colour") == "color")

        vm.sourceLocaleIdentifier = "ja_JP"
        #expect(vm.applyAutoReplacements("colour") == "カラー")
    }
}

// MARK: - Transcription Event Tests

@MainActor
struct TranscriptionEventTests {

    @Test func partialEventSetsPendingPartial() {
        let vm = makeTestViewModel()
        vm.handleTranscriptionEvent(.partial("Hello", duration: nil, audioOffset: nil))
        #expect(vm.entries.count == 1)
        #expect(vm.entries[0].pendingPartial == "Hello")
        #expect(vm.entries[0].source.text.isEmpty)
    }

    @Test func partialEventReplacesPreviousPartial() {
        let vm = makeTestViewModel()
        vm.handleTranscriptionEvent(.partial("Hel", duration: nil, audioOffset: nil))
        vm.handleTranscriptionEvent(.partial("Hello", duration: nil, audioOffset: nil))
        #expect(vm.entries.count == 1)
        #expect(vm.entries[0].pendingPartial == "Hello")
    }

    @Test func finalEventClearsPartialAndAccumulatesSource() {
        let vm = makeTestViewModel()
        vm.handleTranscriptionEvent(.partial("Hello", duration: nil, audioOffset: nil))
        #expect(vm.entries[0].pendingPartial == "Hello")

        vm.handleTranscriptionEvent(.finalized("Hello world.", duration: nil, audioOffset: nil))
        #expect(vm.entries[0].pendingPartial == nil)
        #expect(vm.entries[0].source.text == "Hello world.")
    }

    @Test func finalEventPopulatesPendingSentenceBuffer() {
        let vm = makeTestViewModel()
        vm.handleTranscriptionEvent(.finalized("Hello", duration: nil, audioOffset: nil))
        #expect(vm.pendingSentenceBuffer == "Hello")
    }

    @Test func multipleFinalEventsAccumulateBuffer() {
        let vm = makeTestViewModel()
        vm.handleTranscriptionEvent(.finalized("Hello ", duration: nil, audioOffset: nil))
        vm.handleTranscriptionEvent(.finalized("world", duration: nil, audioOffset: nil))
        #expect(vm.pendingSentenceBuffer == "Hello world")
        #expect(vm.entries[0].source.text == "Hello world")
    }

    @Test func errorEventSetsErrorMessage() {
        let vm = makeTestViewModel()
        vm.handleTranscriptionEvent(.error("Something went wrong"))
        #expect(vm.errorMessage == "Something went wrong")
    }
}

// MARK: - Sentence Boundary Tests

@MainActor
struct SentenceBoundaryTests {

    private func vmWithPendingEntry(buffer: String) -> SessionViewModel {
        let vm = makeTestViewModel()
        vm.pendingSentenceBuffer = buffer
        vm.entries.append(TranscriptEntry(
            source: TransString(text: buffer, isPartial: false)
        ))
        return vm
    }

    @Test func commitOnPeriod() {
        let vm = vmWithPendingEntry(buffer: "Hello world.")
        vm.checkSentenceBoundary()
        #expect(vm.pendingSentenceBuffer == "")
        #expect(vm.segmentIndex == 1)
        #expect(vm.entries[0].isCommitted == true)
    }

    @Test func commitOnJapanesePeriod() {
        let vm = vmWithPendingEntry(buffer: "こんにちは。")
        vm.checkSentenceBoundary()
        #expect(vm.pendingSentenceBuffer == "")
        #expect(vm.segmentIndex == 1)
    }

    @Test func commitOnExclamation() {
        let vm = vmWithPendingEntry(buffer: "Wow!")
        vm.checkSentenceBoundary()
        #expect(vm.pendingSentenceBuffer == "")
        #expect(vm.segmentIndex == 1)
    }

    @Test func commitOnQuestion() {
        let vm = vmWithPendingEntry(buffer: "Really?")
        vm.checkSentenceBoundary()
        #expect(vm.pendingSentenceBuffer == "")
        #expect(vm.segmentIndex == 1)
    }

    @Test func commitOnFullWidthExclamation() {
        let vm = vmWithPendingEntry(buffer: "すごい！")
        vm.checkSentenceBoundary()
        #expect(vm.pendingSentenceBuffer == "")
        #expect(vm.segmentIndex == 1)
    }

    @Test func commitOnFullWidthQuestion() {
        let vm = vmWithPendingEntry(buffer: "本当？")
        vm.checkSentenceBoundary()
        #expect(vm.pendingSentenceBuffer == "")
        #expect(vm.segmentIndex == 1)
    }

    @Test func noCommitWithoutPunctuation() {
        let vm = makeTestViewModel()
        vm.pendingSentenceBuffer = "Hello world"
        vm.entries.append(TranscriptEntry(
            source: TransString(text: "Hello world", isPartial: false)
        ))
        vm.checkSentenceBoundary()
        #expect(vm.pendingSentenceBuffer == "Hello world")
        #expect(vm.segmentIndex == 0)
    }

    @Test func emptyBufferNoCommit() {
        let vm = makeTestViewModel()
        vm.pendingSentenceBuffer = ""
        vm.checkSentenceBoundary()
        #expect(vm.segmentIndex == 0)
    }
}

// MARK: - Transcription Event Edge Cases

@MainActor
struct TranscriptionEventEdgeCaseTests {

    @Test func partialEventSetsElapsedTimeFromAudioOffset() {
        let vm = makeTestViewModel()
        vm.accumulatedElapsedTime = 10.0
        vm.handleTranscriptionEvent(.partial("Hi", duration: 0.5, audioOffset: 2.0))
        #expect(vm.entries[0].elapsedTime == 12.0)
    }

    @Test func partialEventDoesNotOverwriteExistingElapsedTime() {
        let vm = makeTestViewModel()
        vm.accumulatedElapsedTime = 10.0
        vm.handleTranscriptionEvent(.partial("Hi", duration: 0.5, audioOffset: 2.0))
        vm.handleTranscriptionEvent(.partial("Hi there", duration: 1.0, audioOffset: 3.0))
        #expect(vm.entries[0].elapsedTime == 12.0)
    }

    @Test func finalizedEventSetsElapsedTimeFromAudioOffset() {
        let vm = makeTestViewModel()
        vm.accumulatedElapsedTime = 5.0
        vm.handleTranscriptionEvent(.finalized("Done.", duration: 1.0, audioOffset: 3.0))
        #expect(vm.entries[0].elapsedTime == 8.0)
    }

    @Test func durationSpansFromEntryStartToChunkEnd() {
        let vm = makeTestViewModel()
        vm.accumulatedElapsedTime = 0
        vm.handleTranscriptionEvent(.finalized("Hello ", duration: 0.5, audioOffset: 1.0))
        vm.handleTranscriptionEvent(.finalized("world", duration: 0.8, audioOffset: 2.0))
        #expect(vm.entries[0].elapsedTime == 1.0)
        #expect(abs(vm.entries[0].duration! - 1.8) < 0.001)
    }

    @Test func partialEventUpdatesDurationProgressively() {
        let vm = makeTestViewModel()
        vm.accumulatedElapsedTime = 0
        vm.handleTranscriptionEvent(.partial("Hel", duration: 0.3, audioOffset: 1.0))
        #expect(abs(vm.entries[0].duration! - 0.3) < 0.001)
        vm.handleTranscriptionEvent(.partial("Hello", duration: 0.5, audioOffset: 1.5))
        #expect(abs(vm.entries[0].duration! - 1.0) < 0.001)
    }

    @Test func finalizedWithNilAudioOffsetFallsBackToCurrentElapsedTime() {
        let vm = makeTestViewModel()
        vm.accumulatedElapsedTime = 20.0
        vm.sessionStartDate = Date()
        vm.handleTranscriptionEvent(.finalized("No offset.", duration: nil, audioOffset: nil))
        #expect(vm.entries[0].elapsedTime != nil)
        #expect(vm.entries[0].elapsedTime! >= 20.0)
    }

    @Test func partialWithNilAudioOffsetLeavesElapsedTimeNil() {
        let vm = makeTestViewModel()
        vm.handleTranscriptionEvent(.partial("No offset", duration: nil, audioOffset: nil))
        #expect(vm.entries[0].elapsedTime == nil)
    }

    @Test func fileTranscriptionUsesOffsetDirectly() {
        let vm = makeTestViewModel()
        vm.isTranscribingFile = true
        vm.accumulatedElapsedTime = 99.0
        vm.handleTranscriptionEvent(.finalized("Test.", duration: 1.0, audioOffset: 5.0))
        #expect(vm.entries[0].elapsedTime == 5.0)
    }

    @Test func autoReplacementsAppliedToPartialEvents() {
        let vm = makeTestViewModel()
        vm.autoReplacementsByLocale[vm.sourceLocaleIdentifier] = [
            AutoReplacement(from: "teh", to: "the")
        ]
        vm.handleTranscriptionEvent(.partial("teh cat", duration: nil, audioOffset: nil))
        #expect(vm.entries[0].pendingPartial == "the cat")
    }

    @Test func autoReplacementsAppliedToFinalizedEvents() {
        let vm = makeTestViewModel()
        vm.autoReplacementsByLocale[vm.sourceLocaleIdentifier] = [
            AutoReplacement(from: "teh", to: "the")
        ]
        vm.handleTranscriptionEvent(.finalized("teh cat.", duration: nil, audioOffset: nil))
        #expect(vm.entries[0].source.text == "the cat.")
    }

    @Test func commitSentenceCreatesNewEntryForCarryOverPartial() {
        let vm = makeTestViewModel()
        let idx = vm.ensureCurrentEntry()
        vm.entries[idx].source.text = "First sentence."
        vm.entries[idx].pendingPartial = "Second"
        vm.pendingSentenceBuffer = "First sentence."

        vm.commitSentence("First sentence.")

        #expect(vm.entries[0].isCommitted == true)
        #expect(vm.entries[0].pendingPartial == nil)
        #expect(vm.entries.count == 2)
        #expect(vm.entries[1].pendingPartial == "Second")
        #expect(vm.entries[1].isCommitted == false)
    }

    @Test func commitSentenceIncrementsSegmentIndex() {
        let vm = makeTestViewModel()
        let idx = vm.ensureCurrentEntry()
        vm.entries[idx].source.text = "Done."
        vm.pendingSentenceBuffer = "Done."

        #expect(vm.segmentIndex == 0)
        vm.commitSentence("Done.")
        #expect(vm.segmentIndex == 1)
    }

    @Test func commitEmptySentenceIsNoOp() {
        let vm = makeTestViewModel()
        vm.commitSentence("")
        #expect(vm.segmentIndex == 0)
    }

    @Test func multipleSentenceBoundariesInSequence() {
        let vm = makeTestViewModel()
        vm.handleTranscriptionEvent(.partial("Hello", duration: nil, audioOffset: nil))
        vm.handleTranscriptionEvent(.finalized("Hello.", duration: nil, audioOffset: nil))
        #expect(vm.entries[0].isCommitted == true)
        #expect(vm.segmentIndex == 1)

        vm.handleTranscriptionEvent(.finalized("World!", duration: nil, audioOffset: nil))
        #expect(vm.entries[1].isCommitted == true)
        #expect(vm.segmentIndex == 2)
    }
}

// MARK: - Enqueue Translation Tests

@MainActor
struct EnqueueTranslationTests {

    @Test func enqueueAddsToSlotQueue() {
        let vm = makeTestViewModel()
        vm.translationSlots = [TranslationSlot()]
        vm.translationConfigs = [nil]

        let entryID = UUID()
        vm.enqueueTranslation(slot: 0, item: TranslationQueueItem(
            sentence: "Hello", entryID: entryID, isPartial: false, elapsedTime: nil
        ))

        #expect(vm.translationSlots[0].queue.count == 1)
        #expect(vm.translationSlots[0].queue[0].sentence == "Hello")
    }

    @Test func enqueueOutOfBoundsSlotIsIgnored() {
        let vm = makeTestViewModel()
        vm.translationSlots = [TranslationSlot()]

        vm.enqueueTranslation(slot: 5, item: TranslationQueueItem(
            sentence: "Hello", entryID: UUID(), isPartial: false, elapsedTime: nil
        ))
        #expect(vm.translationSlots[0].queue.isEmpty)
    }
}
