//
//  ModelEdgeCaseTests.swift
//  TransSquaredTests
//

import Foundation
import Testing
@testable import TransSquared

// MARK: - PermissionIssue Tests

struct PermissionIssueTests {

    @Test func microphone_idIsMicrophone() {
        #expect(PermissionIssue.microphone.id == "microphone")
    }

    @Test func speechRecognition_idIsSpeechRecognition() {
        #expect(PermissionIssue.speechRecognition.id == "speechRecognition")
    }

    @Test func microphone_titleContainsKeyword() {
        let title = PermissionIssue.microphone.title
        #expect(title.localizedCaseInsensitiveContains("microphone"))
    }

    @Test func speechRecognition_titleContainsKeyword() {
        let title = PermissionIssue.speechRecognition.title
        #expect(title.localizedCaseInsensitiveContains("speech"))
    }

    @Test func microphone_messageContainsKeyword() {
        let msg = PermissionIssue.microphone.message
        #expect(msg.localizedCaseInsensitiveContains("microphone"))
    }

    @Test func speechRecognition_messageContainsKeyword() {
        let msg = PermissionIssue.speechRecognition.message
        #expect(msg.localizedCaseInsensitiveContains("speech"))
    }

    @Test func allCasesAreIdentifiable() {
        // Each case must produce a unique, stable id
        #expect(PermissionIssue.microphone.id != PermissionIssue.speechRecognition.id)
    }
}

// MARK: - DisplayMode Tests

struct DisplayModeTests {

    @Test func normal_rawValue() {
        #expect(DisplayMode.normal.rawValue == "normal")
    }

    @Test func subtitle_rawValue() {
        #expect(DisplayMode.subtitle.rawValue == "subtitle")
    }

    @Test func allCases_containsBothModes() {
        let cases = DisplayMode.allCases
        #expect(cases.contains(.normal))
        #expect(cases.contains(.subtitle))
    }

    @Test func allCases_hasExactlyTwoElements() {
        #expect(DisplayMode.allCases.count == 2)
    }

    @Test func rawValueRoundTrip() {
        for mode in DisplayMode.allCases {
            let restored = DisplayMode(rawValue: mode.rawValue)
            #expect(restored == mode)
        }
    }
}

// MARK: - TranscriptEntry Combined Line Tests

/// Tests for the "combined finalized prefix + partial suffix" rendering path in
/// `TranscriptEntry.sourceTranscriptLines()`.
struct TranscriptEntryCombinedLineTests {

    @Test func combinedLine_singleLineReturned() {
        let entry = TranscriptEntry(
            source: TransString(text: "Good morning.", isPartial: false),
            pendingPartial: " How are"
        )
        let lines = entry.sourceTranscriptLines()
        #expect(lines.count == 1)
    }

    @Test func combinedLine_textIsConcatenation() {
        let entry = TranscriptEntry(
            source: TransString(text: "Good morning.", isPartial: false),
            pendingPartial: " How are"
        )
        let lines = entry.sourceTranscriptLines()
        #expect(lines[0].text == "Good morning. How are")
    }

    @Test func combinedLine_isMarkedPartial() {
        let entry = TranscriptEntry(
            source: TransString(text: "Good morning.", isPartial: false),
            pendingPartial: " How are"
        )
        #expect(entry.sourceTranscriptLines()[0].isPartial == true)
    }

    @Test func combinedLine_finalizedPrefixIsSourceText() {
        let entry = TranscriptEntry(
            source: TransString(text: "Good morning.", isPartial: false),
            pendingPartial: " How are"
        )
        #expect(entry.sourceTranscriptLines()[0].finalizedPrefix == "Good morning.")
    }

    @Test func combinedLine_idMatchesSourceId() {
        let sourceID = UUID()
        let entry = TranscriptEntry(
            source: TransString(id: sourceID, text: "Hello.", isPartial: false),
            pendingPartial: " World"
        )
        #expect(entry.sourceTranscriptLines()[0].id == sourceID)
    }

    @Test func purePartial_hasNilFinalizedPrefix() {
        // When source is empty and only pendingPartial exists, no finalizedPrefix should be set
        let entry = TranscriptEntry(pendingPartial: "typing...")
        let lines = entry.sourceTranscriptLines()
        #expect(lines.count == 1)
        #expect(lines[0].finalizedPrefix == nil)
    }

    @Test func emptyPendingPartialNotUsed() {
        // An empty pendingPartial should not trigger the combined path
        let entry = TranscriptEntry(
            source: TransString(text: "Hello.", isPartial: false),
            pendingPartial: ""
        )
        let lines = entry.sourceTranscriptLines()
        #expect(lines.count == 1)
        #expect(lines[0].text == "Hello.")
        #expect(lines[0].isPartial == false)
    }
}

// MARK: - TranslationSlot resetPartialState Tests

struct TranslationSlotResetPartialStateTests {

    @Test func resetPartialState_clearsPartialEntryID() {
        var slot = TranslationSlot()
        slot.partialEntryID = UUID()
        slot.resetPartialState()
        #expect(slot.partialEntryID == nil)
    }

    @Test func resetPartialState_clearsPendingPartialText() {
        var slot = TranslationSlot()
        slot.pendingPartialText = "some pending text"
        slot.resetPartialState()
        #expect(slot.pendingPartialText == nil)
    }

    @Test func resetPartialState_clearsPendingPartialElapsedTime() {
        var slot = TranslationSlot()
        slot.pendingPartialElapsedTime = 42.5
        slot.resetPartialState()
        #expect(slot.pendingPartialElapsedTime == nil)
    }

    @Test func resetPartialState_cancelsAndNilsTimer() {
        var slot = TranslationSlot()
        // Assign a long-running dummy task to simulate an active debounce timer
        slot.partialTranslationTimer = Task { try? await Task.sleep(for: .seconds(100)) }
        slot.resetPartialState()
        #expect(slot.partialTranslationTimer == nil)
    }

    @Test func resetPartialState_leavesQueueUntouched() {
        var slot = TranslationSlot()
        slot.queue.append(TranslationQueueItem(sentence: "test", entryID: UUID(), isPartial: false, elapsedTime: nil))
        slot.partialEntryID = UUID()
        slot.resetPartialState()
        // Only partial state is cleared — the translation queue must remain intact
        #expect(slot.queue.count == 1)
    }
}

// MARK: - URL(staticString:) Tests

struct URLStaticStringTests {

    @Test func validURL_absoluteStringMatches() {
        let url = URL(staticString: "https://example.com")
        #expect(url.absoluteString == "https://example.com")
    }

    @Test func validURL_withPath_componentsParsedCorrectly() {
        let url = URL(staticString: "https://api.example.com/v1/users")
        #expect(url.host == "api.example.com")
        #expect(url.path == "/v1/users")
    }

    @Test func validURL_schemeExtracted() {
        let url = URL(staticString: "https://example.com/path")
        #expect(url.scheme == "https")
    }
}
