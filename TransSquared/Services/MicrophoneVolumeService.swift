import AVFoundation
import CoreAudio
import os

private let logger = Logger.app("MicVolume")

/// Provides get/set access to the macOS system input (microphone) volume
/// using CoreAudio HAL APIs.
///
/// When initialized with an `AVCaptureDevice`, operations target that
/// specific device. Otherwise, the system default input device is used.
struct MicrophoneVolumeService {
    private let deviceUID: String?

    init(device: AVCaptureDevice? = nil) {
        self.deviceUID = device?.uniqueID
    }

    // MARK: - Public API

    /// Returns the current input volume (0.0–1.0), or nil if unavailable.
    func getInputVolume() -> Float? {
        guard let deviceID = resolveDeviceID() else { return nil }
        return getVolumeScalar(device: deviceID, scope: kAudioDevicePropertyScopeInput)
    }

    /// Sets the input volume (0.0–1.0). Returns true on success.
    @discardableResult
    func setInputVolume(_ volume: Float) -> Bool {
        guard let deviceID = resolveDeviceID() else { return false }
        return setVolumeScalar(device: deviceID, scope: kAudioDevicePropertyScopeInput, volume: volume)
    }

    /// Whether the target input device supports volume control.
    func isVolumeControlAvailable() -> Bool {
        guard let deviceID = resolveDeviceID() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &address) { return true }
        // Some devices use per-channel volume
        address.mElement = 1
        return AudioObjectHasProperty(deviceID, &address)
    }

    // MARK: - Private Helpers

    /// Resolves the target AudioDeviceID — by UID if specified, otherwise system default.
    private func resolveDeviceID() -> AudioDeviceID? {
        if let deviceUID {
            return audioDeviceID(forUID: deviceUID)
        }
        return defaultInputDeviceID()
    }

    /// Translates an AVCaptureDevice UID to a CoreAudio AudioDeviceID.
    private func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let cfUID: CFString = uid as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafePointer(to: cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size), uidPointer,
                &size, &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            logger.warning("Failed to translate UID to device: \(status)")
            return nil
        }
        return deviceID
    }

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            logger.warning("Failed to get default input device: \(status)")
            return nil
        }
        return deviceID
    }

    private func getVolumeScalar(device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Float? {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)

        // Try main element first
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(device, &address) {
            let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
            if status == noErr { return volume }
        }

        // Fallback: try channel 1
        address.mElement = 1
        if AudioObjectHasProperty(device, &address) {
            let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
            if status == noErr { return volume }
        }

        logger.debug("Volume property not available for device \(device)")
        return nil
    }

    private func setVolumeScalar(device: AudioDeviceID, scope: AudioObjectPropertyScope, volume: Float) -> Bool {
        var vol = volume
        let size = UInt32(MemoryLayout<Float32>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(device, &address) {
            let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &vol)
            if status == noErr { return true }
        }

        // Fallback: try channel 1
        address.mElement = 1
        if AudioObjectHasProperty(device, &address) {
            let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &vol)
            if status == noErr { return true }
        }

        logger.warning("Failed to set input volume for device \(device)")
        return false
    }
}
