# Audio Capture & Recording Architecture

## Overview

TransTrans runs two independent audio pipelines in parallel:

1. **Analysis path** — Converts microphone audio to a Speech framework-compatible format for real-time transcription
2. **Recording path** — Encodes `CMSampleBuffer` to AAC and saves to an m4a file

```
Microphone (device-specific format, e.g. Int16 48kHz / Float32 48kHz)
  │
  ▼ ── Conversion① AVCaptureAudioDataOutput (audioSettings)
  │    Device format → Float32 non-interleaved 48kHz
  │
  CMSampleBuffer (Float32 non-interleaved, system rate 48 kHz)
  │
  ├─[Recording path]─→ CMSampleBuffer → Conversion③ AVAssetWriterInput → AAC m4a
  │
  └─[Analysis path]──→ CMSampleBuffer → AVAudioPCMBuffer (copyPCMData)
                         │
                         ▼ ── Conversion② AVAudioConverter (AudioCaptureDelegate)
                         │    Float32 48 kHz → Float32 16 kHz mono
                         │
                         ▼
                       RMS level metering + buffer accumulation (300 ms)
                         │
                         ▼
                       SpeechAnalyzer input stream
```

## Format Conversion Responsibilities

Audio data undergoes format conversion at 3 stages. Each stage's ownership is documented below.

### Conversion① Device Format → Float32 (AudioCaptureService)

| Item | Details |
|------|---------|
| **Owner** | `AVCaptureAudioDataOutput` (OS internal) |
| **Configured at** | `AudioCaptureService.startCapture()` — `audioOutput.audioSettings` |
| **Conversion** | Device-specific format → **Float32 non-interleaved** |
| **Example** | Razer Seiren Mini: Int16 48kHz → Float32 48kHz |
| **Why needed** | Devices output varying formats (Int16/Float32, etc.). `copyPCMData` requires the destination `AVAudioPCMBuffer` format to exactly match the sample buffer format, so we normalize here |

```swift
// AudioCaptureService.swift
audioOutput.audioSettings = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsNonInterleaved: true,
]
```

> **Note**: Sample rate and channel count are preserved from the device's native values (typically 48 kHz, 1ch or 2ch).

### Conversion② Resampling (AudioCaptureDelegate)

| Item | Details |
|------|---------|
| **Owner** | `AVAudioConverter` (inside AudioCaptureDelegate) |
| **Configured at** | `AudioCaptureDelegate.setupPipeline()` — created once on first buffer arrival |
| **Conversion** | Float32 48kHz → **target format** (format requested by SpeechAnalyzer, e.g. 16 kHz mono) |
| **Why needed** | The Speech framework requires a different sample rate than the device output |

```swift
// AudioCaptureDelegate.setupPipeline()
let srcFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)  // detect actual format
converter = AVAudioConverter(from: srcFormat, to: targetFormat)       // created only if mismatch
```

### Conversion③ AAC Encoding (AudioRecordingService)

| Item | Details |
|------|---------|
| **Owner** | `AVAssetWriterInput` internal encoder |
| **Configured at** | `AudioRecordingService.appendSampleBuffer()` — lazily created on first buffer arrival |
| **Conversion** | Float32 48kHz → **AAC 48kHz mono 128kbps** |
| **Why needed** | Efficient storage of recorded audio. Operates independently of the analysis path |

```swift
// AudioRecordingService.appendSampleBuffer()
let input = AVAssetWriterInput(
    mediaType: .audio,
    outputSettings: Self.outputSettings,         // AAC, 48kHz, mono, 128kbps
    sourceFormatHint: sampleBuffer.formatDescription  // format after Conversion①
)
```

### Conversion Flow Summary

```
Device (Int16/Float32, any rate)
  │
  ├─ Conversion① OS normalizes to Float32 non-interleaved [AudioCaptureService]
  │              Sample rate and channel count preserved
  │
  ├─ Conversion② AVAudioConverter resamples [AudioCaptureDelegate]
  │              48 kHz → 16 kHz, stereo → mono (only when needed)
  │              → feeds SpeechAnalyzer
  │
  └─ Conversion③ AVAssetWriterInput encodes to AAC [AudioRecordingService]
                  Float32 48 kHz → AAC 48 kHz mono 128 kbps
                  → writes to m4a file
```

## Session Start Flow

```
SessionViewModel.startSession()
  │
  ├─ Create AudioRecordingService(), begin writing to temporary m4a file
  │
  ├─ Call transcriptionManager.start(recordingService:)
  │   │
  │   ├─ Create SpeechTranscriber (.timeIndexedProgressiveTranscription preset)
  │   ├─ Install speech recognition assets (if not already installed)
  │   ├─ Determine target format via SpeechAnalyzer.bestAvailableAudioFormat()
  │   ├─ Create AudioCaptureService()
  │   ├─ Call captureService.startCapture(audioFormat:, device:, recordingService:)
  │   │   │
  │   │   ├─ Build AVCaptureSession + AVCaptureDeviceInput + AVCaptureAudioDataOutput
  │   │   ├─ Set audioOutput.audioSettings to request Float32 non-interleaved output [Conversion①]
  │   │   ├─ Create AudioCaptureDelegate (targetFormat, continuations)
  │   │   └─ Await startRunning() (throws on failure)
  │   │
  │   ├─ analyzeTask: audioStream → SpeechAnalyzer.analyzeSequence()
  │   └─ resultTask: SpeechTranscriber.results → TranscriptionEvent stream
  │
  ├─ audioLevelTask: waveform display + silence detection for sentence boundary
  └─ transcriptionTask: consume TranscriptionEvents → update entries
```

## AudioCaptureDelegate: 6-Step Pipeline

`captureOutput(_:didOutput:from:)` is called on the captureQueue for every frame:

| Step | Operation | Details |
|------|-----------|---------|
| 1 | Record [Conversion③] | `recordingService?.appendSampleBuffer(sampleBuffer)` — send Float32 buffer to AAC recording |
| 2 | Pipeline init | `setupPipeline(from:)` — detect actual format on first buffer, create AVAudioConverter for Conversion② |
| 3 | PCM conversion | `cmSampleBufferToAVAudioPCMBuffer()` — CMSampleBuffer → AVAudioPCMBuffer (data copy only, no format conversion) |
| 4 | Resample [Conversion②] | `convert()` — only runs when source ≠ target (e.g. 48 kHz → 16 kHz) |
| 5 | Level metering | `yieldAudioLevel(from:)` — RMS → dB → normalized (0–1) → UI |
| 6 | Accumulate + yield | `accumulateAndYield()` — yield after accumulating 4800 frames (300 ms @ 16 kHz) |

### setupPipeline (first buffer only)

1. Extract actual format from `CMSampleBuffer.formatDescription` via `AVAudioFormat(cmAudioFormatDescription:)`
2. Compare 4 attributes against target format (sampleRate, channelCount, commonFormat, isInterleaved)
3. If mismatched, create `AVAudioConverter` and compute `conversionRatio`
4. Cache `needsConversion` / `pipelineReady` — subsequent buffers reuse these results

### Buffer Accumulation

Small PCM chunks are accumulated before yielding, to give the speech recognizer sufficient context.

- **Accumulation threshold**: 4800 frames @ 16 kHz = 300 ms
- When threshold is reached, yield the buffer and carry over excess frames to the next buffer
- On stop, `flushAccumulationBuffer()` yields any remaining data

### Audio Level Metering

```
RMS = vDSP_rmsqv(samples)              // SIMD-optimized
dB  = 20 * log10(max(RMS, 1e-10))      // convert to decibels
normalized = (dB - (-50)) / 50          // -50 dB → 0.0, 0 dB → 1.0
```

- Used for UI waveform display
- Normalized value ≤ 0.2 (approx. -40 dB) sustained for `sentenceBoundarySeconds` triggers sentence boundary confirmation

## AudioRecordingService: How Recording Works

### Lazy Writer Input

`AVAssetWriterInput` is lazily created when the first `CMSampleBuffer` arrives.
This ensures the actual buffer's `CMFormatDescription` is used as `sourceFormatHint`,
guaranteeing correct encoder settings regardless of microphone hardware format.

```
startRecording()     → Create AVAssetWriter (no inputs)
appendSampleBuffer() → First call: create AVAssetWriterInput + startWriting + startSession
                       Subsequent: writerInput.append(sampleBuffer)
finishWriterInput()  → writerInput.markAsFinished()
stopRecording()      → writer.finishWriting() → file finalized
```

**AAC output settings** (fixed):
- Format: MPEG4 AAC
- Channels: 1 (mono)
- Sample rate: 48,000 Hz
- Bit rate: 128 kbps

## Session Stop Flow

```
SessionViewModel.stopSession()
  │
  ├─ Cancel audioLevelTask / sentenceBoundaryTimer
  │
  ├─ await transcriptionManager.stop()
  │   │
  │   ├─ await audioCaptureService.stopCapture()
  │   │   ├─ captureSession.stopRunning()
  │   │   └─ captureQueue.sync:
  │   │       ├─ delegate.finishRecording() → recordingService.finishWriterInput()
  │   │       └─ delegate.flushAccumulationBuffer() → yield remaining buffers
  │   │
  │   ├─ await analyzeTask (wait for natural completion → finalizeAndFinish confirms final result)
  │   ├─ await resultTask (wait for result stream to end)
  │   └─ analyzer.cancelAndFinishNow() (fallback)
  │
  ├─ Cancel transcriptionTask
  ├─ await recordingService.stopRecording() → writer.finishWriting()
  └─ isSessionActive = false
```

**Important**: `analyzeTask` is NOT cancelled. After the stream ends, `finalizeAndFinish(through: endTime)` is called to confirm the last partial result as final.

## File Transcription (AudioFileTranscriber)

Key differences from live capture:

| | Live Capture | File Transcription |
|---|---|---|
| Input | `AsyncStream<AnalyzerInput>` | `AVAudioFile` |
| Preset | `.timeIndexedProgressiveTranscription` | `.transcription` + `.audioTimeRange` |
| Format conversion | Manual via `AVAudioConverter` | Handled internally by `AVAudioFile` |
| Buffer accumulation | Manual (300 ms chunks) | Not needed |
| Recording | Yes (AAC m4a) | No (input is already a file) |
| Progress | None | Computed via `volatileRangeChangedHandler` |

## MicrophoneVolumeService: CoreAudio HAL

Gets/sets macOS system input volume via CoreAudio HAL API.

- `AVCaptureDevice.uniqueID` → `kAudioHardwarePropertyTranslateUIDToDevice` → `AudioDeviceID`
- Read/write 0.0–1.0 volume via `kAudioDevicePropertyVolumeScalar`
- Falls back to channel 1 if main element fails

## Audio Playback (AudioPlaybackService)

Playback of recorded audio files:

1. Load m4a file with `AVPlayer(url:)`
2. Seek to specified timestamp via `player.seek(to:)`
3. Start playback with `player.play()`
4. If entry has a duration, auto-stop via `addBoundaryTimeObserver`

## Related Files

| File | Role |
|------|------|
| `AudioCaptureDelegate.swift` | AVCapture callback, format conversion, accumulation, level metering |
| `AudioCaptureService.swift` | AVCaptureSession setup and management |
| `AudioRecordingService.swift` | AAC recording via AVAssetWriter |
| `TranscriptionManager.swift` | SpeechAnalyzer/Transcriber management, pipeline integration |
| `AudioFileTranscriber.swift` | Offline transcription from files |
| `AudioPlaybackService.swift` | Audio playback via AVPlayer |
| `MicrophoneVolumeService.swift` | Microphone volume control via CoreAudio HAL |
| `AVAudioPCMBuffer+RMS.swift` | RMS level computation using vDSP |
