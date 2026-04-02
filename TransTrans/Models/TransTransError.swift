import Foundation

/// Consolidated error type for TransTrans.
enum TransTransError: Error, LocalizedError {
    // Audio capture errors
    case alreadyCapturing
    case microphoneUnavailable

    // Transcription errors
    case alreadyRunning
    case audioFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing:
            return "Audio capture is already in progress."
        case .microphoneUnavailable:
            return "Microphone is not available."
        case .alreadyRunning:
            return "Transcription is already running."
        case .audioFormatUnavailable:
            return "No compatible audio format available. Assets may need to be installed."
        }
    }
}
