//
//  SessionViewModelExportTests.swift
//  TransSquaredTests
//

import Foundation
import Testing
@testable import TransSquared

// MARK: - Export Tests

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
            TranscriptEntry(),
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

// MARK: - Subtitle Export Tests

@MainActor
struct SubtitleExportTests {

    @Test func srtExportOriginalFormat() {
        let vm = makeTestViewModel()
        vm.targetCount = 1
        vm.translationSlots = [TranslationSlot()]
        vm.entries = [
            TranscriptEntry(
                source: TransString(text: "Hello world.", isPartial: false),
                elapsedTime: 1.5,
                duration: 2.0,
                isCommitted: true
            ),
            TranscriptEntry(
                source: TransString(text: "Goodbye.", isPartial: false),
                elapsedTime: 5.0,
                duration: 1.5,
                isCommitted: true
            ),
        ]

        vm.exportSubtitle(format: .srt, contentType: .original)
        let content = vm.exportContent ?? ""

        #expect(content.contains("1\n00:00:01,500 --> 00:00:03,500\nHello world."))
        #expect(content.contains("2\n00:00:05,000 --> 00:00:06,500\nGoodbye."))
    }

    @Test func vttExportOriginalFormat() {
        let vm = makeTestViewModel()
        vm.targetCount = 1
        vm.translationSlots = [TranslationSlot()]
        vm.entries = [
            TranscriptEntry(
                source: TransString(text: "Hello world.", isPartial: false),
                elapsedTime: 0.0,
                duration: 2.0,
                isCommitted: true
            ),
        ]

        vm.exportSubtitle(format: .vtt, contentType: .original)
        let content = vm.exportContent ?? ""

        #expect(content.hasPrefix("WEBVTT"))
        #expect(content.contains("00:00:00.000 --> 00:00:02.000"))
    }

    @Test func srtExportTranslation() {
        let vm = makeTestViewModel()
        vm.targetCount = 1
        vm.translationSlots = [TranslationSlot()]
        var entry = TranscriptEntry(
            source: TransString(text: "Hello.", isPartial: false),
            elapsedTime: 0.0,
            duration: 1.0,
            isCommitted: true
        )
        entry.translations[0] = TransString(text: "こんにちは。", isPartial: false, finalizedAt: Date())
        vm.entries = [entry]

        vm.exportSubtitle(format: .srt, contentType: .translation)
        let content = vm.exportContent ?? ""

        #expect(content.contains("こんにちは。"))
        #expect(!content.contains("Hello."))
    }

    @Test func srtExportBilingual() {
        let vm = makeTestViewModel()
        vm.targetCount = 1
        vm.translationSlots = [TranslationSlot()]
        var entry = TranscriptEntry(
            source: TransString(text: "Hello.", isPartial: false),
            elapsedTime: 0.0,
            duration: 1.0,
            isCommitted: true
        )
        entry.translations[0] = TransString(text: "こんにちは。", isPartial: false, finalizedAt: Date())
        vm.entries = [entry]

        vm.exportSubtitle(format: .srt, contentType: .both)
        let content = vm.exportContent ?? ""

        #expect(content.contains("Hello.\nこんにちは。"))
    }

    @Test func subtitleExportSkipsEntriesWithoutTiming() {
        let vm = makeTestViewModel()
        vm.targetCount = 1
        vm.translationSlots = [TranslationSlot()]
        vm.entries = [
            TranscriptEntry(
                source: TransString(text: "No timing", isPartial: false),
                isCommitted: true
            ),
        ]

        vm.exportSubtitle(format: .srt, contentType: .original)
        #expect(vm.exportContent == nil)
        #expect(vm.isExporterPresented == false)
    }

    @Test func subtitleExportDefaultDurationWhenMissing() {
        let vm = makeTestViewModel()
        vm.targetCount = 1
        vm.translationSlots = [TranslationSlot()]
        vm.entries = [
            TranscriptEntry(
                source: TransString(text: "Test.", isPartial: false),
                elapsedTime: 0.0,
                duration: nil,
                isCommitted: true
            ),
        ]

        vm.exportSubtitle(format: .srt, contentType: .original)
        let content = vm.exportContent ?? ""

        #expect(content.contains("00:00:00,000 --> 00:00:03,000"))
    }

    @Test func subtitleFormatExtensions() {
        #expect(SessionViewModel.SubtitleFormat.srt.fileExtension == "srt")
        #expect(SessionViewModel.SubtitleFormat.vtt.fileExtension == "vtt")
    }
}

// MARK: - Export Edge Case Tests

@MainActor
struct ExportEdgeCaseTests {

    @Test func saveTranscriptOriginalSetsExportState() {
        let vm = makeTestViewModel()
        vm.entries = [
            TranscriptEntry(source: TransString(text: "Hello", isPartial: false))
        ]

        vm.saveTranscript(contentType: .original)

        #expect(vm.isExporterPresented == true)
        #expect(vm.exportContent == "Hello")
        #expect(vm.exportDefaultFilename.contains("original"))
        #expect(vm.exportDefaultFilename.hasSuffix(".txt"))
    }

    @Test func saveTranscriptEmptyContentDoesNotPresent() {
        let vm = makeTestViewModel()
        vm.entries = []

        vm.saveTranscript(contentType: .original)

        #expect(vm.isExporterPresented == false)
        #expect(vm.exportContent == nil)
    }

    @Test func copyAllTranslationEmptySlots() {
        let vm = makeTestViewModel()
        vm.targetCount = 1
        vm.translationSlots = [TranslationSlot()]
        vm.entries = [
            TranscriptEntry(source: TransString(text: "Hello", isPartial: false), isCommitted: true)
        ]
        #expect(vm.copyAllTranslation() == "")
    }

    @Test func copyAllInterleavedSkipsSeparators() {
        let vm = makeTestViewModel()
        vm.translationSlots = [TranslationSlot()]
        vm.entries = [
            TranscriptEntry(source: TransString(text: "A", isPartial: false), isCommitted: true),
            TranscriptEntry(isSeparator: true),
            TranscriptEntry(source: TransString(text: "B", isPartial: false), isCommitted: true),
        ]
        let result = vm.copyAllInterleaved()
        #expect(!result.contains("separator"))
        #expect(result.contains("A"))
        #expect(result.contains("B"))
    }

    @Test func copyAllInterleavedMultiSlot() {
        let vm = makeTestViewModel()
        vm.targetCount = 2
        vm.translationSlots = [TranslationSlot(), TranslationSlot()]
        var entry = TranscriptEntry(
            source: TransString(text: "Source", isPartial: false),
            isCommitted: true
        )
        entry.translations[0] = TransString(text: "Trans0", isPartial: false)
        entry.translations[1] = TransString(text: "Trans1", isPartial: false)
        vm.entries = [entry]

        let result = vm.copyAllInterleaved()
        let lines = result.components(separatedBy: "\n")
        #expect(lines.contains("Source"))
        #expect(lines.contains("Trans0"))
        #expect(lines.contains("Trans1"))
    }
}
