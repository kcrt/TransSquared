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
            // Remove old partial line and add new one, preserving original elapsed time
            if let lastIndex = sourceLines.indices.last, sourceLines[lastIndex].isPartial {
                let originalElapsed = sourceLines[lastIndex].elapsedTime
                sourceLines[lastIndex] = TranscriptLine(text: text, isPartial: true, elapsedTime: originalElapsed)
            } else {
                sourceLines.append(TranscriptLine(text: text, isPartial: true, elapsedTime: currentElapsedTime))
            }

            // Request partial translation (debounced)
            requestPartialTranslation(for: pendingSentenceBuffer + text)

        case .finalized(let rawText):
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
            sourceLines.append(TranscriptLine(text: text, isPartial: false, elapsedTime: currentElapsedTime))

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
                try? await Task.sleep(for: Self.sentenceBoundaryTimeout)
            }
            guard !Task.isCancelled, !pendingSentenceBuffer.isEmpty else { return }
            let sentence = pendingSentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingSentenceBuffer = ""
            commitSentence(sentence)
        }
    }
}
