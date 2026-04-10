//
//  SubtitleExportTests.swift
//  TransSquaredTests
//

import Foundation
import Testing
@testable import TransSquared

// MARK: - Subtitle Export Tests

@MainActor
struct SubtitleExportTests {

    // MARK: - Helpers

    private func entryWithTiming(
        text: String,
        start: TimeInterval,
        duration: TimeInterval
    ) -> TranscriptEntry {
        TranscriptEntry(
            source: TransString(text: text, isPartial: false),
            elapsedTime: start,
            duration: duration,
            isCommitted: true
        )
    }

    // MARK: SubtitleFormat metadata

    @Test func srt_fileExtension() {
        #expect(SessionViewModel.SubtitleFormat.srt.fileExtension == "srt")
    }

    @Test func vtt_fileExtension() {
        #expect(SessionViewModel.SubtitleFormat.vtt.fileExtension == "vtt")
    }

    // MARK: SRT structure

    @Test func srt_singleEntry_hasCorrectBlockStructure() {
        let vm = makeTestViewModel()
        vm.entries = [entryWithTiming(text: "Hello world", start: 0.0, duration: 2.5)]
        vm.exportSubtitle(format: .srt, contentType: .original)
        guard let content = vm.exportContent else {
            Issue.record("exportContent is nil")
            return
        }
        let lines = content.components(separatedBy: "\n")
        // Block: index / timestamp / text / blank
        #expect(lines[0] == "1")
        #expect(lines[1].contains("-->"))
        #expect(lines[2] == "Hello world")
    }

    @Test func srt_usesCommaAsMillisecondSeparator() {
        let vm = makeTestViewModel()
        vm.entries = [entryWithTiming(text: "Test", start: 0.0, duration: 1.0)]
        vm.exportSubtitle(format: .srt, contentType: .original)
        guard let content = vm.exportContent else {
            Issue.record("exportContent is nil")
            return
        }
        // SRT format: 00:00:00,000 --> 00:00:01,000
        let timestampLine = content.components(separatedBy: "\n")[1]
        #expect(timestampLine.contains(","))
        #expect(!timestampLine.contains("."))
    }

    // MARK: VTT structure

    @Test func vtt_startsWithWebVTTHeader() {
        let vm = makeTestViewModel()
        vm.entries = [entryWithTiming(text: "Hello world", start: 0.0, duration: 2.5)]
        vm.exportSubtitle(format: .vtt, contentType: .original)
        guard let content = vm.exportContent else {
            Issue.record("exportContent is nil")
            return
        }
        #expect(content.hasPrefix("WEBVTT"))
    }

    @Test func vtt_usesDotAsMillisecondSeparator() {
        let vm = makeTestViewModel()
        vm.entries = [entryWithTiming(text: "Test", start: 0.0, duration: 1.0)]
        vm.exportSubtitle(format: .vtt, contentType: .original)
        guard let content = vm.exportContent else {
            Issue.record("exportContent is nil")
            return
        }
        // The timestamp line uses "." (e.g. 00:00:00.000 --> 00:00:01.000)
        let lines = content.components(separatedBy: "\n")
        let timestampLine = lines.first(where: { $0.contains("-->") })
        #expect(timestampLine?.contains(".") == true)
        #expect(timestampLine?.contains(",") == false)
    }

    // MARK: Timestamp accuracy

    @Test func srt_timestampFormattedCorrectly() {
        let vm = makeTestViewModel()
        // Start at 65.5 s, duration 2.0 s → end at 67.5 s
        vm.entries = [entryWithTiming(text: "Timing test", start: 65.5, duration: 2.0)]
        vm.exportSubtitle(format: .srt, contentType: .original)
        guard let content = vm.exportContent else {
            Issue.record("exportContent is nil")
            return
        }
        // 65.5 s  = 00:01:05,500
        // 67.5 s  = 00:01:07,500
        #expect(content.contains("00:01:05,500"))
        #expect(content.contains("00:01:07,500"))
    }

    @Test func srt_durationDefaultsToThreeSecondsWhenNil() {
        let vm = makeTestViewModel()
        // Entry at 10.0 s with no duration → default 3 s → end 13.0 s
        var entry = TranscriptEntry(
            source: TransString(text: "No duration", isPartial: false),
            elapsedTime: 10.0,
            isCommitted: true
        )
        vm.entries = [entry]
        vm.exportSubtitle(format: .srt, contentType: .original)
        guard let content = vm.exportContent else {
            Issue.record("exportContent is nil")
            return
        }
        #expect(content.contains("00:00:10,000"))
        #expect(content.contains("00:00:13,000"))
    }

    @Test func srt_hoursColumnHandledCorrectly() {
        let vm = makeTestViewModel()
        // Start at 3670.0 s (1h 1m 10s), duration 5.0 s
        vm.entries = [entryWithTiming(text: "Late entry", start: 3670.0, duration: 5.0)]
        vm.exportSubtitle(format: .srt, contentType: .original)
        guard let content = vm.exportContent else {
            Issue.record("exportContent is nil")
            return
        }
        #expect(content.contains("01:01:10,000"))
        #expect(content.contains("01:01:15,000"))
    }

    // MARK: Multiple entries

    @Test func srt_multipleEntries_sequentialIndexes() {
        let vm = makeTestViewModel()
        vm.entries = [
            entryWithTiming(text: "First", start: 0.0, duration: 2.0),
            entryWithTiming(text: "Second", start: 3.0, duration: 2.0),
            entryWithTiming(text: "Third", start: 6.0, duration: 2.0),
        ]
        vm.exportSubtitle(format: .srt, contentType: .original)
        guard let content = vm.exportContent else {
            Issue.record("exportContent is nil")
            return
        }
        let lines = content.components(separatedBy: "\n")
        #expect(lines.contains("1"))
        #expect(lines.contains("2"))
        #expect(lines.contains("3"))
        #expect(lines.contains("First"))
        #expect(lines.contains("Second"))
        #expect(lines.contains("Third"))
    }

    // MARK: Empty / missing data

    @Test func emptyEntries_producesNoExport() {
        let vm = makeTestViewModel()
        vm.entries = []
        vm.exportSubtitle(format: .srt, contentType: .original)
        #expect(vm.exportContent == nil)
        #expect(vm.isExporterPresented == false)
    }

    @Test func entriesWithoutElapsedTime_areExcluded() {
        let vm = makeTestViewModel()
        // Entry with no elapsedTime → subtitleCues returns nil → no content
        vm.entries = [TranscriptEntry(
            source: TransString(text: "No timing", isPartial: false),
            isCommitted: true
        )]
        vm.exportSubtitle(format: .srt, contentType: .original)
        #expect(vm.exportContent == nil)
        #expect(vm.isExporterPresented == false)
    }

    @Test func separatorEntries_areExcluded() {
        let vm = makeTestViewModel()
        vm.entries = [TranscriptEntry(isSeparator: true)]
        vm.exportSubtitle(format: .srt, contentType: .original)
        #expect(vm.exportContent == nil)
    }

    // MARK: Content type — translation

    @Test func translationContent_excludesEntriesWithoutTranslation() {
        let vm = makeTestViewModel()
        // Entry has no translation → translation subtitle should be empty
        vm.entries = [entryWithTiming(text: "こんにちは", start: 0.0, duration: 2.0)]
        vm.exportSubtitle(format: .srt, contentType: .translation)
        #expect(vm.exportContent == nil)
    }

    @Test func translationContent_includesTranslatedText() {
        let vm = makeTestViewModel()
        var entry = entryWithTiming(text: "こんにちは", start: 0.0, duration: 2.0)
        entry.translations[0] = TransString(text: "Hello", isPartial: false)
        vm.entries = [entry]
        vm.exportSubtitle(format: .srt, contentType: .translation)
        guard let content = vm.exportContent else {
            Issue.record("exportContent is nil")
            return
        }
        #expect(content.contains("Hello"))
        #expect(!content.contains("こんにちは"))
    }

    @Test func translationContent_partialTranslation_isExcluded() {
        let vm = makeTestViewModel()
        var entry = entryWithTiming(text: "Hello", start: 0.0, duration: 2.0)
        entry.translations[0] = TransString(text: "…", isPartial: true)   // placeholder
        vm.entries = [entry]
        vm.exportSubtitle(format: .srt, contentType: .translation)
        // Partial translation → no finalized text → no cue generated
        #expect(vm.exportContent == nil)
    }

    // MARK: Content type — both (bilingual)

    @Test func bilingualContent_includesBothSourceAndTranslation() {
        let vm = makeTestViewModel()
        var entry = entryWithTiming(text: "こんにちは", start: 0.0, duration: 2.0)
        entry.translations[0] = TransString(text: "Hello", isPartial: false)
        vm.entries = [entry]
        vm.exportSubtitle(format: .vtt, contentType: .both)
        guard let content = vm.exportContent else {
            Issue.record("exportContent is nil")
            return
        }
        #expect(content.contains("こんにちは"))
        #expect(content.contains("Hello"))
    }

    // MARK: isExporterPresented flag

    @Test func exportSubtitle_withContent_setsIsExporterPresented() {
        let vm = makeTestViewModel()
        vm.entries = [entryWithTiming(text: "Hello", start: 0.0, duration: 2.0)]
        vm.exportSubtitle(format: .srt, contentType: .original)
        #expect(vm.isExporterPresented == true)
    }
}
