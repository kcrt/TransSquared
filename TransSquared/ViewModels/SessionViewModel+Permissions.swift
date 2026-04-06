import AVFoundation
import Speech
import AppKit
import os

private let logger = Logger.app("Permissions")

// MARK: - Permission Checks

extension SessionViewModel {

    /// Checks microphone and speech recognition permissions, returning false if denied.
    func checkPermissions() async -> Bool {
        // Check microphone access
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                logger.warning("Microphone access denied by user")
                permissionIssue = .microphone
                return false
            }
        case .denied, .restricted:
            logger.warning("Microphone access denied (status: \(micStatus.rawValue))")
            permissionIssue = .microphone
            return false
        case .authorized:
            break
        @unknown default:
            logger.warning("Unknown microphone authorization status: \(micStatus.rawValue)")
            permissionIssue = .microphone
            return false
        }

        // Check speech recognition access
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        switch speechStatus {
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            if !granted {
                logger.warning("Speech recognition access denied by user")
                permissionIssue = .speechRecognition
                return false
            }
        case .denied, .restricted:
            logger.warning("Speech recognition access denied (status: \(speechStatus.rawValue))")
            permissionIssue = .speechRecognition
            return false
        case .authorized:
            break
        @unknown default:
            logger.warning("Unknown speech recognition authorization status: \(speechStatus.rawValue)")
            permissionIssue = .speechRecognition
            return false
        }

        return true
    }

    /// Opens the Privacy & Security section in System Settings.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
}
