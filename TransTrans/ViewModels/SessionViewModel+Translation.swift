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

        // Use the elapsed time from the current partial source line
        let sourceElapsedTime = sourceLines.last?.elapsedTime

        for slot in 0..<targetCount {
            requestPartialTranslationForSlot(slot, text: trimmed, elapsedTime: sourceElapsedTime)
        }
    }

    private func requestPartialTranslationForSlot(_ slot: Int, text: String, elapsedTime: TimeInterval?) {
        guard slot < translationSlots.count else { return }
        translationSlots[slot].pendingPartialText = text
        translationSlots[slot].pendingPartialElapsedTime = elapsedTime
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
            let elapsed = translationSlots[capturedSlot].pendingPartialElapsedTime
            translationSlots[capturedSlot].pendingPartialText = nil
            translationSlots[capturedSlot].pendingPartialElapsedTime = nil

            let idx = translationSlots[capturedSlot].enqueueTranslation(sentence: text, isPartial: true, elapsedTime: elapsed)
            logger.debug("Queuing partial translation slot \(capturedSlot) (targetIndex: \(idx)): \"\(text, privacy: .private)\"")
        }
    }

    func commitSentence(_ sentence: String) {
        guard !sentence.isEmpty else { return }

        segmentIndex += 1
        let sid = UUID()

        // Use the elapsed time from the first source line in this sentence group
        // so the translation timestamp matches the transcription timestamp.
        let sourceElapsedTime = uncommittedSourceLineIndices.first.flatMap { idx in
            idx < sourceLines.count ? sourceLines[idx].elapsedTime : nil
        }

        // Tag all accumulated source lines with this sentenceID
        for idx in uncommittedSourceLineIndices {
            if idx < sourceLines.count {
                sourceLines[idx].sentenceID = sid
            }
        }
        uncommittedSourceLineIndices = []

        logger.debug("Committing sentence #\(self.segmentIndex): \"\(sentence, privacy: .private)\"")

        for slot in 0..<targetCount {
            commitSentenceForSlot(slot, sentence: sentence, sentenceID: sid, elapsedTime: sourceElapsedTime)
        }
    }

    private func commitSentenceForSlot(_ slot: Int, sentence: String, sentenceID: UUID, elapsedTime: TimeInterval?) {
        guard slot < translationSlots.count else { return }
        translationSlots[slot].partialTranslationTimer?.cancel()
        translationSlots[slot].partialTranslationTimer = nil
        translationSlots[slot].pendingPartialText = nil
        translationSlots[slot].pendingPartialElapsedTime = nil

        let idx = translationSlots[slot].enqueueTranslation(sentence: sentence, isPartial: false, resetPartialIndex: true, elapsedTime: elapsedTime, sentenceID: sentenceID)
        logger.debug("Queuing for translation (slot: \(slot), targetIndex: \(idx))")
    }

    private func translateSentence(_ sentence: String, using session: TranslationSession, slot: Int, targetIndex: Int, isPartial: Bool) async {
        logger.debug("Translating slot \(slot) (\(isPartial ? "partial" : "final")): \"\(sentence, privacy: .private)\"")
        do {
            let response = try await session.translate(sentence)
            logger.debug("Slot \(slot) translation result (\(isPartial ? "partial" : "final")): \"\(response.targetText, privacy: .private)\"")
            // Re-check slot bounds after await since translationSlots may have been rebuilt
            guard slot < translationSlots.count,
                  targetIndex >= 0 && targetIndex < translationSlots[slot].lines.count else { return }
            // For partial translations, only update if the line is still partial
            // (a final translation may have already replaced it)
            let existingLine = translationSlots[slot].lines[targetIndex]
            let elapsed = existingLine.elapsedTime
            let sid = existingLine.sentenceID
            if isPartial {
                if existingLine.isPartial {
                    translationSlots[slot].lines[targetIndex] = TranscriptLine(text: response.targetText, isPartial: true, elapsedTime: elapsed, sentenceID: sid)
                }
            } else {
                translationSlots[slot].lines[targetIndex] = TranscriptLine(text: response.targetText, isPartial: false, finalizedAt: Date(), elapsedTime: elapsed, sentenceID: sid)
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
                let existingLine = targetIndex >= 0 && targetIndex < translationSlots[slot].lines.count
                    ? translationSlots[slot].lines[targetIndex] : nil
                translationSlots[slot].queue.insert(
                    TranslationQueueItem(sentence: sentence, targetIndex: targetIndex, isPartial: isPartial, elapsedTime: existingLine?.elapsedTime, sentenceID: existingLine?.sentenceID), at: 0
                )
            }
        } catch {
            logger.error("Slot \(slot) translation failed: \(error.localizedDescription)")
            // Only show error for final translations; silently ignore partial failures
            if !isPartial {
                if slot < translationSlots.count,
                   targetIndex >= 0 && targetIndex < translationSlots[slot].lines.count {
                    let existingLine = translationSlots[slot].lines[targetIndex]
                    translationSlots[slot].lines[targetIndex] = TranscriptLine(text: "[Translation failed]", isPartial: false, finalizedAt: Date(), elapsedTime: existingLine.elapsedTime, sentenceID: existingLine.sentenceID)
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
