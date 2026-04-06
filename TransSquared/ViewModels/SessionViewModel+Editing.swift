import Foundation
import Translation
import os

private let logger = Logger.app("Editing")

// MARK: - Inline Editing

extension SessionViewModel {

    /// Called when the user edits a source (transcription) line.
    /// Updates the source text and re-translates the corresponding sentence in all slots.
    func editSourceLine(id: UUID, newText: String) {
        // Find the entry matching this source ID
        guard let entryIdx = findSourceEntry(id: id) else { return }
        let oldText = entries[entryIdx].source.text
        guard newText != oldText else { return }

        entries[entryIdx].source.text = newText
        logger.info("Source line edited: \"\(oldText)\" → \"\(newText)\"")

        guard entries[entryIdx].isCommitted else {
            // Not committed yet; no re-translation possible.
            return
        }

        let entryID = entries[entryIdx].id
        for slot in 0..<targetCount {
            retranslateForSlot(slot, entryIndex: entryIdx, entryID: entryID, sentence: newText)
        }
    }

    /// Called when the user edits a translation line.
    /// Simply updates the text in-place; no re-translation is triggered.
    func editTranslationLine(slot: Int, id: UUID, newText: String) {
        guard let entryIdx = findTranslationEntry(slot: slot, translationID: id) else { return }
        guard let oldText = entries[entryIdx].translations[slot]?.text, newText != oldText else { return }

        entries[entryIdx].translations[slot]?.text = newText
        logger.info("Translation line edited (slot \(slot)): \"\(oldText)\" → \"\(newText)\"")
    }

    /// Re-translates a sentence in a specific slot by replacing the translation with a placeholder
    /// and enqueuing a new translation request.
    private func retranslateForSlot(_ slot: Int, entryIndex entryIdx: Int, entryID: UUID, sentence: String) {
        guard slot < translationSlots.count else { return }

        let elapsed = entries[entryIdx].elapsedTime

        // Replace translation with placeholder
        entries[entryIdx].translations[slot] = TransString(text: "…", isPartial: true)

        // Remove any existing queue items for this entry to avoid duplicates
        translationSlots[slot].queue.removeAll { $0.entryID == entryID }

        // Ensure translation session is available
        if translationSlots[slot].config == nil, slot < targetLanguageIdentifiers.count {
            let targetLang = Locale.Language(identifier: targetLanguageIdentifiers[slot])
            translationSlots[slot].config = TranslationSession.Configuration(
                source: sourceLocale.language,
                target: targetLang
            )
        }

        // Enqueue the re-translation
        enqueueTranslation(slot: slot, item: TranslationQueueItem(
            sentence: sentence, entryID: entryID,
            isPartial: false, elapsedTime: elapsed
        ))

        logger.debug("Re-translation queued for slot \(slot), entryID: \(entryID)")
    }

    // MARK: - Entry Lookup Helpers

    /// Finds the entry index whose source has the given ID.
    private func findSourceEntry(id: UUID) -> Int? {
        entries.firstIndex(where: { $0.source.id == id })
    }

    /// Finds the entry index containing a translation with the given ID in the specified slot.
    private func findTranslationEntry(slot: Int, translationID: UUID) -> Int? {
        entries.firstIndex(where: { $0.translations[slot]?.id == translationID })
    }
}
