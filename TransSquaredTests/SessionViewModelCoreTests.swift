//
//  SessionViewModelCoreTests.swift
//  TransSquaredTests
//

import Foundation
import Testing
@testable import TransSquared

// MARK: - Entry Helper Tests

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

// MARK: - hasTranscriptContent Tests

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
        vm.recomputeDisplayLines()
        #expect(vm.hasTranscriptContent == true)
    }

    @Test func withSeparatorOnlyReturnsTrue() {
        let vm = makeTestViewModel()
        vm.entries = [TranscriptEntry(isSeparator: true)]
        vm.recomputeDisplayLines()
        #expect(vm.hasTranscriptContent == true)
    }
}

// MARK: - Font Size Tests

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

// MARK: - Display Mode Toggle Tests

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

// MARK: - Entry Index Map Tests

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

// MARK: - Adjusted Elapsed Time Tests

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

// MARK: - Recompute Display Lines Tests

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

// MARK: - Reset Transcript State Tests

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

// MARK: - Initialization & Persistence Tests

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

// MARK: - Contextual Strings Tests

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
