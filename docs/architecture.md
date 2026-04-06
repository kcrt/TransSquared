# Architecture

## Project Structure

```
TransTransApp
└── ContentView
    ├── ContentView+Toolbar (native macOS toolbar: record, save, display, language, font)
    ├── MenuCommands (global menu bar commands & shortcuts)
    ├── TranscriptPaneView (×N: source + up to 10 targets)
    ├── SettingsView (custom vocabulary sheet)
    ├── SubtitleWindowController (borderless overlay window)
    │   └── SubtitleOverlayView (subtitle-style translation display)
    └── HelperViews (reusable menu items, checkmark labels)

SessionViewModel (@Observable)
├── +Transcription (event handling, sentence boundary detection)
├── +Translation (translation queue, multi-target dispatch)
├── +Languages (language configuration, swap logic)
├── +Permissions (microphone & speech authorization)
├── +Export (save/copy transcript in various formats)
├── +FileTranscription (transcribe audio files)
├── TranscriptionManager (actor: audio → transcription pipeline)
│   ├── AudioCaptureService (AVCaptureSession, format conversion)
│   └── AudioCaptureDelegate (sample buffer → PCM conversion, RMS)
└── TranslationSlot (per-target translation state & queue)
```

## Layer Responsibilities

| Layer | Responsibility |
|---|---|
| **Models** | Transcript lines, translation slots (`TranslationSlot`), error types (`TransTransError`) |
| **Services** | Audio capture (`AVCaptureSession`), speech recognition (`SpeechTranscriber`, `SpeechAnalyzer`), audio analysis (`AVAudioPCMBuffer+RMS`) |
| **ViewModel** | State management, translation queue, sentence boundary detection, user preferences — split into focused extensions |
| **Views** | SwiftUI declarative UI with native toolbar, menu commands, and keyboard shortcuts |

## Entitlements

| Entitlement | Purpose |
|---|---|
| `com.apple.security.app-sandbox` | App Sandbox |
| `com.apple.security.device.audio-input` | Microphone access |

## Build

Open `TransTrans.xcodeproj` in Xcode and build the project (⌘B).

## Further Documentation

- [TranscriptEntry Data Model](TranscriptEntry.md)
- [Audio Capture & Recording Architecture](audio_capture.md)
- [Translation Pipeline](translation_pipeline.md)
- [Language Model Availability](language_availability.md)
