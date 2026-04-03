import AVFoundation
import os

private let logger = Logger.app("SpeechSynthesis")

/// Speaks translated text aloud using AVSpeechSynthesizer.
@MainActor
@Observable
final class SpeechSynthesisService: NSObject, AVSpeechSynthesizerDelegate {
    /// Whether speech is currently being synthesized.
    var isSpeaking = false
    /// The entry ID currently being spoken (for UI stop-icon display).
    var speakingEntryID: UUID?

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speaks the given text in the specified language.
    /// If already speaking, the current utterance is stopped first.
    func speak(text: String, language: String, entryID: UUID) {
        // Stop any in-progress speech
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        isSpeaking = true
        speakingEntryID = entryID
        synthesizer.speak(utterance)
        logger.debug("Speaking translation for entry \(entryID) in language '\(language)'")
    }

    /// Stops any ongoing speech synthesis.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        speakingEntryID = nil
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.speakingEntryID = nil
            logger.debug("Speech synthesis finished")
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.speakingEntryID = nil
            logger.debug("Speech synthesis cancelled")
        }
    }
}
