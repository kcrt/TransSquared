import SwiftUI
import Translation

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
struct TranscriptLine: Identifiable {
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

/// Encapsulates the mutable translation state for one target language slot.
/// Used for both the single-pane target and each multi-pane target.
struct TranslationSlot {
    var lines: [TranscriptLine] = []
    var queue: [(sentence: String, targetIndex: Int, isPartial: Bool)] = []
    var partialTargetIndex: Int = -1
    var partialTranslationTimer: Task<Void, Never>? = nil
    var config: TranslationSession.Configuration? = nil

    mutating func reset() {
        queue = []
        partialTargetIndex = -1
        partialTranslationTimer?.cancel()
        partialTranslationTimer = nil
        config = nil
    }
}
