import SwiftUI

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

// MARK: - TransString

/// A text string with partial/finalized state, used as the building block for source segments and translations.
struct TransString: Identifiable, Sendable {
    let id: UUID
    var text: String
    var isPartial: Bool
    /// The time when this string was finalized (non-partial). Used for subtitle expiration.
    var finalizedAt: Date?

    init(id: UUID = UUID(), text: String, isPartial: Bool, finalizedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.isPartial = isPartial
        self.finalizedAt = finalizedAt
    }
}

// MARK: - TranscriptEntry

/// A single utterance unit grouping source text with its translations and shared metadata.
/// Each entry corresponds to one committed sentence (or an in-progress uncommitted one).
struct TranscriptEntry: Identifiable, Sendable {
    let id: UUID
    /// Accumulated finalized source text for this utterance.
    var source: TransString
    /// Current partial recognition text (in-progress, not yet finalized). Displayed but temporary.
    var pendingPartial: String?
    /// Translations indexed by slot (0..<maxTargetCount). `nil` means not yet translated.
    var translations: [TransString?]
    /// Cumulative elapsed time (in seconds) from the first session start when this entry was created.
    var elapsedTime: TimeInterval?
    /// The duration of spoken audio for this entry, in seconds.
    var duration: TimeInterval?
    /// True for visual separator entries inserted between sessions.
    var isSeparator: Bool
    /// True after sentence boundary detection commits this entry for translation.
    var isCommitted: Bool

    /// Maximum number of target language slots.
    static let maxTranslationSlots = 3

    init(
        id: UUID = UUID(),
        source: TransString = TransString(text: "", isPartial: false),
        pendingPartial: String? = nil,
        translations: [TransString?]? = nil,
        elapsedTime: TimeInterval? = nil,
        duration: TimeInterval? = nil,
        isSeparator: Bool = false,
        isCommitted: Bool = false
    ) {
        self.id = id
        self.source = source
        self.pendingPartial = pendingPartial
        self.translations = translations ?? Array(repeating: nil, count: Self.maxTranslationSlots)
        self.elapsedTime = elapsedTime
        self.duration = duration
        self.isSeparator = isSeparator
        self.isCommitted = isCommitted
    }

    /// Derives `TranscriptLine`(s) for the source pane.
    /// When both finalized text and a pending partial exist, they are returned as
    /// **separate lines** so the finalized text stays stable and the partial appears below it.
    func sourceTranscriptLines() -> [TranscriptLine] {
        if isSeparator {
            return [TranscriptLine(id: id, text: "", isPartial: false, isSeparator: true)]
        }
        var lines: [TranscriptLine] = []
        if !source.text.isEmpty {
            lines.append(TranscriptLine(
                id: source.id,
                text: source.text,
                isPartial: false,
                elapsedTime: elapsedTime,
                duration: duration,
                sentenceID: isCommitted ? id : nil
            ))
        }
        if let partial = pendingPartial, !partial.isEmpty {
            lines.append(TranscriptLine(
                id: source.text.isEmpty ? source.id : id,
                text: partial,
                isPartial: true,
                elapsedTime: source.text.isEmpty ? elapsedTime : nil
            ))
        }
        return lines
    }

    /// Derives a `TranscriptLine` for the translation pane of the given slot, or `nil` if no translation exists.
    func translationTranscriptLine(forSlot slot: Int) -> TranscriptLine? {
        guard slot < translations.count, let trans = translations[slot] else { return nil }
        return TranscriptLine(
            id: trans.id,
            text: trans.text,
            isPartial: trans.isPartial,
            finalizedAt: trans.finalizedAt,
            elapsedTime: elapsedTime,
            sentenceID: id
        )
    }
}

// MARK: - TranscriptLine (UI display type)

/// A single line of transcribed/translated text displayed in the UI.
/// Derived from `TranscriptEntry` for view consumption.
struct TranscriptLine: Identifiable, Sendable {
    let id: UUID
    var text: String
    var isPartial: Bool
    /// The time when this line was finalized (non-partial). Used for subtitle expiration.
    var finalizedAt: Date?
    /// True for visual separator lines inserted between sessions.
    var isSeparator: Bool
    /// Cumulative elapsed time (in seconds) from the first session start when this line was created.
    var elapsedTime: TimeInterval?
    /// The duration of spoken audio for this line, in seconds.
    var duration: TimeInterval?
    /// The entry ID (sentence ID) this line belongs to.
    var sentenceID: UUID?

    init(
        id: UUID = UUID(),
        text: String,
        isPartial: Bool,
        finalizedAt: Date? = nil,
        isSeparator: Bool = false,
        elapsedTime: TimeInterval? = nil,
        duration: TimeInterval? = nil,
        sentenceID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.isPartial = isPartial
        self.finalizedAt = finalizedAt
        self.isSeparator = isSeparator
        self.elapsedTime = elapsedTime
        self.duration = duration
        self.sentenceID = sentenceID
    }
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
