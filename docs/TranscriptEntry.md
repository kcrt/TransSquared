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
              │  carryOver = pendingPartial   │  ← save before clearing
              │  pendingPartial = nil        │
              │  isCommitted = true          │
              │  translations[slot]          │
              │    = TransString("…",        │  ← placeholder inserted
              │       isPartial: true)       │
              │  Enqueued for translation    │
              │                              │
              │  if carryOver exists:        │  ← carry over to next entry
              │    new entry created         │
              │    pendingPartial = carryOver │
              │    elapsedTime = now         │
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

After commit, if a `pendingPartial` existed (from the next utterance arriving early),
it is carried over to a **new entry** immediately — so it never briefly disappears.
The new entry receives `currentElapsedTime`, giving the partial a time label right away.
Otherwise, the next partial/finalized event creates the new entry.

## UI Conversion

`TranscriptEntry` is not passed directly to views. It is converted to `TranscriptLine`:

```swift
// Source pane (1 entry → 1 or 2 lines)
var sourceLines: [TranscriptLine] {
    entries.flatMap { $0.sourceTranscriptLines() }
}

// Translation pane (per slot, 1 entry = 1 line)
func translationLines(forSlot slot: Int) -> [TranscriptLine] {
    entries.compactMap { ... }
}
```

Display logic of `sourceTranscriptLines()`:

| source.text | pendingPartial | Returned lines                                         |
|-------------|----------------|--------------------------------------------------------|
| `""`        | `"Hello"`      | 1 line: `"Hello"` (partial)                            |
| `"Hello."`  | `"、How are"`  | 2 lines: `"Hello."` (final) + `"、How are"` (partial)  |
| `"Hello."`  | `nil`          | 1 line: `"Hello."` (final)                             |
| `""`        | `nil`          | 0 lines (empty)                                        |

> **Note:** When both `source.text` and `pendingPartial` exist, they are returned
> as **separate lines**. The finalized text stays stable on its own line, while the
> partial from the next recognition segment appears below it. This prevents the
> "finalization undone" glitch where new speech briefly appears appended to an
> already-finalized line.

## Worked Example: Real-time Speech Recognition

User says "Hello world. How are you?":

```
Time  Event                        source.text          pendingPartial   isCommitted
──────────────────────────────────────────────────────────────────────────────────────
t0    partial("Hel")               ""                   "Hel"            false
t1    partial("Hello wor")         ""                   "Hello wor"      false
t2    finalized("Hello world.")    "Hello world."       nil              false
      → punctuation detected → commitSentence
      → pendingPartial = nil (cleared on commit)
      → isCommitted = true                                               true
      → "Hello world." enqueued for translation
      → next event goes to a new entry

t3    partial("How")               ""                   "How"            false  ← new entry
t4    partial("How are y")         ""                   "How are y"      false
t5    finalized("How are you?")    "How are you?"       nil              false
      → punctuation detected → commitSentence                            true
```

### Timer-based Boundary (no punctuation)

User says "本日は晴天なり" then "こんにちは。":

```
Time  Event                           source.text        pendingPartial   Display
─────────────────────────────────────────────────────────────────────────────────────
t0    partial("本日は")               ""                 "本日は"         "本日は"
t1    finalized("本日は晴天なり")     "本日は晴天なり"   nil              "本日は晴天なり"
      → no punctuation → 3s timer started
t2    partial("、こんにちは")         (same entry)       "、こんにちは"   "本日は晴天なり"
      ↑ pendingPartial shown as a separate line below                        "、こんにちは"
t3    timer fires → commitSentence
      → carryOver = "、こんにちは"
      → entry[0]: pendingPartial = nil, isCommitted = true
      → new entry[1] created (elapsedTime = now)        entry[1]          "、こんにちは"
      → entry[1].pendingPartial = "、こんにちは"        ↑ carried over, never disappears
t4    finalized("こんにちは。")       "こんにちは。"     nil              "こんにちは。"
      ↑ goes into entry[1] (already exists)
      → punctuation detected → commitSentence
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
