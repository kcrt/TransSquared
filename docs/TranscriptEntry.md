# TranscriptEntry Data Model

## Overview

`TranscriptEntry` is the core data model of TransTrans.
It groups source text, translations, and metadata for a single utterance (sentence).

```
entries: [TranscriptEntry]   ← the single source of truth in SessionViewModel
```

## Type Structure

```
TranscriptEntry
├── id: UUID                      Unique identifier (also serves as sentenceID)
├── source: TransString           Accumulated finalized source text
├── pendingPartial: String?       In-progress recognition text (temporary)
├── translations: [TransString?]  Per-slot translations (up to 3 languages, nil = not yet translated)
├── elapsedTime: TimeInterval?    Elapsed time since session start
├── duration: TimeInterval?       Duration of spoken audio
├── isSeparator: Bool             Visual divider between sessions
└── isCommitted: Bool             Set to true after sentence boundary detection → queued for translation

TransString
├── id: UUID          Stable ID for SwiftUI diffing
├── text: String
├── isPartial: Bool
└── finalizedAt: Date?   Timestamp when finalized (used for subtitle auto-dismiss)
```

## Entry Lifecycle

```
                    ┌──────────────────┐
                    │  Entry created    │  ensureCurrentEntry()
                    │  isCommitted     │  source.text = ""
                    │    = false       │  pendingPartial = nil
                    └────────┬─────────┘
                             │
              ┌──────────────▼──────────────┐
              │  .partial event received     │  Speech recognizer sends interim result
              │                              │
              │  pendingPartial = text       │  ← overwrites (keeps latest only)
              │  source.text unchanged       │
              └──────────────┬──────────────┘
                             │ repeats
              ┌──────────────▼──────────────┐
              │  .finalized event received   │  Speech recognizer commits a chunk
              │                              │
              │  pendingPartial = nil        │  ← cleared
              │  source.text += text         │  ← appends finalized text
              │  pendingSentenceBuffer       │  ← also appends to sentence boundary buffer
              │    += text                   │
              └──────────────┬──────────────┘
                             │ partial → finalized repeats
                             │ until sentence boundary detected
                             │
              ┌──────────────▼──────────────┐
              │  Sentence boundary detected  │  Punctuation or 3s silence timeout
              │  commitSentence()            │
              │                              │
              │  isCommitted = true          │
              │  translations[slot]          │
              │    = TransString("…",        │  ← placeholder inserted
              │       isPartial: true)       │
              │  Enqueued for translation    │
              └──────────────┬──────────────┘
                             │
              ┌──────────────▼──────────────┐
              │  Translation complete        │  TranslationSession.translate()
              │                              │
              │  translations[slot]          │
              │    = TransString(result,     │
              │       isPartial: false,      │
              │       finalizedAt: now)      │
              └─────────────────────────────┘
```

### Sentence Boundary Detection

Finalized text accumulates in `pendingSentenceBuffer`. A commit is triggered by either:

1. **Punctuation**: Buffer ends with `.` `。` `!` `?` `！` `？` → immediate commit
2. **Silence timeout**: No new finalized event for 3 seconds → timer-based commit

After commit, the next partial/finalized event goes into a **new entry**.

## UI Conversion

`TranscriptEntry` is not passed directly to views. It is converted to `TranscriptLine`:

```swift
// Source pane (1 entry = 1 line)
var sourceLines: [TranscriptLine] {
    entries.compactMap { $0.sourceTranscriptLine() }
}

// Translation pane (per slot, 1 entry = 1 line)
func translationLines(forSlot slot: Int) -> [TranscriptLine] {
    entries.compactMap { ... }
}
```

Display logic of `sourceTranscriptLine()`:

| source.text | pendingPartial | Displayed text             | isPartial |
|-------------|----------------|----------------------------|-----------|
| `""`        | `"Hello"`      | `"Hello"`                  | true      |
| `"Hello."`  | `" How are"`   | `"Hello. How are"`         | true      |
| `"Hello."`  | `nil`          | `"Hello."`                 | false     |
| `""`        | `nil`          | *(nil — nothing displayed)* | —         |

## Worked Example: Real-time Speech Recognition

User says "Hello world. How are you?":

```
Time  Event                        source.text          pendingPartial   isCommitted
──────────────────────────────────────────────────────────────────────────────────────
t0    partial("Hel")               ""                   "Hel"            false
t1    partial("Hello wor")         ""                   "Hello wor"      false
t2    finalized("Hello world.")    "Hello world."       nil              false
      → punctuation detected → commitSentence
      → isCommitted = true                                               true
      → "Hello world." enqueued for translation
      → next event goes to a new entry

t3    partial("How")               ""                   "How"            false  ← new entry
t4    partial("How are y")         ""                   "How are y"      false
t5    finalized("How are you?")    "How are you?"       nil              false
      → punctuation detected → commitSentence                            true
```

## Related Files

| File | Role |
|------|------|
| `Models/TranscriptModels.swift` | TransString, TranscriptEntry, TranscriptLine definitions |
| `Models/TranslationSlot.swift` | Translation queue management (TranslationQueueItem) |
| `ViewModels/SessionViewModel.swift` | entries, sourceLines, translationLines |
| `ViewModels/SessionViewModel+Transcription.swift` | partial/finalized event handling |
| `ViewModels/SessionViewModel+Translation.swift` | commitSentence, translation execution |
| `ViewModels/SessionViewModel+Editing.swift` | Inline editing of source/translation text |
| `ViewModels/SessionViewModel+Export.swift` | Copy/file export |
