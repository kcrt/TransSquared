//
//  SessionViewModelFileTranscriptionTests.swift
//  TransSquaredTests
//

import Foundation
import Testing
@testable import TransSquared

// MARK: - File Transcription State Tests

@MainActor
struct FileTranscriptionStateTests {

    @Test func requestFileTranscriptionBlockedDuringSession() {
        let vm = makeTestViewModel()
        vm.isSessionActive = true
        vm.requestFileTranscription(url: URL(fileURLWithPath: "/tmp/test.m4a"))
        #expect(vm.errorMessage != nil)
    }

    @Test func requestFileTranscriptionBlockedWhileTranscribing() {
        let vm = makeTestViewModel()
        vm.isTranscribingFile = true
        vm.requestFileTranscription(url: URL(fileURLWithPath: "/tmp/test.m4a"))
        #expect(vm.errorMessage != nil)
    }

    @Test func fileTranslationProgressZeroWhenNoSegments() {
        let vm = makeTestViewModel()
        vm.segmentIndex = 0
        #expect(vm.fileTranslationProgress(forSlot: 0) == 0)
    }

    @Test func fileTranslationProgressCalculation() {
        let vm = makeTestViewModel()
        vm.segmentIndex = 10
        vm.translationSlots = [TranslationSlot()]
        vm.translationSlots[0].queue = [
            TranslationQueueItem(sentence: "a", entryID: UUID(), isPartial: false, elapsedTime: nil),
            TranslationQueueItem(sentence: "b", entryID: UUID(), isPartial: false, elapsedTime: nil),
            TranslationQueueItem(sentence: "c", entryID: UUID(), isPartial: false, elapsedTime: nil),
        ]
        let progress = vm.fileTranslationProgress(forSlot: 0)
        #expect(progress == 0.7)
    }

    @Test func fileTranslationProgressIgnoresPartialItems() {
        let vm = makeTestViewModel()
        vm.segmentIndex = 5
        vm.translationSlots = [TranslationSlot()]
        vm.translationSlots[0].queue = [
            TranslationQueueItem(sentence: "a", entryID: UUID(), isPartial: true, elapsedTime: nil),
            TranslationQueueItem(sentence: "b", entryID: UUID(), isPartial: false, elapsedTime: nil),
        ]
        let progress = vm.fileTranslationProgress(forSlot: 0)
        #expect(progress == 0.8)
    }

    @Test func cancelFileTranscriptionClearsState() {
        let vm = makeTestViewModel()
        vm.isTranscribingFile = true
        vm.pendingSentenceBuffer = "leftover"
        vm.translationSlots = [TranslationSlot()]
        vm.translationSlots[0].queue.append(
            TranslationQueueItem(sentence: "q", entryID: UUID(), isPartial: false, elapsedTime: nil)
        )

        vm.cancelFileTranscription()

        #expect(vm.isTranscribingFile == false)
        #expect(vm.pendingSentenceBuffer == "")
        #expect(vm.translationSlots[0].queue.isEmpty)
    }
}

// MARK: - Audio File Transcription Tests

struct AudioFileTranscriptionTests {

    private func audioFileURL(_ name: String, ext: String) -> URL? {
        let bundle = Bundle(for: TestBundleAnchor.self)
        return bundle.url(forResource: name, withExtension: ext)
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "sounds")
    }

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
            // Expected
        }
    }
}
