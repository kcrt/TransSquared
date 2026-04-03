# TransTrans

A macOS application for real-time speech transcription and translation. TransTrans captures microphone audio, transcribes speech using Apple's Speech framework, and translates it into a target language using Apple's Translation framework — all in real-time.

![TransTrans Screenshot](screenshot.png)

## Features

- **Real-time transcription** — Live speech-to-text using Apple's Speech framework with progressive transcription
- **Automatic translation** — Instant translation of transcribed text via Apple's Translation framework
- **Multi-target language support** — Translate into up to 3 target languages simultaneously, with one-click language swap (⌘⇧S)
- **Audio level visualization** — Color-coded waveform display (green/orange/red)
- **Always-on-top mode** — Keep the window above other applications (⌘T)
- **Subtitle mode** — Movie-style subtitle overlay at the bottom of the screen, showing translation only (⌘D); lines auto-expire after 30 seconds

## Requirements

- macOS 26 or later
- Microphone access

## Architecture

```
TransTransApp
└── ContentView
    ├── ContentView+Toolbar (native macOS toolbar: record, save, display, language, font)
    ├── MenuCommands (global menu bar commands & shortcuts)
    ├── TranscriptPaneView (×N: source + up to 3 targets)
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

| Layer | Responsibility |
|---|---|
| **Models** | Transcript lines, translation slots (`TranslationSlot`), error types (`TransTransError`) |
| **Services** | Audio capture (`AVCaptureSession`), speech recognition (`SpeechTranscriber`, `SpeechAnalyzer`), audio analysis (`AVAudioPCMBuffer+RMS`) |
| **ViewModel** | State management, translation queue, sentence boundary detection, user preferences — split into focused extensions |
| **Views** | SwiftUI declarative UI with native toolbar, menu commands, and keyboard shortcuts |

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| ⌘R | Start / Stop transcription |
| ⌘S | Save both (interleaved) |
| ⌘⇧S | Swap source and target languages |
| ⌘D | Toggle subtitle mode |
| ⌘T | Toggle always-on-top |
| ⌘+ | Increase font size |
| ⌘− | Decrease font size |
| ⌘, | Settings (custom vocabulary) |

## Entitlements

| Entitlement | Purpose |
|---|---|
| `com.apple.security.app-sandbox` | App Sandbox |
| `com.apple.security.device.audio-input` | Microphone access |

## Build

Open `TransTrans.xcodeproj` in Xcode and build the project (⌘B).

## License

All rights reserved.
