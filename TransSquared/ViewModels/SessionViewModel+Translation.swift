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

        // A session being provided means the translation model is installed
        guard slot < targetLanguageIdentifiers.count else { return }
        let langId = targetLanguageIdentifiers[slot]
        if targetLanguageDownloadStatus[langId] != true {
            targetLanguageDownloadStatus[langId] = true
        }

        // Process queued translations using the session provided by the closure.
        // Re-check bounds after each await since translationSlots may be rebuilt.
        while slot < translationSlots.count && !translationSlots[slot].queue.isEmpty {
            let item = translationSlots[slot].queue.removeFirst()
            translationSlots[slot].currentItem = item
            let result = await translateSentence(item.sentence, using: session, slot: slot, entryID: item.entryID, isPartial: item.isPartial)
            if slot < translationSlots.count {
                translationSlots[slot].currentItem = nil
                if let resultText = result.text {
                    translationSlots[slot].recentlyCompleted.append(
                        CompletedTranslationItem(source: item, resultText: resultText, completedAt: Date())
                    )
                    // Prune items older than 6 seconds (buffer beyond the 5s display).
                    let cutoff = Date().addingTimeInterval(-6)
                    translationSlots[slot].recentlyCompleted.removeAll { $0.completedAt < cutoff }
                }
                // Session was invalidated — stop processing with this session.
                // Re-enqueued items will be picked up when a new session is provided.
                if result.sessionInvalidated {
                    logger.info("Slot \(slot) session invalidated, breaking out of processing loop (\(self.translationSlots[slot].queue.count) items remaining)")
                    if slot < translationConfigs.count {
                        translationConfigs[slot]?.invalidate()
                    }
                    break
                }
            }
        }
    }

    // MARK: - Translation Model Preparation

    /// Called from the preparation `.translationTask()` modifier when a session is available for proactive download.
    /// Calls `prepareTranslation()` once. If it fails, the user can install models manually from
    /// System Settings > General > Language & Region > Translation Languages.
    func handleTranslationPreparationSession(_ session: TranslationSession) async {
        let langId = translationPreparationConfig?.target?.minimalIdentifier ?? ""
        logger.info("Translation preparation session available for '\(langId)'")

        do {
            try await session.prepareTranslation()
            targetLanguageDownloadStatus[langId] = true
            logger.info("Translation model prepared for '\(langId)'")
        } catch {
            logger.error("Translation preparation failed for '\(langId)': \(error.localizedDescription)")
        }
        translationPreparationConfig = nil
    }

    // MARK: - Translation Queue

    /// Appends a translation item to the slot's queue and triggers the translation session if idle.
    func enqueueTranslation(slot: Int, item: TranslationQueueItem) {
        guard slot < translationSlots.count else { return }
        translationSlots[slot].queue.append(item)
        #if DEBUG
        let queueSize = translationSlots[slot].queue.count
        if queueSize > (debugPeakQueueSize[slot] ?? 0) {
            debugPeakQueueSize[slot] = queueSize
        }
        #endif
        if !translationSlots[slot].isProcessing, slot < translationConfigs.count {
            translationConfigs[slot]?.invalidate()
        }
    }

    func requestPartialTranslation(for text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Use the elapsed time from the current entry
        let sourceElapsedTime = entries.last?.elapsedTime

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
            translationSlots[capturedSlot].pendingPartialElapsedTime = nil

            enqueuePartialTranslation(slot: capturedSlot, text: text)
        }
    }

    /// Creates or reuses a partial translation placeholder in the current entry and enqueues it.
    private func enqueuePartialTranslation(slot: Int, text: String) {
        let idx = ensureCurrentEntry()
        let entryID = entries[idx].id

        // Create or reuse partial translation placeholder
        if entries[idx].translations[slot] == nil {
            entries[idx].translations[slot] = TransString(text: "…", isPartial: true)
        }

        translationSlots[slot].partialEntryID = entryID
        // Remove stale partial items for this entry — only the latest partial matters.
        translationSlots[slot].queue.removeAll { $0.isPartial && $0.entryID == entryID }
        enqueueTranslation(slot: slot, item: TranslationQueueItem(
            sentence: text, entryID: entryID, isPartial: true, elapsedTime: entries[idx].elapsedTime
        ))
        // logger.debug("Queuing partial translation slot \(slot): \"\(text, privacy: .private)\"")
    }

    func commitSentence(_ sentence: String) {
        guard !sentence.isEmpty else { return }

        segmentIndex += 1

        // Get the current entry (which accumulated source segments for this sentence)
        guard let idx = currentEntryIndex else {
            logger.warning("commitSentence called but no current entry exists")
            return
        }

        // Save pending partial — it belongs to the next utterance, not this one.
        let carryOverPartial = entries[idx].pendingPartial
        entries[idx].pendingPartial = nil
        entries[idx].isCommitted = true

        logger.debug("Committing sentence #\(self.segmentIndex): \"\(sentence, privacy: .private)\"")

        for slot in 0..<targetCount {
            commitSentenceForSlot(slot, entryIndex: idx, sentence: sentence)
        }

        // Carry over the pending partial to a new entry so it doesn't briefly disappear.
        // ensureCurrentEntry() creates a new entry with currentElapsedTime, so the
        // time label also appears immediately.
        if let partial = carryOverPartial, !partial.isEmpty {
            let newIdx = ensureCurrentEntry()
            entries[newIdx].pendingPartial = partial
        }
    }

    private func commitSentenceForSlot(_ slot: Int, entryIndex idx: Int, sentence: String) {
        guard slot < translationSlots.count else { return }
        translationSlots[slot].resetPartialState()

        let entryID = entries[idx].id
        let elapsed = entries[idx].elapsedTime

        // Remove queued partial translations for this entry — they are superseded by the final request.
        translationSlots[slot].queue.removeAll { $0.isPartial && $0.entryID == entryID }

        // Create or reuse translation placeholder (may already exist from partial)
        if let existing = entries[idx].translations[slot], existing.isPartial {
            // Keep existing partial text visible until the final translation arrives
        } else {
            entries[idx].translations[slot] = TransString(text: "…", isPartial: true)
        }

        translationSlots[slot].partialEntryID = nil
        enqueueTranslation(slot: slot, item: TranslationQueueItem(
            sentence: sentence, entryID: entryID, isPartial: false, elapsedTime: elapsed
        ))
        // logger.debug("Queuing for translation (slot: \(slot), entryID: \(entryID))")
    }

    /// Result of a single translation attempt, indicating both the translated text (if any)
    /// and whether the session was invalidated (requiring a new session to continue).
    struct TranslationAttemptResult {
        var text: String?
        var sessionInvalidated: Bool = false
    }

    private func translateSentence(_ sentence: String, using session: TranslationSession, slot: Int, entryID: UUID, isPartial: Bool) async -> TranslationAttemptResult {
        // logger.debug("Translating slot \(slot) (\(isPartial ? "partial" : "final")): \"\(sentence, privacy: .private)\"")
        do {
            let response = try await session.translate(sentence)
            // logger.debug("Slot \(slot) translation result (\(isPartial ? "partial" : "final")): \"\(response.targetText, privacy: .private)\"")

            // Re-validate after await: the entries array may have changed during the async gap.
            guard slot < translationSlots.count,
                  let entryIdx = entryIndex(for: entryID) else {
                // logger.debug("Slot \(slot) entry \(entryID) no longer valid after translation, discarding result")
                return TranslationAttemptResult()
            }

            let existing = entries[entryIdx].translations[slot]

            if isPartial {
                // Only update if the translation is still partial (a finalized translation may have arrived)
                guard existing?.isPartial == true, let existingID = existing?.id else { return TranslationAttemptResult() }
                entries[entryIdx].translations[slot] = TransString(
                    id: existingID, text: response.targetText, isPartial: true
                )
            } else {
                entries[entryIdx].translations[slot] = TransString(
                    id: existing?.id ?? UUID(), text: response.targetText, isPartial: false, finalizedAt: Date()
                )
            }
            #if DEBUG
            debugTranslationSuccessCount[slot, default: 0] += 1
            #endif
            return TranslationAttemptResult(text: response.targetText)
        } catch is CancellationError {
            logger.info("Slot \(slot) translation cancelled")
            return TranslationAttemptResult()
        } catch where Self.isTranslationSessionCancellation(error) {
            let nsError = error as NSError
            logger.info("Slot \(slot) translation session cancelled (domain: \(nsError.domain), code: \(nsError.code)), re-enqueueing")
            if slot < translationSlots.count {
                let elapsed = entryIndex(for: entryID).flatMap { entries[$0].elapsedTime }
                translationSlots[slot].queue.insert(
                    TranslationQueueItem(sentence: sentence, entryID: entryID, isPartial: isPartial, elapsedTime: elapsed), at: 0
                )
                #if DEBUG
                debugTranslationReenqueueCount[slot, default: 0] += 1
                #endif
            }
            return TranslationAttemptResult(sessionInvalidated: true)
        } catch {
            logger.error("Slot \(slot) translation failed: \(error.localizedDescription)")
            #if DEBUG
            debugTranslationFailureCount[slot, default: 0] += 1
            #endif
            guard !isPartial, let entryIdx = entryIndex(for: entryID) else { return TranslationAttemptResult() }
            let existing = entries[entryIdx].translations[slot]
            entries[entryIdx].translations[slot] = TransString(
                id: existing?.id ?? UUID(), text: "[Translation failed]", isPartial: false, finalizedAt: Date()
            )
            return TranslationAttemptResult(text: "[Translation failed]")
        }
    }

    /// Determines whether an error represents a Translation framework session cancellation.
    /// The Translation framework signals session invalidation with code 2 in its error domain.
    /// Only match that specific code; other errors (e.g., network, unsupported language)
    /// should propagate as real failures.
    private static func isTranslationSessionCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain.contains("Translation") && nsError.code == 2
    }
}
