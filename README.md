# TransTrans

A macOS application for real-time speech transcription and translation. TransTrans captures microphone audio, transcribes speech using Apple's Speech framework, and translates it into a target language using Apple's Translation framework — all in real-time.

![TransTrans Screenshot](screenshot.png)

## Features

- **Real-time transcription** — Live speech-to-text using Apple's Speech framework with progressive transcription
- **Automatic translation** — Instant translation of transcribed text via Apple's Translation framework
- **Multi-target language support** — Translate into up to 5 target languages simultaneously, with one-click language swap (⌘⇧S)
- **Custom vocabulary** — Add domain-specific terminology to improve recognition accuracy (up to 100 words per language)
- **Microphone selection** — Choose from available audio input devices or use the system default
- **Audio level visualization** — Color-coded waveform display (green/orange/red)
- **Native macOS toolbar** — Integrated toolbar with recording, display, language, and font controls
- **Menu bar commands** — Full menu bar integration with save (original/translation/interleaved), copy, and display controls
- **Always-on-top mode** — Keep the window above other applications (⌘T)
- **Adjustable font size** — Resize transcript text (⌘+ / ⌘−)
- **Frosted glass UI** — Translucent HUD-style window design
- **Subtitle mode** — Movie-style subtitle overlay at the bottom of the screen, showing translation only (⌘D); lines auto-expire after 30 seconds
- **Save & copy transcripts** — Save or copy original, translation, or interleaved text via menu or context menu

## Requirements

- macOS 26 or later
- Microphone access
- Network access (for downloading speech recognition assets and translation models)

## Architecture

```
TransTransApp
└── ContentView
    ├── ContentView+Toolbar (native macOS toolbar: record, save, display, language, font)
    ├── MenuCommands (global menu bar commands & shortcuts)
    ├── TranscriptPaneView (×N: source + up to 5 targets)
    ├── SettingsView (custom vocabulary sheet)
    ├── SubtitleWindowController (borderless overlay window)
    │   └── SubtitleOverlayView (subtitle-style translation display)
    └── VisualEffectBackground (frosted glass effect)

SessionViewModel (@Observable)
├── +Transcription (event handling, sentence boundary detection)
├── +Translation (translation queue, multi-target dispatch)
├── +Languages (language configuration, swap logic)
├── +Permissions (microphone & speech authorization)
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
| `com.apple.security.network.client` | Network access for model downloads |

## Build

Open `TransTrans.xcodeproj` in Xcode and build the project (⌘B).

## License

All rights reserved.
