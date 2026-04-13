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
func makeTestViewModel() -> SessionViewModel {
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

    @Test func sourceTranscriptLinesWithPendingPartialCombinesIntoOneLine() {
        // When source has finalized text and pendingPartial exists, they are merged
        // into a single partial line so the view can style each portion differently
        // via `finalizedPrefix`.
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
        slot.isProcessing = true
        slot.currentItem = TranslationQueueItem(sentence: "running", entryID: UUID(), isPartial: false, elapsedTime: nil)

        slot.reset()

        #expect(slot.queue.isEmpty)
        #expect(slot.partialEntryID == nil)
        #expect(slot.isProcessing == false)
        #expect(slot.currentItem == nil)
    }

    @Test func defaultValues() {
        let slot = TranslationSlot()
        #expect(slot.queue.isEmpty)
        #expect(slot.partialEntryID == nil)
        #expect(slot.isProcessing == false)
        #expect(slot.currentItem == nil)
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
