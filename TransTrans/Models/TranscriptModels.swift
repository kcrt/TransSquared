import SwiftUI
import Translation
import os

// MARK: - Centralized Logger

extension Logger {
    /// Creates a Logger scoped to the TransTrans app with the given category.
    static func app(_ category: String) -> Logger {
        Logger(subsystem: "net.kcrt.app.transtrans", category: category)
    }
}

/// Describes a missing permission that the user needs to grant in System Settings.
enum PermissionIssue: Identifiable {
    case microphone
    case speechRecognition

    var id: String {
        switch self {
        case .microphone: return "microphone"
        case .speechRecognition: return "speechRecognition"
        }
    }

    var title: String {
        switch self {
        case .microphone:
            return String(localized: "Microphone Access Required")
        case .speechRecognition:
            return String(localized: "Speech Recognition Access Required")
        }
    }

    var message: String {
        switch self {
        case .microphone:
            return String(localized: "TransTrans needs microphone access for speech transcription. Please enable it in System Settings > Privacy & Security > Microphone.")
        case .speechRecognition:
            return String(localized: "TransTrans needs speech recognition access for transcription. Please enable it in System Settings > Privacy & Security > Speech Recognition.")
        }
    }
}

/// A single line of transcribed/translated text displayed in the UI.
struct TranscriptLine: Identifiable, Sendable {
    let id = UUID()
    var text: String
    var isPartial: Bool
    /// The time when this line was finalized (non-partial). Used for subtitle expiration.
    var finalizedAt: Date?
    /// True for visual separator lines inserted between sessions.
    var isSeparator: Bool = false
}

extension Array where Element == TranscriptLine {
    /// Returns only finalized, non-separator lines suitable for export.
    var finalizedLines: [TranscriptLine] {
        filter { !$0.isPartial && !$0.isSeparator }
    }
}

/// Controls the display style of the main content area.
/// The number of translation panes is determined by `targetCount`, not by the display mode.
enum DisplayMode: String, CaseIterable {
    /// Show source pane and translation pane(s) in the main window.
    case normal
    /// Show only the primary translation in a subtitle-style overlay at the bottom of the screen.
    case subtitle
}

/// A single auto-replacement rule: when `from` appears in transcription output, replace with `to`.
struct AutoReplacement: Codable, Identifiable, Equatable {
    var id = UUID()
    var from: String
    var to: String
}

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
