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
    func play(from time: TimeInterval, duration: TimeInterval?, entryID: UUID) {
        guard let player else { return }
        removeBoundaryObserver()
        let cmTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
        player.seek(to: cmTime) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.player?.play()
                self.isPlaying = true
                self.playingEntryID = entryID
                logger.debug("Playing from \(String(format: "%.1f", time))s duration=\(duration.map { String(format: "%.1f", $0) } ?? "nil") (entry: \(entryID))")

                // Schedule automatic stop at the end of this entry's segment
                if let duration, let player = self.player {
                    let endTime = CMTime(seconds: max(0, time) + duration, preferredTimescale: 600)
                    self.boundaryObserver = player.addBoundaryTimeObserver(
                        forTimes: [NSValue(time: endTime)],
                        queue: .main
                    ) { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.stop()
                        }
                    }
                }
            }
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
