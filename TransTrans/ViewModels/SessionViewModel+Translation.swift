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
        translationSlots[slot].pendingPartialText = text
        translationSlots[slot].partialDebounceGeneration &+= 1

        // If a debounce task is already running, it will detect the new generation and re-wait.
        // This avoids creating and cancelling a new Task on every partial event (~10+/sec).
        guard translationSlots[slot].partialTranslationTimer == nil else { return }

        let capturedSlot = slot
        translationSlots[slot].partialTranslationTimer = Task {
            defer {
                if capturedSlot < translationSlots.count {
                    translationSlots[capturedSlot].partialTranslationTimer = nil
                }
            }
            var lastGen: UInt64 = 0
            while !Task.isCancelled, capturedSlot < translationSlots.count {
                let currentGen = translationSlots[capturedSlot].partialDebounceGeneration
                if currentGen == lastGen { break }
                lastGen = currentGen
                try? await Task.sleep(for: Self.partialTranslationDebounce)
            }
            guard !Task.isCancelled, capturedSlot < translationSlots.count,
                  let text = translationSlots[capturedSlot].pendingPartialText else { return }
            translationSlots[capturedSlot].pendingPartialText = nil

            let idx = translationSlots[capturedSlot].enqueueTranslation(sentence: text, isPartial: true, elapsedTime: currentElapsedTime)
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
        translationSlots[slot].pendingPartialText = nil

        let idx = translationSlots[slot].enqueueTranslation(sentence: sentence, isPartial: false, resetPartialIndex: true, elapsedTime: currentElapsedTime)
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
            let elapsed = translationSlots[slot].lines[targetIndex].elapsedTime
            if isPartial {
                if translationSlots[slot].lines[targetIndex].isPartial {
                    translationSlots[slot].lines[targetIndex] = TranscriptLine(text: response.targetText, isPartial: true, elapsedTime: elapsed)
                }
            } else {
                translationSlots[slot].lines[targetIndex] = TranscriptLine(text: response.targetText, isPartial: false, finalizedAt: Date(), elapsedTime: elapsed)
            }
        } catch is CancellationError {
            // Task was cancelled (e.g. session stopped) — not a real failure.
            logger.info("Slot \(slot) translation cancelled")
        } catch where Self.isTranslationSessionCancellation(error) {
            // The translation session was invalidated/replaced while this request was in flight.
            // Re-enqueue the item so the next session can pick it up.
            let nsError = error as NSError
            logger.info("Slot \(slot) translation session cancelled (domain: \(nsError.domain), code: \(nsError.code)), re-enqueueing")
            if slot < translationSlots.count {
                let elapsed = targetIndex >= 0 && targetIndex < translationSlots[slot].lines.count
                    ? translationSlots[slot].lines[targetIndex].elapsedTime : nil
                translationSlots[slot].queue.insert(
                    TranslationQueueItem(sentence: sentence, targetIndex: targetIndex, isPartial: isPartial, elapsedTime: elapsed), at: 0
                )
            }
        } catch {
            logger.error("Slot \(slot) translation failed: \(error.localizedDescription)")
            // Only show error for final translations; silently ignore partial failures
            if !isPartial {
                if slot < translationSlots.count,
                   targetIndex >= 0 && targetIndex < translationSlots[slot].lines.count {
                    let elapsed = translationSlots[slot].lines[targetIndex].elapsedTime
                    translationSlots[slot].lines[targetIndex] = TranscriptLine(text: "[Translation failed]", isPartial: false, finalizedAt: Date(), elapsedTime: elapsed)
                }
            }
        }
    }

    /// Determines whether an error represents a Translation framework session cancellation.
    /// These errors occur when `TranslationSession.Configuration.invalidate()` is called
    /// while a translation request is in flight.
    private static func isTranslationSessionCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain.contains("Translation")
    }
}
