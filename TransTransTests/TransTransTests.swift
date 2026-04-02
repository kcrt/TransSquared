//
//  TransTransTests.swift
//  TransTransTests
//
//  Created by 高橋亨平 on 2026-03-24.
//

import Foundation
import Testing
@testable import TransTrans

// MARK: - 1. TranscriptModels Tests

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
}

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

struct TranslationSlotTests {

    @Test func resetClearsState() {
        var slot = TranslationSlot()
        slot.queue.append(TranslationQueueItem(sentence: "test", targetIndex: 0, isPartial: false))
        slot.partialTargetIndex = 5

        slot.reset()

        #expect(slot.queue.isEmpty)
        #expect(slot.partialTargetIndex == -1)
        #expect(slot.config == nil)
    }

    @Test func defaultValues() {
        let slot = TranslationSlot()
        #expect(slot.lines.isEmpty)
        #expect(slot.queue.isEmpty)
        #expect(slot.partialTargetIndex == -1)
        #expect(slot.config == nil)
    }
}

// MARK: - 2. SessionViewModel — Auto-Replacement Logic

@MainActor
struct AutoReplacementLogicTests {

    @Test func singleRule() {
        let vm = SessionViewModel()
        vm.autoReplacementsByLocale[vm.sourceLocaleIdentifier] = [
            AutoReplacement(from: "teh", to: "the")
        ]
        #expect(vm.applyAutoReplacements("teh quick fox") == "the quick fox")
    }

    @Test func multipleRules() {
        let vm = SessionViewModel()
        vm.autoReplacementsByLocale[vm.sourceLocaleIdentifier] = [
            AutoReplacement(from: "teh", to: "the"),
            AutoReplacement(from: "quik", to: "quick"),
        ]
        #expect(vm.applyAutoReplacements("teh quik fox") == "the quick fox")
    }

    @Test func emptyFromIsSkipped() {
        let vm = SessionViewModel()
        vm.autoReplacementsByLocale[vm.sourceLocaleIdentifier] = [
            AutoReplacement(from: "", to: "anything"),
            AutoReplacement(from: "cat", to: "dog"),
        ]
        #expect(vm.applyAutoReplacements("a cat") == "a dog")
    }

    @Test func noRulesReturnsOriginal() {
        let vm = SessionViewModel()
        vm.autoReplacementsByLocale[vm.sourceLocaleIdentifier] = []
        #expect(vm.applyAutoReplacements("hello world") == "hello world")
    }

    @Test func rulesAreScopedPerLocale() {
        let vm = SessionViewModel()
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

// MARK: - 5. SessionViewModel — Transcription Event Handling

@MainActor
struct TranscriptionEventTests {

    @Test func partialEventAddsPartialSourceLine() {
        let vm = SessionViewModel()
        vm.handleTranscriptionEvent(.partial("Hello"))
        #expect(vm.sourceLines.count == 1)
        #expect(vm.sourceLines[0].text == "Hello")
        #expect(vm.sourceLines[0].isPartial == true)
    }

    @Test func partialEventReplacesPreviousPartial() {
        let vm = SessionViewModel()
        vm.handleTranscriptionEvent(.partial("Hel"))
        vm.handleTranscriptionEvent(.partial("Hello"))
        #expect(vm.sourceLines.count == 1)
        #expect(vm.sourceLines[0].text == "Hello")
        #expect(vm.sourceLines[0].isPartial == true)
    }

    @Test func finalEventRemovesPartialAndAppendsFinal() {
        let vm = SessionViewModel()
        vm.handleTranscriptionEvent(.partial("Hello"))
        #expect(vm.sourceLines.count == 1)
        #expect(vm.sourceLines[0].isPartial == true)

        vm.handleTranscriptionEvent(.final_("Hello world."))
        // Partial removed, final appended
        #expect(vm.sourceLines.count == 1)
        #expect(vm.sourceLines[0].text == "Hello world.")
        #expect(vm.sourceLines[0].isPartial == false)
    }

    @Test func finalEventPopulatesPendingSentenceBuffer() {
        let vm = SessionViewModel()
        vm.handleTranscriptionEvent(.final_("Hello"))
        #expect(vm.pendingSentenceBuffer == "Hello")
    }

    @Test func multipleFinalEventsAccumulateBuffer() {
        let vm = SessionViewModel()
        vm.handleTranscriptionEvent(.final_("Hello "))
        vm.handleTranscriptionEvent(.final_("world"))
        // "Hello " ends without sentence-ending punctuation, so buffer accumulates
        #expect(vm.pendingSentenceBuffer == "Hello world")
    }

    @Test func errorEventSetsErrorMessage() {
        let vm = SessionViewModel()
        vm.handleTranscriptionEvent(.error("Something went wrong"))
        #expect(vm.errorMessage == "Something went wrong")
    }
}

// MARK: - 6. SessionViewModel — Sentence Boundary Detection

@MainActor
struct SentenceBoundaryTests {

    @Test func commitOnPeriod() {
        let vm = SessionViewModel()
        vm.pendingSentenceBuffer = "Hello world."
        vm.checkSentenceBoundary()
        #expect(vm.pendingSentenceBuffer == "")
        #expect(vm.segmentIndex == 1)
    }

    @Test func commitOnJapanesePeriod() {
        let vm = SessionViewModel()
        vm.pendingSentenceBuffer = "こんにちは。"
        vm.checkSentenceBoundary()
        #expect(vm.pendingSentenceBuffer == "")
        #expect(vm.segmentIndex == 1)
    }

    @Test func commitOnExclamation() {
        let vm = SessionViewModel()
        vm.pendingSentenceBuffer = "Wow!"
        vm.checkSentenceBoundary()
        #expect(vm.pendingSentenceBuffer == "")
        #expect(vm.segmentIndex == 1)
    }

    @Test func commitOnQuestion() {
        let vm = SessionViewModel()
        vm.pendingSentenceBuffer = "Really?"
        vm.checkSentenceBoundary()
        #expect(vm.pendingSentenceBuffer == "")
        #expect(vm.segmentIndex == 1)
    }

    @Test func commitOnFullWidthExclamation() {
        let vm = SessionViewModel()
        vm.pendingSentenceBuffer = "すごい！"
        vm.checkSentenceBoundary()
        #expect(vm.pendingSentenceBuffer == "")
        #expect(vm.segmentIndex == 1)
    }

    @Test func commitOnFullWidthQuestion() {
        let vm = SessionViewModel()
        vm.pendingSentenceBuffer = "本当？"
        vm.checkSentenceBoundary()
        #expect(vm.pendingSentenceBuffer == "")
        #expect(vm.segmentIndex == 1)
    }

    @Test func noCommitWithoutPunctuation() {
        let vm = SessionViewModel()
        vm.pendingSentenceBuffer = "Hello world"
        vm.checkSentenceBoundary()
        // Buffer should remain (timer would handle it, but we just check no immediate commit)
        #expect(vm.pendingSentenceBuffer == "Hello world")
        #expect(vm.segmentIndex == 0)
    }

    @Test func emptyBufferNoCommit() {
        let vm = SessionViewModel()
        vm.pendingSentenceBuffer = ""
        vm.checkSentenceBoundary()
        #expect(vm.segmentIndex == 0)
    }
}

// MARK: - 7. SessionViewModel — Export Functions

@MainActor
struct ExportTests {

    @Test func copyAllOriginalJoinsFinalizedLines() {
        let vm = SessionViewModel()
        vm.sourceLines = [
            TranscriptLine(text: "Line 1", isPartial: false),
            TranscriptLine(text: "Partial", isPartial: true),
            TranscriptLine(text: "Line 2", isPartial: false),
        ]
        #expect(vm.copyAllOriginal() == "Line 1\nLine 2")
    }

    @Test func copyAllOriginalExcludesSeparators() {
        let vm = SessionViewModel()
        vm.sourceLines = [
            TranscriptLine(text: "Line 1", isPartial: false),
            TranscriptLine(text: "", isPartial: false, isSeparator: true),
            TranscriptLine(text: "Line 2", isPartial: false),
        ]
        #expect(vm.copyAllOriginal() == "Line 1\nLine 2")
    }

    @Test func copyAllOriginalEmptyReturnsEmpty() {
        let vm = SessionViewModel()
        vm.sourceLines = []
        #expect(vm.copyAllOriginal() == "")
    }

    @Test func copyAllTranslationSingleSlot() {
        let vm = SessionViewModel()
        vm.displayMode = .normal
        vm.translationSlots = [TranslationSlot()]
        vm.translationSlots[0].lines = [
            TranscriptLine(text: "Translated 1", isPartial: false),
            TranscriptLine(text: "Partial", isPartial: true),
            TranscriptLine(text: "Translated 2", isPartial: false),
        ]
        #expect(vm.copyAllTranslation() == "Translated 1\nTranslated 2")
    }

    @Test func copyAllTranslationMultiSlotWithHeaders() {
        let vm = SessionViewModel()
        vm.targetCount = 2
        vm.targetLanguageIdentifiers = ["en", "zh-Hans", "ko"]
        vm.translationSlots = [TranslationSlot(), TranslationSlot()]
        vm.translationSlots[0].lines = [
            TranscriptLine(text: "English line", isPartial: false),
        ]
        vm.translationSlots[1].lines = [
            TranscriptLine(text: "中文行", isPartial: false),
        ]
        let result = vm.copyAllTranslation()
        #expect(result.contains("[EN]"))
        #expect(result.contains("English line"))
        #expect(result.contains("[ZH-HANS]"))
        #expect(result.contains("中文行"))
    }

    @Test func copyAllInterleavedFormat() {
        let vm = SessionViewModel()
        vm.sourceLines = [
            TranscriptLine(text: "Source 1", isPartial: false),
            TranscriptLine(text: "Source 2", isPartial: false),
        ]
        vm.translationSlots = [TranslationSlot()]
        vm.translationSlots[0].lines = [
            TranscriptLine(text: "Target 1", isPartial: false),
            TranscriptLine(text: "Target 2", isPartial: false),
        ]
        let result = vm.copyAllInterleaved()
        let lines = result.components(separatedBy: "\n")
        // Expected: "Source 1", "Target 1", "", "Source 2", "Target 2", ""
        #expect(lines.contains("Source 1"))
        #expect(lines.contains("Target 1"))
        #expect(lines.contains("Source 2"))
        #expect(lines.contains("Target 2"))
    }

    @Test func clearHistoryEmptiesBothSourceAndTranslation() {
        let vm = SessionViewModel()
        vm.sourceLines = [
            TranscriptLine(text: "Line", isPartial: false),
        ]
        vm.translationSlots = [TranslationSlot()]
        vm.translationSlots[0].lines = [
            TranscriptLine(text: "Translated", isPartial: false),
        ]
        vm.clearHistory()
        #expect(vm.sourceLines.isEmpty)
        #expect(vm.translationSlots[0].lines.isEmpty)
    }
}

// MARK: - 8. TranslationSlot — enqueueTranslation Tests

struct EnqueueTranslationTests {

    @Test func enqueueCreatesPlaceholderLine() {
        var slot = TranslationSlot()
        let idx = slot.enqueueTranslation(sentence: "Hello", isPartial: false)
        #expect(slot.lines.count == 1)
        #expect(slot.lines[0].isPartial == true)
        #expect(slot.lines[0].text == "…")
        #expect(slot.queue.count == 1)
        #expect(slot.queue[0].sentence == "Hello")
        #expect(slot.queue[0].targetIndex == idx)
        #expect(slot.queue[0].isPartial == false)
    }

    @Test func enqueuePartialReusesExistingPartialLine() {
        var slot = TranslationSlot()
        let idx1 = slot.enqueueTranslation(sentence: "Hel", isPartial: true)
        let idx2 = slot.enqueueTranslation(sentence: "Hello", isPartial: true)
        // Should reuse the same placeholder line
        #expect(idx1 == idx2)
        #expect(slot.lines.count == 1)
        #expect(slot.queue.count == 2)
    }

    @Test func enqueueFinalResetsPartialIndex() {
        var slot = TranslationSlot()
        let partialIdx = slot.enqueueTranslation(sentence: "Hel", isPartial: true)
        let finalIdx = slot.enqueueTranslation(sentence: "Hello.", isPartial: false, resetPartialIndex: true)
        // Final reuses the existing partial line but resets partialTargetIndex
        #expect(partialIdx == finalIdx)
        #expect(slot.partialTargetIndex == -1)
    }

    @Test func enqueueSkipsInvalidateWhenProcessing() {
        var slot = TranslationSlot()
        // Simulate a processing session — config should not be invalidated
        slot.isProcessing = true
        // No config set, so invalidate would be a no-op anyway, but verify the flag is respected
        slot.enqueueTranslation(sentence: "Test", isPartial: false)
        #expect(slot.queue.count == 1)
        #expect(slot.isProcessing == true)
    }

    @Test func enqueueAppendsNewLineWhenNoPartialExists() {
        var slot = TranslationSlot()
        // Add a finalized line first
        slot.lines.append(TranscriptLine(text: "Done", isPartial: false))
        slot.partialTargetIndex = -1
        let idx = slot.enqueueTranslation(sentence: "Next", isPartial: true)
        #expect(idx == 1) // New line appended after existing
        #expect(slot.lines.count == 2)
    }
}

// MARK: - 9. TranslationQueueItem Tests

struct TranslationQueueItemTests {

    @Test func propertiesAreStored() {
        let item = TranslationQueueItem(sentence: "Hello", targetIndex: 3, isPartial: true)
        #expect(item.sentence == "Hello")
        #expect(item.targetIndex == 3)
        #expect(item.isPartial == true)
    }
}

// MARK: - 10. SessionViewModel — Language Swap Tests

@MainActor
struct LanguageSwapTests {

    @Test func swapIsDisabledDuringActiveSession() {
        let vm = SessionViewModel()
        vm.isSessionActive = true
        let oldSource = vm.sourceLocaleIdentifier
        let oldTarget = vm.targetLanguageIdentifier
        vm.swapLanguages()
        // Should be no-op when session is active
        #expect(vm.sourceLocaleIdentifier == oldSource)
        #expect(vm.targetLanguageIdentifier == oldTarget)
    }

    @Test func swapWithEmptyLocalesIsNoOp() {
        let vm = SessionViewModel()
        vm.supportedSourceLocales = []
        let oldSource = vm.sourceLocaleIdentifier
        let oldTarget = vm.targetLanguageIdentifier
        vm.swapLanguages()
        // No candidates found, swap should be no-op
        #expect(vm.sourceLocaleIdentifier == oldSource)
        // Target may or may not change depending on old source lang code
    }

    @Test func swapWithMatchingLocalesSwapsCorrectly() {
        let vm = SessionViewModel()
        vm.isSessionActive = false
        // Set up locales: source=ja_JP, target=en
        vm.sourceLocaleIdentifier = "ja_JP"
        vm.targetLanguageIdentifier = "en"
        // Provide both locales as supported sources
        vm.supportedSourceLocales = [
            Locale(identifier: "ja_JP"),
            Locale(identifier: "en_US"),
        ]
        vm.swapLanguages()
        // Source should now be en_US (matched from target "en")
        #expect(vm.sourceLocaleIdentifier == "en_US")
        // Target should now be ja (from old source ja_JP's language code)
        #expect(vm.targetLanguageIdentifier == "ja")
    }
}

// MARK: - 11. SessionViewModel — hasTranscriptContent

@MainActor
struct HasTranscriptContentTests {

    @Test func emptyStateReturnsFalse() {
        let vm = SessionViewModel()
        vm.sourceLines = []
        vm.translationSlots = [TranslationSlot()]
        #expect(vm.hasTranscriptContent == false)
    }

    @Test func withSourceLinesReturnsTrue() {
        let vm = SessionViewModel()
        vm.sourceLines = [TranscriptLine(text: "Hello", isPartial: false)]
        vm.translationSlots = [TranslationSlot()]
        #expect(vm.hasTranscriptContent == true)
    }

    @Test func withTranslationLinesReturnsTrue() {
        let vm = SessionViewModel()
        vm.sourceLines = []
        vm.translationSlots = [TranslationSlot()]
        vm.translationSlots[0].lines = [TranscriptLine(text: "Hello", isPartial: false)]
        #expect(vm.hasTranscriptContent == true)
    }

    @Test func withEmptySlotsArrayReturnsFalseNotCrash() {
        let vm = SessionViewModel()
        vm.sourceLines = []
        vm.translationSlots = []
        // Should not crash, should return false
        #expect(vm.hasTranscriptContent == false)
    }
}
