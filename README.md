# TransTrans

A macOS application for real-time speech transcription and translation. TransTrans captures microphone audio, transcribes speech using Apple's Speech framework, and translates it into a target language using Apple's Translation framework — all in real-time.

## Features

- **Real-time transcription** — Live speech-to-text using Apple's Speech framework with progressive transcription
- **Automatic translation** — Instant translation of transcribed text via Apple's Translation framework
- **Multi-language support** — Configurable source and target languages with one-click language swap (⌘⇧S)
- **Custom vocabulary** — Add domain-specific terminology to improve recognition accuracy (up to 100 words per language)
- **Microphone selection** — Choose from available audio input devices or use the system default
- **Audio level visualization** — Color-coded waveform display (green/orange/red)
- **Always-on-top mode** — Keep the window above other applications (⌘T)
- **Adjustable font size** — Resize transcript text (⌘+ / ⌘−)
- **Frosted glass UI** — Translucent HUD-style window design
- **Subtitle mode** — Movie-style subtitle overlay at the bottom of the screen, showing translation only (⌘D); lines auto-expire after 30 seconds
- **Copy transcripts** — Copy original, translation, or interleaved text via context menu

## Requirements

- macOS 26 or later
- Microphone access
- Network access (for downloading speech recognition assets and translation models)

## Architecture

```
TransTransApp
└── ContentView
    ├── TranscriptPaneView (×2: source & target)
    ├── ControlStripView (sidebar controls)
    ├── SettingsView (custom vocabulary sheet)
    ├── SubtitleWindowController (borderless overlay window)
    │   └── SubtitleOverlayView (subtitle-style translation display)
    └── VisualEffectBackground (frosted glass effect)

SessionViewModel (@Observable)
├── TranscriptionManager (actor: audio → transcription pipeline)
│   └── AudioCaptureService (AVCaptureSession, format conversion)
└── TranslationSession (sentence-boundary-aware translation)
```

| Layer | Responsibility |
|---|---|
| **Services** | Audio capture (`AVCaptureSession`), speech recognition (`SpeechTranscriber`, `SpeechAnalyzer`) |
| **ViewModel** | State management, translation queue, sentence boundary detection, user preferences |
| **Views** | SwiftUI declarative UI with keyboard shortcuts and context menus |

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| ⌘R | Start / Stop transcription |
| ⌘⇧S | Swap source and target languages |
| ⌘D | Toggle subtitle mode |
| ⌘T | Toggle always-on-top |
| ⌘+ | Increase font size |
| ⌘− | Decrease font size |

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
