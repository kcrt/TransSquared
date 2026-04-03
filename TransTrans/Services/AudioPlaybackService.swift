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

    /// Loads an audio file for playback.
    func loadAudio(url: URL) {
        player = AVPlayer(url: url)
        logger.debug("Loaded audio for playback: \(url.lastPathComponent)")
    }

    /// Seeks to the given time and starts playing.
    func play(from time: TimeInterval, entryID: UUID) {
        guard let player else { return }
        let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
        player.seek(to: cmTime) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.player?.play()
                self.isPlaying = true
                self.playingEntryID = entryID
                logger.debug("Playing from \(String(format: "%.1f", time))s (entry: \(entryID))")
            }
        }
    }

    /// Stops playback.
    func stop() {
        player?.pause()
        isPlaying = false
        playingEntryID = nil
    }

    /// Stops playback and releases the player.
    func cleanup() {
        stop()
        player = nil
    }
}
