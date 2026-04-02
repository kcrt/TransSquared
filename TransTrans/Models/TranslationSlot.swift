import Foundation
import Translation

/// A queued translation request for a single sentence.
struct TranslationQueueItem: Sendable {
    let sentence: String
    let targetIndex: Int
    let isPartial: Bool
}

/// Encapsulates the mutable translation state for one target language slot.
/// Used for both the single-pane target and each multi-pane target.
struct TranslationSlot {
    var lines: [TranscriptLine] = []
    var queue: [TranslationQueueItem] = []
    var partialTargetIndex: Int = -1
    var partialTranslationTimer: Task<Void, Never>? = nil
    var config: TranslationSession.Configuration? = nil
    /// True while a `handleTranslationSession` loop is actively draining the queue.
    /// When set, `enqueueTranslation` skips `invalidate()` because the running session
    /// will pick up new items via its `while` loop.
    var isProcessing: Bool = false

    /// Ensures a placeholder line exists for the translation, enqueues the sentence, and invalidates config.
    /// If `reusePartial` is true and a valid partial line exists, it is reused; otherwise a new placeholder is appended.
    /// Returns the target line index used.
    @discardableResult
    mutating func enqueueTranslation(sentence: String, isPartial: Bool, resetPartialIndex: Bool = false) -> Int {
        let pIdx = partialTargetIndex
        let hasExistingPartial = pIdx >= 0 && pIdx < lines.count && lines[pIdx].isPartial

        let targetIndex: Int
        if hasExistingPartial {
            targetIndex = pIdx
        } else {
            lines.append(TranscriptLine(text: "…", isPartial: true))
            targetIndex = lines.count - 1
        }

        if !hasExistingPartial || resetPartialIndex {
            partialTargetIndex = resetPartialIndex ? -1 : targetIndex
        }

        queue.append(TranslationQueueItem(sentence: sentence, targetIndex: targetIndex, isPartial: isPartial))
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
        config = nil
    }
}
