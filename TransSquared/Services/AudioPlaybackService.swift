import AVFoundation
import os

private let logger = Logger.app("AudioPlayback")

/// Plays back recorded audio at specific timestamps using AVPlayer.
@MainActor
@Observable
final class AudioPlaybackService {
    /// Whether audio is currently playing.
    var isPlaying = false
    /// The entry ID currently being played (for UI highlight).
    var playingEntryID: UUID?

    private var player: AVPlayer?
    private var boundaryObserver: Any?

    /// Loads an audio file for playback.
    func loadAudio(url: URL) {
        player = AVPlayer(url: url)
        logger.debug("Loaded audio for playback: \(url.lastPathComponent)")
    }

    /// Seeks to the given time and starts playing.
    /// If `duration` is provided, playback automatically stops after that many seconds.
    func play(from time: TimeInterval, duration: TimeInterval?, entryID: UUID) async {
        guard let player else { return }
        removeBoundaryObserver()
        let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
        await player.seek(to: cmTime)
        player.play()
        isPlaying = true
        playingEntryID = entryID
        logger.debug("Playing from \(String(format: "%.1f", time))s duration=\(duration.map { String(format: "%.1f", $0) } ?? "nil") (entry: \(entryID))")

        if let duration {
            scheduleBoundaryStop(at: max(0, time) + duration)
        }
    }

    private func scheduleBoundaryStop(at seconds: TimeInterval) {
        guard let player else { return }
        let endTime = CMTime(seconds: seconds, preferredTimescale: 600)
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: endTime)], queue: .main
        ) { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.stop() }
        }
    }

    /// Stops playback.
    func stop() {
        removeBoundaryObserver()
        player?.pause()
        isPlaying = false
        playingEntryID = nil
    }

    private func removeBoundaryObserver() {
        if let observer = boundaryObserver {
            player?.removeTimeObserver(observer)
            boundaryObserver = nil
        }
    }

    /// Stops playback and releases the player.
    func cleanup() {
        stop()
        player = nil
    }
}
