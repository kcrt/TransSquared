import Foundation
import Translation
import os

private let logger = Logger.app("FileTranscription")

// MARK: - Audio File Transcription

extension SessionViewModel {

    /// Checks for existing transcript content and either shows a confirmation dialog or starts transcription directly.
    func requestFileTranscription(url: URL) {
        guard !isSessionActive, !isTranscribingFile else {
            errorMessage = String(
                localized: "Cannot transcribe a file while a session is active.",
                comment: "Error shown when user tries to transcribe a file during an active recording session"
            )
            return
        }

        if hasTranscriptContent {
            pendingFileTranscriptionURL = url
            showFileTranscriptionConfirmation = true
        } else {
            transcribeAudioFile(url: url)
        }
    }

    /// Confirms and starts file transcription, clearing existing data first.
    func confirmFileTranscription() {
        guard let url = pendingFileTranscriptionURL else { return }
        pendingFileTranscriptionURL = nil

        // Clear existing transcript data
        entries.removeAll()
        for slot in 0..<translationSlots.count {
            translationSlots[slot].queue.removeAll()
        }
        segmentIndex = 0
        accumulatedElapsedTime = 0

        transcribeAudioFile(url: url)
    }

    /// Transcribes an audio file and feeds results into the existing transcript/translation pipeline.
    private func transcribeAudioFile(url: URL) {
        logger.info("Starting file transcription: \(url.lastPathComponent)")

        isTranscribingFile = true
        fileTranscriptionProgress = 0
        fileAudioDuration = 0

        pendingSentenceBuffer = ""
        segmentIndex = 0
        accumulatedElapsedTime = 0
        sessionStartDate = Date()

        // Set up translation slots so committed sentences get translated.
        let slotCount = targetCount
        translationSlots = (0..<slotCount).map { i in
            var slot = TranslationSlot()
            let targetLang = Locale.Language(identifier: targetLanguageIdentifiers[i])
            slot.config = TranslationSession.Configuration(
                source: sourceLocale.language,
                target: targetLang
            )
            return slot
        }

        let transcriber = AudioFileTranscriber()
        audioFileTranscriber = transcriber

        fileTranscriptionTask = Task {
            // Obtain access to the security-scoped resource from the file picker.
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess { url.stopAccessingSecurityScopedResource() }
                if let start = sessionStartDate {
                    accumulatedElapsedTime += Date().timeIntervalSince(start)
                }
                sessionStartDate = nil
                isTranscribingFile = false
                audioFileTranscriber = nil
                fileTranscriptionTask = nil
            }

            do {
                let (stream, duration) = try await transcriber.transcribe(
                    fileURL: url,
                    locale: sourceLocale,
                    contextualStrings: currentContextualStrings,
                    onProgress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.fileTranscriptionProgress = progress
                        }
                    }
                )
                fileAudioDuration = duration

                for await event in stream {
                    guard !Task.isCancelled else { break }
                    handleTranscriptionEvent(event)
                }

                // Flush any remaining text in the buffer.
                if !pendingSentenceBuffer.isEmpty {
                    let sentence = pendingSentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    pendingSentenceBuffer = ""
                    if !sentence.isEmpty {
                        commitSentence(sentence)
                    }
                }

                fileTranscriptionProgress = 1.0

                // Wait for translation queues to drain before dismissing.
                let slotCount = targetCount
                while !Task.isCancelled {
                    let allDone = (0..<slotCount).allSatisfy { slot in
                        guard slot < self.translationSlots.count else { return true }
                        return self.translationSlots[slot].queue.filter({ !$0.isPartial }).isEmpty
                    }
                    if allDone { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }

                logger.info("File transcription completed")
            } catch {
                if !Task.isCancelled {
                    logger.error("File transcription failed: \(error.localizedDescription)")
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Translation progress (0.0–1.0) for a given slot during file transcription.
    func fileTranslationProgress(forSlot slot: Int) -> Double {
        guard segmentIndex > 0, slot < translationSlots.count else { return 0 }
        let pendingFinal = translationSlots[slot].queue.filter { !$0.isPartial }.count
        let completed = max(0, segmentIndex - pendingFinal)
        return Double(completed) / Double(segmentIndex)
    }

    /// Cancels any in-progress file transcription.
    func cancelFileTranscription() {
        guard isTranscribingFile else { return }
        logger.info("Cancelling file transcription")
        fileTranscriptionTask?.cancel()
        fileTranscriptionTask = nil
        Task {
            await audioFileTranscriber?.cancel()
            audioFileTranscriber = nil
        }
        // Discard pending translations so they don't keep running after cancel.
        for slot in 0..<translationSlots.count {
            translationSlots[slot].queue.removeAll()
        }
        pendingSentenceBuffer = ""
        isTranscribingFile = false
    }
}
