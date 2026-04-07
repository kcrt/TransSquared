import Foundation
import Translation

/// A queued translation request for a single sentence.
struct TranslationQueueItem: Sendable {
    let sentence: String
    let entryID: UUID
    let isPartial: Bool
    let elapsedTime: TimeInterval?
}

/// Encapsulates the mutable translation state for one target language slot.
/// Manages the translation queue and session lifecycle.
/// Translation results are written to `TranscriptEntry.translations` in the view model.
struct TranslationSlot {
    var queue: [TranslationQueueItem] = []
    var partialEntryID: UUID?
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
    /// When set, enqueue skips `invalidate()` because the running session
    /// will pick up new items via its `while` loop.
    var isProcessing: Bool = false

    /// Clears the debounced partial translation state for this slot.
    mutating func resetPartialState() {
        partialTranslationTimer?.cancel()
        partialTranslationTimer = nil
        pendingPartialText = nil
        pendingPartialElapsedTime = nil
        partialEntryID = nil
    }

    mutating func reset() {
        queue = []
        isProcessing = false
        resetPartialState()
        config = nil
    }
}
