import Foundation
import Translation
import os

private let logger = Logger.app("Translation")

// MARK: - Translation Processing

extension SessionViewModel {

    /// Called from the `.translationTask()` view modifier when a session is available for a given slot.
    func handleTranslationSession(_ session: TranslationSession, slot: Int) async {
        guard slot >= 0 && slot < translationSlots.count else { return }
        logger.info("Translation session available for slot \(slot), queued: \(self.translationSlots[slot].queue.count)")

        // Process queued translations using the session provided by the closure.
        // Do NOT store the session — it is only valid within this closure scope.
        // Re-check bounds after each await since translationSlots may be rebuilt.
        while slot < translationSlots.count && !translationSlots[slot].queue.isEmpty {
            let item = translationSlots[slot].queue.removeFirst()
            await translateSentence(item.sentence, using: session, slot: slot, targetIndex: item.targetIndex, isPartial: item.isPartial)
        }
    }

    // MARK: - Target Language Management

    func addTargetLanguage() {
        guard targetCount < Self.maxTargetCount else { return }
        targetCount += 1
        // Pick a default language not already selected
        let used = Set(targetLanguageIdentifiers.prefix(targetCount - 1))
        if let available = supportedTargetLanguages.first(where: { !used.contains($0.minimalIdentifier) }) {
            if targetLanguageIdentifiers.count < targetCount {
                targetLanguageIdentifiers.append(available.minimalIdentifier)
            } else {
                targetLanguageIdentifiers[targetCount - 1] = available.minimalIdentifier
            }
        }
    }

    func removeTargetLanguage() {
        guard targetCount > 1 else { return }
        targetCount -= 1
    }

    // MARK: - Transcription Event Handling

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

    // MARK: - Translation Queue

    func requestPartialTranslation(for text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        for slot in 0..<targetCount {
            requestPartialTranslationForSlot(slot, text: trimmed)
        }
    }

    private func requestPartialTranslationForSlot(_ slot: Int, text: String) {
        guard slot < translationSlots.count else { return }
        translationSlots[slot].partialTranslationTimer?.cancel()
        let capturedSlot = slot
        translationSlots[slot].partialTranslationTimer = Task {
            try? await Task.sleep(nanoseconds: Self.partialTranslationDebounce)
            guard !Task.isCancelled, capturedSlot < translationSlots.count else { return }

            let idx = translationSlots[capturedSlot].enqueueTranslation(sentence: text, isPartial: true)
            logger.debug("Queuing partial translation slot \(capturedSlot) (targetIndex: \(idx)): \"\(text)\"")
        }
    }

    func commitSentence(_ sentence: String) {
        guard !sentence.isEmpty else { return }

        segmentIndex += 1
        logger.info("Committing sentence #\(self.segmentIndex): \"\(sentence)\"")

        for slot in 0..<targetCount {
            commitSentenceForSlot(slot, sentence: sentence)
        }
    }

    private func commitSentenceForSlot(_ slot: Int, sentence: String) {
        guard slot < translationSlots.count else { return }
        translationSlots[slot].partialTranslationTimer?.cancel()
        translationSlots[slot].partialTranslationTimer = nil

        let idx = translationSlots[slot].enqueueTranslation(sentence: sentence, isPartial: false, resetPartialIndex: true)
        logger.debug("Queuing for translation (slot: \(slot), targetIndex: \(idx))")
    }

    private func translateSentence(_ sentence: String, using session: TranslationSession, slot: Int, targetIndex: Int, isPartial: Bool) async {
        logger.debug("Translating slot \(slot) (\(isPartial ? "partial" : "final")): \"\(sentence)\"")
        do {
            let response = try await session.translate(sentence)
            logger.info("Slot \(slot) translation result (\(isPartial ? "partial" : "final")): \"\(response.targetText)\"")
            // Re-check slot bounds after await since translationSlots may have been rebuilt
            guard slot < translationSlots.count,
                  targetIndex >= 0 && targetIndex < translationSlots[slot].lines.count else { return }
            // For partial translations, only update if the line is still partial
            // (a final translation may have already replaced it)
            if isPartial {
                if translationSlots[slot].lines[targetIndex].isPartial {
                    translationSlots[slot].lines[targetIndex] = TranscriptLine(text: response.targetText, isPartial: true)
                }
            } else {
                translationSlots[slot].lines[targetIndex] = TranscriptLine(text: response.targetText, isPartial: false, finalizedAt: Date())
            }
        } catch {
            logger.error("Slot \(slot) translation failed: \(error.localizedDescription)")
            // Only show error for final translations; silently ignore partial failures
            if !isPartial {
                if slot < translationSlots.count,
                   targetIndex >= 0 && targetIndex < translationSlots[slot].lines.count {
                    translationSlots[slot].lines[targetIndex] = TranscriptLine(text: "[Translation failed]", isPartial: false, finalizedAt: Date())
                }
            }
        }
    }
}
