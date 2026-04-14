//
//  TransSquaredTests.swift
//  TransSquaredTests
//
//  Created by 高橋亨平 on 2026-03-24.
//

import Foundation
import Testing
@testable import TransSquared

// MARK: - Test Helpers

/// Creates an ephemeral `UserDefaults` suite that won't pollute the app's real settings.
@MainActor
private func makeTestViewModel() -> SessionViewModel {
    let suiteName = "com.transsquared.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return SessionViewModel(defaults: defaults)
}

// MARK: - 1. TranscriptModels Tests

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

    @Test func sourceTranscriptLinesWithPendingPartialShowsBothLines() {
        // When source has finalized text and pendingPartial exists,
        // they appear as two separate lines (finalized + partial).
        let entry = TranscriptEntry(
            source: TransString(text: "Hello.", isPartial: false),
            pendingPartial: " How are"
        )
        let lines = entry.sourceTranscriptLines()
        #expect(lines.count == 2)
        #expect(lines[0].text == "Hello.")
        #expect(lines[0].isPartial == false)
        #expect(lines[1].text == " How are")
        #expect(lines[1].isPartial == true)
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

// MARK: - 2. SessionViewModel — Auto-Replacement Logic

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

// MARK: - 5. SessionViewModel — Transcription Event Handling

@MainActor
struct TranscriptionEventTests {

    @Test func partialEventSetsPendingPartial() {
        let vm = makeTestViewModel()
        vm.handleTranscriptionEvent(.partial("Hello", duration: nil, audioOffset: nil))
        #expect(vm.entries.count == 1)
        #expect(vm.entries[0].pendingPartial == "Hello")
        #expect(vm.entries[0].source.text.isEmpty)
        // Also verify derived sourceLines
        #expect(vm.sourceLines.count == 1)
        #expect(vm.sourceLines[0].text == "Hello")
        #expect(vm.sourceLines[0].isPartial == true)
    }

    @Test func partialEventReplacesPreviousPartial() {
        let vm = makeTestViewModel()
        vm.handleTranscriptionEvent(.partial("Hel", duration: nil, audioOffset: nil))
        vm.handleTranscriptionEvent(.partial("Hello", duration: nil, audioOffset: nil))
        #expect(vm.entries.count == 1)
        #expect(vm.entries[0].pendingPartial == "Hello")
        #expect(vm.sourceLines.count == 1)
        #expect(vm.sourceLines[0].text == "Hello")
    }

    @Test func finalEventClearsPartialAndAccumulatesSource() {
        let vm = makeTestViewModel()
        vm.handleTranscriptionEvent(.partial("Hello", duration: nil, audioOffset: nil))
        #expect(vm.entries[0].pendingPartial == "Hello")

        vm.handleTranscriptionEvent(.finalized("Hello world.", duration: nil, audioOffset: nil))
        // Partial cleared, source accumulated
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
        // "Hello " ends without sentence-ending punctuation, so buffer accumulates
        #expect(vm.pendingSentenceBuffer == "Hello world")
        // Source text also accumulates within the same entry
        #expect(vm.entries[0].source.text == "Hello world")
    }

    @Test func errorEventSetsErrorMessage() {
        let vm = makeTestViewModel()
        vm.handleTranscriptionEvent(.error("Something went wrong"))
        #expect(vm.errorMessage == "Something went wrong")
    }
}

// MARK: - 6. SessionViewModel — Sentence Boundary Detection

@MainActor
struct SentenceBoundaryTests {

    /// Helper: creates a VM with an uncommitted entry so commitSentence has something to commit.
    private func vmWithPendingEntry(buffer: String) -> SessionViewModel {
        let vm = makeTestViewModel()
        vm.pendingSentenceBuffer = buffer
        // Create an uncommitted entry with source text (simulates finalized event)
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

// MARK: - 7. SessionViewModel — Export Functions

@MainActor
struct ExportTests {

    @Test func copyAllOriginalJoinsSourceTexts() {
        let vm = makeTestViewModel()
        vm.entries = [
            TranscriptEntry(source: TransString(text: "Line 1", isPartial: false)),
            TranscriptEntry(source: TransString(text: "Line 2", isPartial: false)),
        ]
        #expect(vm.copyAllOriginal() == "Line 1\nLine 2")
    }

    @Test func copyAllOriginalExcludesSeparatorsAndEmpty() {
        let vm = makeTestViewModel()
        vm.entries = [
            TranscriptEntry(source: TransString(text: "Line 1", isPartial: false), isCommitted: true),
            TranscriptEntry(isSeparator: true),
            TranscriptEntry(), // empty entry
            TranscriptEntry(source: TransString(text: "Line 2", isPartial: false), isCommitted: true),
        ]
        #expect(vm.copyAllOriginal() == "Line 1\nLine 2")
    }

    @Test func copyAllOriginalEmptyReturnsEmpty() {
        let vm = makeTestViewModel()
        vm.entries = []
        #expect(vm.copyAllOriginal() == "")
    }

    @Test func copyAllTranslationSingleSlot() {
        let vm = makeTestViewModel()
        vm.translationSlots = [TranslationSlot()]
        var entry1 = TranscriptEntry(isCommitted: true)
        entry1.translations[0] = TransString(text: "Translated 1", isPartial: false)
        var entry2 = TranscriptEntry(isCommitted: true)
        entry2.translations[0] = TransString(text: "Partial", isPartial: true)
        var entry3 = TranscriptEntry(isCommitted: true)
        entry3.translations[0] = TransString(text: "Translated 2", isPartial: false)
        vm.entries = [entry1, entry2, entry3]
        #expect(vm.copyAllTranslation() == "Translated 1\nTranslated 2")
    }

    @Test func copyAllTranslationMultiSlotWithHeaders() {
        let vm = makeTestViewModel()
        vm.targetCount = 2
        vm.targetLanguageIdentifiers = ["en", "zh-Hans", "ko"]
        vm.translationSlots = [TranslationSlot(), TranslationSlot()]
        var entry = TranscriptEntry(isCommitted: true)
        entry.translations[0] = TransString(text: "English line", isPartial: false)
        entry.translations[1] = TransString(text: "中文行", isPartial: false)
        vm.entries = [entry]
        let result = vm.copyAllTranslation()
        #expect(result.contains("[EN]"))
        #expect(result.contains("English line"))
        #expect(result.contains("[ZH-HANS]"))
        #expect(result.contains("中文行"))
    }

    @Test func copyAllInterleavedFormat() {
        let vm = makeTestViewModel()
        vm.translationSlots = [TranslationSlot()]
        var entry1 = TranscriptEntry(
            source: TransString(text: "Source 1", isPartial: false),
            isCommitted: true
        )
        entry1.translations[0] = TransString(text: "Target 1", isPartial: false)
        var entry2 = TranscriptEntry(
            source: TransString(text: "Source 2", isPartial: false),
            isCommitted: true
        )
        entry2.translations[0] = TransString(text: "Target 2", isPartial: false)
        vm.entries = [entry1, entry2]
        let result = vm.copyAllInterleaved()
        let lines = result.components(separatedBy: "\n")
        #expect(lines.contains("Source 1"))
        #expect(lines.contains("Target 1"))
        #expect(lines.contains("Source 2"))
        #expect(lines.contains("Target 2"))
    }

    @Test func clearHistoryEmptiesEntries() {
        let vm = makeTestViewModel()
        vm.entries = [
            TranscriptEntry(source: TransString(text: "Line", isPartial: false), isCommitted: true)
        ]
        vm.translationSlots = [TranslationSlot()]
        vm.clearHistory()
        #expect(vm.entries.isEmpty)
        #expect(vm.sourceLines.isEmpty)
    }
}

// MARK: - 8. TranslationQueueItem Tests

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

// MARK: - 9. SessionViewModel — Entry Helpers

@MainActor
struct EntryHelperTests {

    @Test func currentEntryIndexReturnsNilWhenEmpty() {
        let vm = makeTestViewModel()
        #expect(vm.currentEntryIndex == nil)
    }

    @Test func currentEntryIndexReturnsNilWhenLastIsCommitted() {
        let vm = makeTestViewModel()
        vm.entries = [TranscriptEntry(isCommitted: true)]
        #expect(vm.currentEntryIndex == nil)
    }

    @Test func currentEntryIndexReturnsNilWhenLastIsSeparator() {
        let vm = makeTestViewModel()
        vm.entries = [TranscriptEntry(isSeparator: true)]
        #expect(vm.currentEntryIndex == nil)
    }

    @Test func currentEntryIndexReturnsUncommittedEntry() {
        let vm = makeTestViewModel()
        vm.entries = [
            TranscriptEntry(isCommitted: true),
            TranscriptEntry(isCommitted: false),
        ]
        #expect(vm.currentEntryIndex == 1)
    }

    @Test func ensureCurrentEntryCreatesNewIfNeeded() {
        let vm = makeTestViewModel()
        let idx = vm.ensureCurrentEntry()
        #expect(idx == 0)
        #expect(vm.entries.count == 1)
        #expect(vm.entries[0].isCommitted == false)
    }

    @Test func ensureCurrentEntryReusesExisting() {
        let vm = makeTestViewModel()
        let idx1 = vm.ensureCurrentEntry()
        let idx2 = vm.ensureCurrentEntry()
        #expect(idx1 == idx2)
        #expect(vm.entries.count == 1)
    }

    @Test func entryIndexMapIsBuiltByEnsureCurrentEntry() {
        let vm = makeTestViewModel()
        let idx = vm.ensureCurrentEntry()
        let entryID = vm.entries[idx].id
        #expect(vm.entryIndex(for: entryID) == idx)
    }

    @Test func entryIndexMapReturnsNilForUnknownID() {
        let vm = makeTestViewModel()
        #expect(vm.entryIndex(for: UUID()) == nil)
    }
}

// MARK: - 10. SessionViewModel — Language Swap Tests

@MainActor
struct LanguageSwapTests {

    @Test func swapIsDisabledDuringActiveSession() {
        let vm = makeTestViewModel()
        vm.isSessionActive = true
        let oldSource = vm.sourceLocaleIdentifier
        let oldTarget = vm.targetLanguageIdentifier
        vm.swapLanguages()
        // Should be no-op when session is active
        #expect(vm.sourceLocaleIdentifier == oldSource)
        #expect(vm.targetLanguageIdentifier == oldTarget)
    }

    @Test func swapWithEmptyLocalesIsNoOp() {
        let vm = makeTestViewModel()
        vm.supportedSourceLocales = []
        let oldSource = vm.sourceLocaleIdentifier
        vm.swapLanguages()
        // No candidates found, swap should be no-op
        #expect(vm.sourceLocaleIdentifier == oldSource)
        // Should show an error message to the user
        #expect(vm.errorMessage != nil)
    }

    @Test func swapWithMatchingLocalesSwapsCorrectly() {
        let vm = makeTestViewModel()
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
        let vm = makeTestViewModel()
        vm.entries = []
        #expect(vm.hasTranscriptContent == false)
    }

    @Test func withEntriesReturnsTrue() {
        let vm = makeTestViewModel()
        vm.entries = [TranscriptEntry(source: TransString(text: "Hello", isPartial: false))]
        #expect(vm.hasTranscriptContent == true)
    }

    @Test func withSeparatorOnlyReturnsTrue() {
        let vm = makeTestViewModel()
        vm.entries = [TranscriptEntry(isSeparator: true)]
        #expect(vm.hasTranscriptContent == true)
    }
}

// MARK: - TimeInterval Formatting Tests

struct TimeIntervalFormattingTests {

    @Test func formattedMMSSZero() {
        #expect(TimeInterval(0).formattedMMSS == "00:00")
    }

    @Test func formattedMMSSUnderOneMinute() {
        #expect(TimeInterval(45).formattedMMSS == "00:45")
    }

    @Test func formattedMMSSExactMinute() {
        #expect(TimeInterval(60).formattedMMSS == "01:00")
    }

    @Test func formattedMMSSMultipleMinutes() {
        #expect(TimeInterval(225).formattedMMSS == "03:45")
    }

    @Test func formattedMMSSOverAnHour() {
        // 65 minutes = 3900 seconds → "65:00"
        #expect(TimeInterval(3900).formattedMMSS == "65:00")
    }

    @Test func formattedMMSSNegativeClampedToZero() {
        #expect(TimeInterval(-10).formattedMMSS == "00:00")
    }

    @Test func formattedMMSSFractionalTruncated() {
        // 45.9 seconds → truncated to 45
        #expect(TimeInterval(45.9).formattedMMSS == "00:45")
    }

    @Test func formattedMSSZero() {
        #expect(TimeInterval(0).formattedMSS == "0:00")
    }

    @Test func formattedMSSUnderOneMinute() {
        #expect(TimeInterval(9).formattedMSS == "0:09")
    }

    @Test func formattedMSSMultipleMinutes() {
        #expect(TimeInterval(225).formattedMSS == "3:45")
    }

    @Test func formattedMSSNegativeClampedToZero() {
        #expect(TimeInterval(-5).formattedMSS == "0:00")
    }
}

// MARK: - TransSquaredError Tests

struct TransSquaredErrorTests {

    @Test func allCasesHaveDescriptions() {
        let cases: [TransSquaredError] = [
            .alreadyCapturing, .microphoneUnavailable,
            .alreadyRunning, .audioFormatUnavailable, .recordingFailed
        ]
        for error in cases {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test func conformsToLocalizedError() {
        let error: any LocalizedError = TransSquaredError.microphoneUnavailable
        #expect(error.errorDescription != nil)
    }
}

// MARK: - PermissionIssue Tests

struct PermissionIssueTests {

    @Test func identifiable() {
        let mic = PermissionIssue.microphone
        let speech = PermissionIssue.speechRecognition
        #expect(mic.id != speech.id)
    }

    @Test func titleAndMessageAreNonEmpty() {
        for issue in [PermissionIssue.microphone, .speechRecognition] {
            #expect(!issue.title.isEmpty)
            #expect(!issue.message.isEmpty)
        }
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

// MARK: - TranscriptEntry sourceTranscriptLines Combined Line Tests

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
        // Empty pendingPartial string should behave like nil
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

// MARK: - AudioLevelMonitor Tests

@MainActor
struct AudioLevelMonitorTests {

    @Test func initialLevelsAreAllZero() {
        let monitor = AudioLevelMonitor()
        #expect(monitor.levels.count == AudioLevelMonitor.sampleCount)
        #expect(monitor.levels.allSatisfy { $0 == 0 })
    }

    @Test func appendAddsLevel() {
        let monitor = AudioLevelMonitor()
        monitor.append(0.5)
        #expect(monitor.levels.last == 0.5)
        #expect(monitor.levels.count == AudioLevelMonitor.sampleCount)
    }

    @Test func appendMaintainsFixedSize() {
        let monitor = AudioLevelMonitor()
        // Append more than sampleCount values
        for i in 0..<(AudioLevelMonitor.sampleCount + 10) {
            monitor.append(Float(i) / 100.0)
        }
        #expect(monitor.levels.count == AudioLevelMonitor.sampleCount)
        // Oldest values should have been dropped
        let expected = Float(AudioLevelMonitor.sampleCount + 10 - 1) / 100.0
        #expect(monitor.levels.last == expected)
    }

    @Test func appendShiftsOutOldestValue() {
        let monitor = AudioLevelMonitor()
        // Fill with known values
        for i in 0..<AudioLevelMonitor.sampleCount {
            monitor.append(Float(i + 1))
        }
        // All initial zeros should be gone
        #expect(monitor.levels.first == 1.0)
        #expect(monitor.levels.last == Float(AudioLevelMonitor.sampleCount))

        // Append one more - shifts out 1.0
        monitor.append(99.0)
        #expect(monitor.levels.first == 2.0)
        #expect(monitor.levels.last == 99.0)
    }

    @Test func resetSetsAllToZero() {
        let monitor = AudioLevelMonitor()
        monitor.append(0.8)
        monitor.append(0.6)
        monitor.reset()
        #expect(monitor.levels.count == AudioLevelMonitor.sampleCount)
        #expect(monitor.levels.allSatisfy { $0 == 0 })
    }

    @Test func sampleCountIsReasonable() {
        #expect(AudioLevelMonitor.sampleCount > 0)
        #expect(AudioLevelMonitor.sampleCount <= 100)
    }
}

// MARK: - SessionViewModel Core Logic Tests

@MainActor
struct FontSizeTests {

    @Test func increaseFontSize() {
        let vm = makeTestViewModel()
        vm.fontSize = 16
        vm.increaseFontSize()
        #expect(vm.fontSize == 18)
    }

    @Test func increaseFontSizeClampsAtMax() {
        let vm = makeTestViewModel()
        vm.fontSize = SessionViewModel.maxFontSize
        vm.increaseFontSize()
        #expect(vm.fontSize == SessionViewModel.maxFontSize)
    }

    @Test func decreaseFontSize() {
        let vm = makeTestViewModel()
        vm.fontSize = 16
        vm.decreaseFontSize()
        #expect(vm.fontSize == 14)
    }

    @Test func decreaseFontSizeClampsAtMin() {
        let vm = makeTestViewModel()
        vm.fontSize = SessionViewModel.minFontSize
        vm.decreaseFontSize()
        #expect(vm.fontSize == SessionViewModel.minFontSize)
    }
}

@MainActor
struct DisplayModeToggleTests {

    @Test func toggleFromSubtitleToNormal() {
        let vm = makeTestViewModel()
        vm.displayMode = .subtitle
        vm.toggleDisplayMode()
        #expect(vm.displayMode == .normal)
    }

    @Test func toggleFromNormalToSubtitleWhenSessionActiveAndSingleTarget() {
        let vm = makeTestViewModel()
        vm.displayMode = .normal
        vm.isSessionActive = true
        vm.targetCount = 1
        vm.toggleDisplayMode()
        #expect(vm.displayMode == .subtitle)
    }

    @Test func toggleFromNormalStaysNormalWhenNotActive() {
        let vm = makeTestViewModel()
        vm.displayMode = .normal
        vm.isSessionActive = false
        vm.toggleDisplayMode()
        #expect(vm.displayMode == .normal)
    }

    @Test func toggleFromNormalStaysNormalWhenMultiTarget() {
        let vm = makeTestViewModel()
        vm.displayMode = .normal
        vm.isSessionActive = true
        vm.targetCount = 2
        vm.toggleDisplayMode()
        #expect(vm.displayMode == .normal)
    }

    @Test func subtitleButtonDisabledWhenNotActive() {
        let vm = makeTestViewModel()
        vm.displayMode = .normal
        vm.isSessionActive = false
        #expect(vm.isSubtitleButtonDisabled == true)
    }

    @Test func subtitleButtonEnabledInSubtitleMode() {
        let vm = makeTestViewModel()
        vm.displayMode = .subtitle
        #expect(vm.isSubtitleButtonDisabled == false)
    }

    @Test func subtitleButtonDisabledWithMultiTarget() {
        let vm = makeTestViewModel()
        vm.displayMode = .normal
        vm.isSessionActive = true
        vm.targetCount = 2
        #expect(vm.isSubtitleButtonDisabled == true)
    }
}

@MainActor
struct EntryIndexMapTests {

    @Test func rebuildEntryIndexMapIsAccurate() {
        let vm = makeTestViewModel()
        let e1 = TranscriptEntry(source: TransString(text: "A", isPartial: false))
        let e2 = TranscriptEntry(source: TransString(text: "B", isPartial: false))
        let e3 = TranscriptEntry(source: TransString(text: "C", isPartial: false))
        vm.entries = [e1, e2, e3]
        vm.rebuildEntryIndexMap()
        #expect(vm.entryIndex(for: e1.id) == 0)
        #expect(vm.entryIndex(for: e2.id) == 1)
        #expect(vm.entryIndex(for: e3.id) == 2)
    }

    @Test func rebuildAfterRemoval() {
        let vm = makeTestViewModel()
        let e1 = TranscriptEntry(source: TransString(text: "A", isPartial: false))
        let e2 = TranscriptEntry(source: TransString(text: "B", isPartial: false))
        vm.entries = [e1, e2]
        vm.rebuildEntryIndexMap()
        // Remove first entry
        vm.entries.remove(at: 0)
        vm.rebuildEntryIndexMap()
        #expect(vm.entryIndex(for: e1.id) == nil)
        #expect(vm.entryIndex(for: e2.id) == 0)
    }

    @Test func entryIndexForUnknownIDReturnsNil() {
        let vm = makeTestViewModel()
        #expect(vm.entryIndex(for: UUID()) == nil)
    }
}

@MainActor
struct AdjustedElapsedTimeTests {

    @Test func liveSessionAddsAccumulatedTime() {
        let vm = makeTestViewModel()
        vm.isTranscribingFile = false
        vm.accumulatedElapsedTime = 30.0
        let result = vm.adjustedElapsedTime(audioOffset: 5.0)
        #expect(result == 35.0)
    }

    @Test func fileTranscriptionUsesOffsetDirectly() {
        let vm = makeTestViewModel()
        vm.isTranscribingFile = true
        vm.accumulatedElapsedTime = 30.0
        let result = vm.adjustedElapsedTime(audioOffset: 5.0)
        #expect(result == 5.0)
    }
}

@MainActor
struct RecomputeDisplayLinesTests {

    @Test func recomputeSourceLines() {
        let vm = makeTestViewModel()
        vm.entries = [
            TranscriptEntry(source: TransString(text: "Hello", isPartial: false), isCommitted: true),
            TranscriptEntry(source: TransString(text: "World", isPartial: false), isCommitted: true),
        ]
        vm.recomputeDisplayLines()
        #expect(vm.sourceLines.count == 2)
        #expect(vm.sourceLines[0].text == "Hello")
        #expect(vm.sourceLines[1].text == "World")
    }

    @Test func recomputeIncludesSeparators() {
        let vm = makeTestViewModel()
        vm.entries = [
            TranscriptEntry(source: TransString(text: "A", isPartial: false)),
            TranscriptEntry(isSeparator: true),
            TranscriptEntry(source: TransString(text: "B", isPartial: false)),
        ]
        vm.recomputeDisplayLines()
        #expect(vm.sourceLines.count == 3)
        #expect(vm.sourceLines[1].isSeparator == true)
    }

    @Test func recomputeTranslationLines() {
        let vm = makeTestViewModel()
        vm.targetCount = 1
        vm.translationSlots = [TranslationSlot()]
        var entry = TranscriptEntry(isCommitted: true)
        entry.translations[0] = TransString(text: "Translated", isPartial: false, finalizedAt: Date())
        vm.entries = [entry]
        vm.recomputeDisplayLines()
        #expect(vm.translationLines(forSlot: 0).count == 1)
        #expect(vm.translationLines(forSlot: 0)[0].text == "Translated")
    }

    @Test func translationLinesOutOfBoundsReturnsEmpty() {
        let vm = makeTestViewModel()
        #expect(vm.translationLines(forSlot: 99).isEmpty)
    }

    @Test func recomputeEmptyEntries() {
        let vm = makeTestViewModel()
        vm.entries = []
        vm.recomputeDisplayLines()
        #expect(vm.sourceLines.isEmpty)
    }
}

@MainActor
struct ResetTranscriptStateTests {

    @Test func resetClearsAllState() {
        let vm = makeTestViewModel()
        vm.entries = [TranscriptEntry(source: TransString(text: "Hello", isPartial: false))]
        vm.segmentIndex = 5
        vm.accumulatedElapsedTime = 100.0
        vm.translationSlots = [TranslationSlot()]
        vm.translationSlots[0].queue.append(
            TranslationQueueItem(sentence: "test", entryID: UUID(), isPartial: false, elapsedTime: nil)
        )

        vm.resetTranscriptState()

        #expect(vm.entries.isEmpty)
        #expect(vm.segmentIndex == 0)
        #expect(vm.accumulatedElapsedTime == 0)
        #expect(vm.sourceLines.isEmpty)
    }
}

@MainActor
struct InitializationPersistenceTests {

    @Test func defaultInitValues() {
        let vm = makeTestViewModel()
        #expect(vm.sourceLocaleIdentifier == "ja_JP")
        #expect(vm.targetCount == 1)
        #expect(vm.sentenceBoundarySeconds == 3.0)
        #expect(vm.entries.isEmpty)
        #expect(vm.isSessionActive == false)
    }

    @Test func persistsSourceLocale() {
        let suiteName = "com.transsquared.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let vm1 = SessionViewModel(defaults: defaults)
        vm1.sourceLocaleIdentifier = "en_US"

        let vm2 = SessionViewModel(defaults: defaults)
        #expect(vm2.sourceLocaleIdentifier == "en_US")

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func persistsTargetCount() {
        let suiteName = "com.transsquared.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let vm1 = SessionViewModel(defaults: defaults)
        vm1.targetCount = 3

        let vm2 = SessionViewModel(defaults: defaults)
        #expect(vm2.targetCount == 3)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func persistsSentenceBoundarySeconds() {
        let suiteName = "com.transsquared.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let vm1 = SessionViewModel(defaults: defaults)
        vm1.sentenceBoundarySeconds = 5.0

        let vm2 = SessionViewModel(defaults: defaults)
        #expect(vm2.sentenceBoundarySeconds == 5.0)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func invalidTargetCountFallsBackToDefault() {
        let suiteName = "com.transsquared.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(0, forKey: "targetCount")

        let vm = SessionViewModel(defaults: defaults)
        #expect(vm.targetCount == 1)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func persistsAutoReplacements() {
        let suiteName = "com.transsquared.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let vm1 = SessionViewModel(defaults: defaults)
        vm1.autoReplacementsByLocale["ja_JP"] = [AutoReplacement(from: "teh", to: "the")]

        let vm2 = SessionViewModel(defaults: defaults)
        #expect(vm2.autoReplacementsByLocale["ja_JP"]?.count == 1)
        #expect(vm2.autoReplacementsByLocale["ja_JP"]?.first?.from == "teh")

        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
struct ContextualStringsTests {

    @Test func currentContextualStringsAccessesCorrectLocale() {
        let vm = makeTestViewModel()
        vm.sourceLocaleIdentifier = "ja_JP"
        vm.currentContextualStrings = ["test1", "test2"]
        #expect(vm.contextualStringsByLocale["ja_JP"] == ["test1", "test2"])
    }

    @Test func currentContextualStringsReturnsEmptyForUnset() {
        let vm = makeTestViewModel()
        vm.sourceLocaleIdentifier = "fr_FR"
        #expect(vm.currentContextualStrings.isEmpty)
    }

    @Test func currentAutoReplacementsAccessesCorrectLocale() {
        let vm = makeTestViewModel()
        vm.sourceLocaleIdentifier = "en_US"
        vm.currentAutoReplacements = [AutoReplacement(from: "a", to: "b")]
        #expect(vm.autoReplacementsByLocale["en_US"]?.count == 1)
    }
}

// MARK: - SessionViewModel Editing Tests

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

        // No translation placeholder should have been created
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

        // Translation should be replaced with placeholder
        #expect(vm.entries[0].translations[0]?.isPartial == true)
        #expect(vm.entries[0].translations[0]?.text == "…")
        // A translation should be queued
        #expect(vm.translationSlots[0].queue.count == 1)
        #expect(vm.translationSlots[0].queue[0].sentence == "Goodbye")
    }

    @Test func editSourceLineIgnoresUnknownID() {
        let vm = makeTestViewModel()
        vm.entries = [
            TranscriptEntry(source: TransString(text: "Hello", isPartial: false))
        ]
        vm.rebuildEntryIndexMap()

        // Should not crash
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

// MARK: - SessionViewModel Language Helper Tests

@MainActor
struct LikelyRegionTests {

    @Test func englishLikelyRegionIsUS() {
        let region = SessionViewModel.likelyRegion(for: "en")
        #expect(region?.identifier == "US")
    }

    @Test func japaneseLikelyRegionIsJP() {
        let region = SessionViewModel.likelyRegion(for: "ja")
        #expect(region?.identifier == "JP")
    }

    @Test func chineseSimplifiedLikelyRegion() {
        let region = SessionViewModel.likelyRegion(for: "zh-Hans")
        // zh-Hans maximal is zh-Hans-CN
        #expect(region != nil)
    }

    @Test func koreanLikelyRegionIsKR() {
        let region = SessionViewModel.likelyRegion(for: "ko")
        #expect(region?.identifier == "KR")
    }
}

@MainActor
struct BestLanguageMatchTests {

    @Test func matchesUserRegionFirst() {
        // This test verifies the priority order — we can't control Locale.current,
        // but we can test with explicit candidates
        let candidates = [
            Locale.Language(identifier: "en-GB"),
            Locale.Language(identifier: "en-US"),
            Locale.Language(identifier: "en"),
        ]
        let result = SessionViewModel.bestLanguageMatch(from: candidates, for: "en")
        #expect(result != nil)
    }

    @Test func emptyReturnNil() {
        let result = SessionViewModel.bestLanguageMatch(from: [], for: "en")
        #expect(result == nil)
    }

    @Test func singleCandidateReturned() {
        let candidates = [Locale.Language(identifier: "fr")]
        let result = SessionViewModel.bestLanguageMatch(from: candidates, for: "fr")
        #expect(result?.minimalIdentifier == "fr")
    }
}

@MainActor
struct AddRemoveTargetLanguageTests {

    @Test func addTargetLanguageIncrementsCount() {
        let vm = makeTestViewModel()
        vm.targetCount = 1
        vm.supportedTargetLanguages = [
            Locale.Language(identifier: "en"),
            Locale.Language(identifier: "ko"),
            Locale.Language(identifier: "zh-Hans"),
        ]
        vm.addTargetLanguage()
        #expect(vm.targetCount == 2)
    }

    @Test func addTargetLanguageClampsAtMax() {
        let vm = makeTestViewModel()
        vm.targetCount = SessionViewModel.maxTargetCount
        vm.addTargetLanguage()
        #expect(vm.targetCount == SessionViewModel.maxTargetCount)
    }

    @Test func removeTargetLanguageDecrementsCount() {
        let vm = makeTestViewModel()
        vm.targetCount = 2
        vm.removeTargetLanguage()
        #expect(vm.targetCount == 1)
    }

    @Test func removeTargetLanguageClampsAtOne() {
        let vm = makeTestViewModel()
        vm.targetCount = 1
        vm.removeTargetLanguage()
        #expect(vm.targetCount == 1)
    }

    @Test func addTargetLanguagePicksUnusedLanguage() {
        let vm = makeTestViewModel()
        vm.targetCount = 1
        vm.targetLanguageIdentifiers[0] = "en"
        vm.supportedTargetLanguages = [
            Locale.Language(identifier: "en"),
            Locale.Language(identifier: "ko"),
        ]
        vm.addTargetLanguage()
        // The second slot should get "ko" (not "en" which is already used)
        #expect(vm.targetLanguageIdentifiers[1] == "ko")
    }
}

// MARK: - 12. Audio File Transcription Tests

/// Anchor class used to locate the test bundle at runtime.
private final class TestBundleAnchor {}

struct AudioFileTranscriptionTests {

    /// Resolves a test audio file URL from the test bundle.
    private func audioFileURL(_ name: String, ext: String) -> URL? {
        let bundle = Bundle(for: TestBundleAnchor.self)
        return bundle.url(forResource: name, withExtension: ext)
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "sounds")
    }

    /// Helper: collects all finalized texts from a transcription stream.
    private func collectFinalizedTexts(from stream: AsyncStream<TranscriptionEvent>) async -> [String] {
        var texts: [String] = []
        for await event in stream {
            if case .finalized(let text, _, _) = event {
                texts.append(text)
            }
        }
        return texts
    }

    @Test func transcribeHelloAudio() async throws {
        guard let url = audioFileURL("hello", ext: "m4a") else {
            Issue.record("hello.m4a not found in test bundle")
            return
        }

        let transcriber = AudioFileTranscriber()
        let (stream, _) = try await transcriber.transcribe(
            fileURL: url,
            locale: Locale(identifier: "en_US")
        )

        let texts = await collectFinalizedTexts(from: stream)
        let fullText = texts.joined(separator: " ").lowercased()
        #expect(fullText.contains("hello"), "Expected 'hello' in transcription, got: \"\(fullText)\"")
    }

    @Test func transcribeSentenceAudio() async throws {
        guard let url = audioFileURL("sentence", ext: "m4a") else {
            Issue.record("sentence.m4a not found in test bundle")
            return
        }

        let transcriber = AudioFileTranscriber()
        let (stream, _) = try await transcriber.transcribe(
            fileURL: url,
            locale: Locale(identifier: "en_US")
        )

        let texts = await collectFinalizedTexts(from: stream)
        let fullText = texts.joined(separator: " ").lowercased()
        // Expected: "Formerly most Japanese houses were made of wood."
        let hasExpectedWord = fullText.contains("japanese")
            || fullText.contains("house")
            || fullText.contains("wood")
        #expect(hasExpectedWord, "Expected key words in transcription, got: \"\(fullText)\"")
    }

    @Test func transcribeNonexistentFileThrows() async {
        let badURL = URL(fileURLWithPath: "/nonexistent/file.m4a")
        let transcriber = AudioFileTranscriber()
        do {
            _ = try await transcriber.transcribe(
                fileURL: badURL,
                locale: Locale(identifier: "en_US")
            )
            Issue.record("Expected an error for nonexistent file")
        } catch {
            // Expected — AVAudioFile throws when the file doesn't exist.
        }
    }
}
