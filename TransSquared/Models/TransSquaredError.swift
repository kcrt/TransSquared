import Foundation

/// Consolidated error type for Trans².
enum TransSquaredError: Error, LocalizedError {
    // Audio capture errors
    case alreadyCapturing
    case microphoneUnavailable

    // Transcription errors
    case alreadyRunning
    case audioFormatUnavailable

    // Recording errors
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing:
            return String(localized: "Audio capture is already in progress.")
        case .microphoneUnavailable:
            return String(localized: "Microphone is not available.")
        case .alreadyRunning:
            return String(localized: "Transcription is already running.")
        case .audioFormatUnavailable:
            return String(localized: "No compatible audio format available. Assets may need to be installed.")
        case .recordingFailed:
            return String(localized: "Failed to start audio recording.")
        }
    }
}
