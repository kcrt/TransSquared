import Foundation
import Translation
import os

private let logger = Logger.app("Translation")

// MARK: - Translation Processing

extension SessionViewModel {

    /// Called from the `.translationTask()` view modifier when a session is available for a given slot.
    func handleTranslationSession(_ session: TranslationSession, slot: Int) async {
        guard slot >= 0 && slot < translationSlots.count else { return }
        translationSlots[slot].isProcessing = true
        defer {
            if slot < translationSlots.count {
                translationSlots[slot].isProcessing = false
            }
        }
        logger.info("Translation session available for slot \(slot), queued: \(self.translationSlots[slot].queue.count)")

        // Process queued translations using the session provided by the closure.
        // Do NOT store the session — it is only valid within this closure scope.
        // Re-check bounds after each await since translationSlots may be rebuilt.
        while slot < translationSlots.count && !translationSlots[slot].queue.isEmpty {
            let item = translationSlots[slot].queue.removeFirst()
            await translateSentence(item.sentence, using: session, slot: slot, targetIndex: item.targetIndex, isPartial: item.isPartial)
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
        } catch is CancellationError {
            // Task was cancelled (e.g. session stopped) — not a real failure.
            logger.info("Slot \(slot) translation cancelled")
        } catch let error as NSError where error.domain.contains("Translation") || "\(error)".contains("alreadyCancelled") {
            // The translation session was invalidated/replaced while this request was in flight.
            // Primary match: NSError domain containing "Translation" (covers framework errors).
            // Fallback: string match for "alreadyCancelled" in case the error type changes.
            // Re-enqueue the item so the next session can pick it up.
            logger.info("Slot \(slot) translation session cancelled (domain: \(error.domain), code: \(error.code)), re-enqueueing")
            if slot < translationSlots.count {
                translationSlots[slot].queue.insert(
                    TranslationQueueItem(sentence: sentence, targetIndex: targetIndex, isPartial: isPartial), at: 0
                )
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
