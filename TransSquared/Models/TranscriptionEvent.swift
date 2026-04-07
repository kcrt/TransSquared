import Speech
import CoreMedia

enum TranscriptionEvent: Sendable {
    case partial(String, duration: TimeInterval?, audioOffset: TimeInterval?)
    case finalized(String, duration: TimeInterval?, audioOffset: TimeInterval?)
    case error(String)

    /// Creates a `TranscriptionEvent` from a `SpeechTranscriber.Result`.
    static func from(_ result: SpeechTranscriber.Result) -> TranscriptionEvent {
        let text = String(result.text.characters)
        let timeInfo = AudioTimeInfo.from(result.text)
        return result.isFinal
            ? .finalized(text, duration: timeInfo?.duration, audioOffset: timeInfo?.offset)
            : .partial(text, duration: timeInfo?.duration, audioOffset: timeInfo?.offset)
    }
}

/// Timing information extracted from a `SpeechTranscriber.Result`'s `TimeRangeAttribute` runs.
struct AudioTimeInfo: Sendable {
    /// Start position within the audio source (seconds).
    let offset: TimeInterval
    /// Duration of the spoken audio (seconds).
    let duration: TimeInterval

    /// Extracts the audio start offset and total spoken-audio duration from a `SpeechTranscriber.Result`'s
    /// attributed string by reading `TimeRangeAttribute` runs.
    static func from(_ text: AttributedString) -> AudioTimeInfo? {
        var minStart: CMTime?
        var maxEnd: CMTime?
        for run in text.runs {
            guard let timeRange = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
            let start = timeRange.start
            let end = CMTimeAdd(start, timeRange.duration)
            if minStart == nil || CMTimeCompare(start, minStart!) < 0 {
                minStart = start
            }
            if maxEnd == nil || CMTimeCompare(end, maxEnd!) > 0 {
                maxEnd = end
            }
        }
        guard let start = minStart, let end = maxEnd else { return nil }
        let duration = CMTimeGetSeconds(CMTimeSubtract(end, start))
        guard duration > 0 else { return nil }
        return AudioTimeInfo(offset: CMTimeGetSeconds(start), duration: duration)
    }
}

/// Streams returned by `TranscriptionManager.start()`.
struct TranscriptionStreams {
    let events: AsyncStream<TranscriptionEvent>
    let audioLevels: AsyncStream<Float>?
}
