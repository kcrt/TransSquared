import Foundation
import os

private let logger = Logger.app("Transcription")

// MARK: - Transcription Event Handling

extension SessionViewModel {

    func handleTranscriptionEvent(_ event: TranscriptionEvent) {
        switch event {
        case .partial(let rawText, let duration, let audioOffset):
            let text = applyAutoReplacements(rawText)
            logger.debug("Event: partial \"\(rawText, privacy: .private)\" → \"\(text, privacy: .private)\"")

            let idx = ensureCurrentEntry()
            entries[idx].pendingPartial = text
            entries[idx].duration = duration
            // For file transcription, use the audio offset as the elapsed time
            if isTranscribingFile, let audioOffset {
                entries[idx].elapsedTime = audioOffset
            }

            // Request partial translation (debounced)
            requestPartialTranslation(for: pendingSentenceBuffer + text)

        case .finalized(let rawText, let duration, let audioOffset):
            let text = applyAutoReplacements(rawText)
            logger.debug("Event: final \"\(rawText, privacy: .private)\" → \"\(text, privacy: .private)\"")

            // Cancel any pending partial translation timers
            for slot in 0..<translationSlots.count {
                translationSlots[slot].partialTranslationTimer?.cancel()
                translationSlots[slot].partialTranslationTimer = nil
            }

            let idx = ensureCurrentEntry()

            // Clear partial and append finalized text to source
            entries[idx].pendingPartial = nil
            entries[idx].source.text += text
            // For file transcription, use the audio offset from the Speech framework.
            // For live transcription, use the wall-clock elapsed time.
            if isTranscribingFile, let audioOffset {
                entries[idx].elapsedTime = audioOffset
            } else if entries[idx].elapsedTime == nil {
                entries[idx].elapsedTime = currentElapsedTime
            }
            entries[idx].duration = duration

            // Add to sentence buffer and check for boundaries
            pendingSentenceBuffer += text
            checkSentenceBoundary()

        case .error(let message):
            logger.error("Event: error \"\(message)\"")
            errorMessage = message
        }
    }

    // MARK: - Sentence Boundary Detection

    func checkSentenceBoundary() {
        // Check if the buffer ends with sentence-ending punctuation
        if let lastChar = pendingSentenceBuffer.last, Self.sentenceEndChars.contains(lastChar) {
            let sentence = pendingSentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingSentenceBuffer = ""
            commitSentence(sentence)
        } else {
            // Reset the silence timer
            resetSentenceBoundaryTimer()
        }
    }

    func resetSentenceBoundaryTimer() {
        sentenceBoundaryGeneration &+= 1

        // If a timer task is already running, it will detect the new generation and
        // re-wait, avoiding Task creation churn on every finalized chunk.
        guard sentenceBoundaryTimer == nil else { return }

        sentenceBoundaryTimer = Task {
            defer { sentenceBoundaryTimer = nil }
            var lastGen: UInt64 = 0
            while !Task.isCancelled {
                let currentGen = sentenceBoundaryGeneration
                if currentGen == lastGen { break }
                lastGen = currentGen
                try? await Task.sleep(for: sentenceBoundaryTimeout)
            }
            guard !Task.isCancelled, !pendingSentenceBuffer.isEmpty else { return }
            let sentence = pendingSentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingSentenceBuffer = ""
            commitSentence(sentence)
        }
    }
}
