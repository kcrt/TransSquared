import Foundation
import os

private let logger = Logger.app("Transcription")

// MARK: - Transcription Event Handling

extension SessionViewModel {

    func handleTranscriptionEvent(_ event: TranscriptionEvent) {
        switch event {
        case .partial(let rawText):
            let text = applyAutoReplacements(rawText)
            logger.debug("Event: partial \"\(rawText)\" → \"\(text)\"")
            // Remove old partial line and add new one
            if let lastIndex = sourceLines.indices.last, sourceLines[lastIndex].isPartial {
                sourceLines[lastIndex] = TranscriptLine(text: text, isPartial: true)
            } else {
                sourceLines.append(TranscriptLine(text: text, isPartial: true))
            }

            // Request partial translation (debounced)
            requestPartialTranslation(for: pendingSentenceBuffer + text)

        case .final_(let rawText):
            let text = applyAutoReplacements(rawText)
            logger.info("Event: final \"\(rawText)\" → \"\(text)\"")
            // Cancel any pending partial translation timers
            for slot in 0..<translationSlots.count {
                translationSlots[slot].partialTranslationTimer?.cancel()
                translationSlots[slot].partialTranslationTimer = nil
            }

            // Remove partial line if present
            if let lastIndex = sourceLines.indices.last, sourceLines[lastIndex].isPartial {
                sourceLines.removeLast()
            }

            // Append finalized text
            sourceLines.append(TranscriptLine(text: text, isPartial: false))

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
        sentenceBoundaryTimer?.cancel()
        sentenceBoundaryTimer = Task {
            try? await Task.sleep(nanoseconds: Self.sentenceBoundaryTimeout)
            guard !Task.isCancelled else { return }
            if !pendingSentenceBuffer.isEmpty {
                let sentence = pendingSentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                pendingSentenceBuffer = ""
                commitSentence(sentence)
            }
        }
    }
}
