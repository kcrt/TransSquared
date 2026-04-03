import Foundation
import Translation
import os

private let logger = Logger.app("Editing")

// MARK: - Inline Editing

extension SessionViewModel {

    /// Called when the user edits a source (transcription) line.
    /// Updates the line text and re-translates the corresponding sentence in all slots.
    func editSourceLine(id: UUID, newText: String) {
        guard let lineIndex = sourceLines.firstIndex(where: { $0.id == id }) else { return }
        let oldText = sourceLines[lineIndex].text
        guard newText != oldText else { return }

        sourceLines[lineIndex].text = newText
        logger.info("Source line edited: \"\(oldText)\" → \"\(newText)\"")

        guard let sentenceID = sourceLines[lineIndex].sentenceID else {
            // No sentenceID means this line hasn't been committed yet; no re-translation possible.
            return
        }

        // Reconstruct the full sentence from all source lines with this sentenceID
        let sentenceLines = sourceLines.filter { $0.sentenceID == sentenceID }
        let reconstructedSentence = sentenceLines.map(\.text).joined()

        for slot in 0..<targetCount {
            retranslateForSlot(slot, sentenceID: sentenceID, sentence: reconstructedSentence)
        }
    }

    /// Called when the user edits a translation line.
    /// Simply updates the text in-place; no re-translation is triggered.
    func editTranslationLine(slot: Int, id: UUID, newText: String) {
        guard slot < translationSlots.count else { return }
        guard let lineIndex = translationSlots[slot].lines.firstIndex(where: { $0.id == id }) else { return }
        let oldText = translationSlots[slot].lines[lineIndex].text
        guard newText != oldText else { return }

        translationSlots[slot].lines[lineIndex].text = newText
        logger.info("Translation line edited (slot \(slot)): \"\(oldText)\" → \"\(newText)\"")
    }

    /// Re-translates a sentence in a specific slot by finding the translation line
    /// with the matching sentenceID and enqueuing a new translation.
    private func retranslateForSlot(_ slot: Int, sentenceID: UUID, sentence: String) {
        guard slot < translationSlots.count else { return }

        guard let targetIndex = translationSlots[slot].lines.firstIndex(where: { $0.sentenceID == sentenceID }) else {
            logger.debug("No translation line found for sentenceID in slot \(slot)")
            return
        }

        let elapsed = translationSlots[slot].lines[targetIndex].elapsedTime

        // Replace line with placeholder
        translationSlots[slot].lines[targetIndex] = TranscriptLine(
            text: "…", isPartial: true, elapsedTime: elapsed, sentenceID: sentenceID
        )

        // Remove any existing queue items for this targetIndex to avoid duplicates
        translationSlots[slot].queue.removeAll { $0.targetIndex == targetIndex }

        // Enqueue the re-translation
        translationSlots[slot].queue.append(
            TranslationQueueItem(
                sentence: sentence, targetIndex: targetIndex,
                isPartial: false, elapsedTime: elapsed, sentenceID: sentenceID
            )
        )

        // Ensure translation session is available
        if translationSlots[slot].config == nil {
            let targetLang = Locale.Language(identifier: targetLanguageIdentifiers[slot])
            translationSlots[slot].config = TranslationSession.Configuration(
                source: sourceLocale.language,
                target: targetLang
            )
        } else if !translationSlots[slot].isProcessing {
            translationSlots[slot].config?.invalidate()
        }

        logger.debug("Re-translation queued for slot \(slot), targetIndex: \(targetIndex)")
    }
}
