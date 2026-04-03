import Foundation
import Translation

/// A queued translation request for a single sentence.
struct TranslationQueueItem: Sendable {
    let sentence: String
    let targetIndex: Int
    let isPartial: Bool
    let elapsedTime: TimeInterval?
    let sentenceID: UUID?
}

/// Encapsulates the mutable translation state for one target language slot.
/// Used for both the single-pane target and each multi-pane target.
struct TranslationSlot {
    var lines: [TranscriptLine] = []
    var queue: [TranslationQueueItem] = []
    var partialTargetIndex: Int = -1
    var partialTranslationTimer: Task<Void, Never>?
    /// The most recent partial text awaiting debounced translation.
    var pendingPartialText: String?
    /// The elapsed time associated with the pending partial text (from the source line).
    var pendingPartialElapsedTime: TimeInterval?
    /// Incremented on each partial translation request; the debounce task re-waits
    /// when it detects the generation changed, avoiding Task creation churn.
    var partialDebounceGeneration: UInt64 = 0
    var config: TranslationSession.Configuration?
    /// True while a `handleTranslationSession` loop is actively draining the queue.
    /// When set, `enqueueTranslation` skips `invalidate()` because the running session
    /// will pick up new items via its `while` loop.
    var isProcessing: Bool = false

    /// Ensures a placeholder line exists for the translation, enqueues the sentence, and invalidates config.
    /// If `reusePartial` is true and a valid partial line exists, it is reused; otherwise a new placeholder is appended.
    /// Returns the target line index used.
    @discardableResult
    mutating func enqueueTranslation(sentence: String, isPartial: Bool, resetPartialIndex: Bool = false, elapsedTime: TimeInterval? = nil, sentenceID: UUID? = nil) -> Int {
        let pIdx = partialTargetIndex
        let hasExistingPartial = pIdx >= 0 && pIdx < lines.count && lines[pIdx].isPartial

        let targetIndex: Int
        if hasExistingPartial {
            targetIndex = pIdx
            // Stamp sentenceID onto the reused partial line (it was nil during partial translation)
            if let sentenceID {
                lines[pIdx].sentenceID = sentenceID
            }
        } else {
            lines.append(TranscriptLine(text: "…", isPartial: true, elapsedTime: elapsedTime, sentenceID: sentenceID))
            targetIndex = lines.count - 1
        }

        if !hasExistingPartial || resetPartialIndex {
            partialTargetIndex = resetPartialIndex ? -1 : targetIndex
        }

        queue.append(TranslationQueueItem(sentence: sentence, targetIndex: targetIndex, isPartial: isPartial, elapsedTime: elapsedTime, sentenceID: sentenceID))
        // Only invalidate when no session is actively processing — the running session's
        // while-loop will naturally pick up newly enqueued items without needing a restart.
        if !isProcessing {
            config?.invalidate()
        }
        return targetIndex
    }

    mutating func reset() {
        queue = []
        partialTargetIndex = -1
        isProcessing = false
        partialTranslationTimer?.cancel()
        partialTranslationTimer = nil
        pendingPartialText = nil
        pendingPartialElapsedTime = nil
        config = nil
    }
}
