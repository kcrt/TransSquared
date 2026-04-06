# TransTrans

A macOS application for real-time speech transcription and translation. TransTrans captures microphone audio, transcribes speech using Apple's Speech framework, and translates it into a target language using Apple's Translation framework — all in real-time.

![TransTrans Screenshot](screenshot.png)

## Features

- **Real-time transcription** — Live speech-to-text using Apple's Speech framework with progressive transcription
- **Automatic translation** — Instant translation of transcribed text via Apple's Translation framework
- **Multi-target language support** — Translate into up to 10 target languages simultaneously, with one-click language swap (⌘⇧S)

![Multi-language translation](multilang.png)
- **Audio level visualization** — Color-coded waveform display (green/orange/red)
- **Always-on-top mode** — Keep the window above other applications (⌘T)
- **Subtitle mode** — Movie-style subtitle overlay at the bottom of the screen, showing translation only (⌘D); lines auto-expire after 30 seconds

![Subtitle mode](subtitle.png)

## Requirements

- macOS 26 or later
- Microphone access

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

## Language Models

TransTrans uses on-device models for both speech recognition and translation.
Models are downloaded automatically when you select a language that is not yet
installed — a cloud icon (☁️↓) indicates languages that need downloading, and a
progress indicator appears during download.

### Managing Downloaded Models

- **Translation models** — Open **System Settings → General → Language & Region → Translation Languages** to view, download, or remove translation language packs.
- **Speech recognition models** — Managed automatically by the system. There is no user-facing UI to delete them. The system may reclaim storage for models that have not been used recently.

## Documentation

Technical documentation (architecture, audio pipeline, translation pipeline, etc.) is available in the [`docs/`](docs/) directory.

## License

All rights reserved.
