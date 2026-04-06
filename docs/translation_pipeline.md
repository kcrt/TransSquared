# Translation Pipeline

## Overview

TransTrans translates recognized speech into one or more target languages in real time.
Each target language runs in its own **translation slot** — slots are independent and
process translations concurrently. Within a single slot, translations are processed
serially in FIFO order.

```
Slot 0 (e.g. Japanese):  [item1] → [item2] → [item3]   ← serial
Slot 1 (e.g. French):    [item1] → [item2]              ← serial
                          ↑ these run concurrently ↑
```

## Architecture

### Key Types

| Type | File | Role |
|------|------|------|
| `TranslationSlot` | `Models/TranslationSlot.swift` | Per-slot mutable state: queue, debounce timer, session config |
| `TranslationQueueItem` | `Models/TranslationSlot.swift` | A single queued request (sentence, entryID, isPartial) |
| `TranslationSession` | Apple Translation framework | Performs the actual translation |

### View Integration

Translation sessions are provided by SwiftUI's `.translationTask()` view modifier.
`ContentView` attaches one modifier per slot via a hidden `ForEach`:

```swift
// ContentView.swift — TranslationTaskSlots
ForEach(0..<maxTranslationSlots, id: \.self) { slot in
    Color.clear
        .translationTask(slotConfig(slot)) { session in
            await viewModel.handleTranslationSession(session, slot: slot)
        }
}
```

- `slotConfig(slot)` returns the slot's `TranslationSession.Configuration?`
- When the config is invalidated (changed), SwiftUI provides a fresh `TranslationSession`
- The session callback calls `handleTranslationSession`, which drains the queue

## Session Start: Model Availability Check

Before creating translation slots, `startSession()` verifies that all active target
languages have installed translation models using
`LanguageAvailability.status(from:to:)`. If any target model is not `.installed`,
the session is aborted with an error message and `prepareTranslationModelIfNeeded()`
triggers a system download dialog for the missing language.

This check uses the **source→target pair** — translation model availability depends
on both the source and target language. The `targetLanguageDownloadStatus` dictionary
(rebuilt by `updateTargetLanguages()` whenever the source changes) tracks this
pair-dependent status.

## Model Preparation (Proactive Download)

A separate `TranslationPreparation` view modifier in `ContentView` attaches a
`.translationTask()` driven by `translationPreparationConfig`. When the user selects
an uninstalled target language, `prepareTranslationModelIfNeeded(for:)` sets this
config, triggering `session.prepareTranslation()` which shows a system download
dialog. After `prepareTranslation()` returns, `session.isReady` is checked to verify
the model was actually installed (since `prepareTranslation()` returns without
prompting if the model is "in the middle of downloading"). Only when `isReady` is
`true` does the cloud icon disappear.

The preparation includes two layers of retry:
1. **Within the session**: If `prepareTranslation()` returns but `isReady=false`,
   retry up to 2 times with a 1-second delay (handles transient daemon failures).
2. **Session creation timeout**: If `.translationTask()` never provides a session
   (daemon crashed before session creation), a 5-second timeout detects this and
   retries by cycling the config through nil→re-set.

**Known issue**: The `translationd` daemon crashes for certain language pairs,
causing the download dialog to flash briefly and disappear. See
`docs/TRANSLATION_MODEL_PROBLEM.md` for details.

## Slot Lifecycle

```
makeTranslationSlots()          ← called on session start
    │
    ├── Creates one TranslationSlot per target language
    ├── Sets config = TranslationSession.Configuration(source:, target:)
    └── SwiftUI detects config → provides TranslationSession
                │
                ▼
handleTranslationSession(session, slot)
    │
    ├── isProcessing = true
    ├── while queue is not empty:
    │       dequeue first item
    │       await translateSentence(...)   ← blocks until API responds
    └── isProcessing = false
```

## Translation Flow

### 1. Partial Translation (real-time preview)

Triggered by each `.partial` transcription event to show work-in-progress translations.

```
.partial event
    │
    ▼
requestPartialTranslation(text)
    │
    ├── for each slot:
    │       requestPartialTranslationForSlot(slot, text)
    │           │
    │           ├── pendingPartialText = text
    │           ├── partialDebounceGeneration += 1
    │           │
    │           └── if no debounce timer running:
    │                   start debounce Task:
    │                       loop: wait partialTranslationDebounce
    │                             if generation changed → re-wait
    │                       enqueuePartialTranslation(slot, text)
    │                           │
    │                           ├── Create "…" placeholder in entry.translations[slot]
    │                           └── enqueueTranslation(slot, item(isPartial: true))
    │
    └── Debounce ensures only the latest partial is translated
        (rapid keystrokes produce one request, not many)
```

### 2. Final Translation (committed sentence)

Triggered when sentence boundary detection commits a sentence.

```
commitSentence(sentence)
    │
    ├── entry.isCommitted = true
    │
    ├── for each slot:
    │       commitSentenceForSlot(slot, idx, sentence)
    │           │
    │           ├── Cancel partialTranslationTimer
    │           ├── Clear pendingPartialText / pendingPartialElapsedTime
    │           ├── Remove queued partial items for this entry  ← prevents wasted API calls
    │           ├── Set placeholder "…" (or keep existing partial text visible)
    │           └── enqueueTranslation(slot, item(isPartial: false))
    │
    └── Carry over pendingPartial to new entry (if exists)
```

### 3. Queue Dispatch

```
enqueueTranslation(slot, item)
    │
    ├── Append item to slot.queue
    │
    └── if not slot.isProcessing:
            slot.config.invalidate()   ← triggers SwiftUI to provide a new session
                                         (or the while loop picks it up if already running)
```

## Partial → Final Transition: Race Condition Prevention

When a sentence is finalized, previously queued partial translations become redundant.
Multiple safeguards prevent wasted work:

### Debounce Timer Cancellation

When a `.finalized` event arrives, all partial debounce timers are cancelled immediately
(`SessionViewModel+Transcription.swift:37-40`). This prevents new partial items from
being enqueued.

### Queue Cleanup on Commit

`commitSentenceForSlot` removes any queued partial items for the same entry before
enqueuing the final request (`SessionViewModel+Translation.swift:145`):

```swift
translationSlots[slot].queue.removeAll { $0.isPartial && $0.entryID == entryID }
```

This handles the case where a partial was already enqueued (past the debounce) but
not yet picked up by the session.

### Result Write Guard

Even if a partial translation is in-flight when the final is enqueued, the result
handler guards against stale writes (`SessionViewModel+Translation.swift:177-179`):

```swift
if isPartial {
    guard existing?.isPartial == true else { return }  // skip if already finalized
}
```

A final translation always overwrites, regardless of what was there before.

### Summary of Defenses

```
Partial request ──┐
                  │  [Debounce timer]  ──── cancelled by finalized event
                  │
                  ▼
           Queue entry     ──── removed by commitSentenceForSlot
                  │
                  ▼
          API call in-flight ── result discarded if entry already finalized
                  │
                  ▼
         Final translation  ── always overwrites (authoritative)
```

## Error Handling

| Error Type | Behavior |
|------------|----------|
| `CancellationError` | Logged, item discarded |
| Translation session cancellation (NSError with "Translation" domain) | Item re-enqueued at front of queue; session will be re-provided by SwiftUI |
| Other errors | For final translations: writes `"[Translation failed]"` placeholder. For partial: silently discarded |

Session cancellation re-enqueue ensures that if the Translation framework tears down
a session (e.g., language model update), pending work is not lost.

## Related Files

| File | Role |
|------|------|
| `Models/TranslationSlot.swift` | TranslationSlot, TranslationQueueItem |
| `ViewModels/SessionViewModel+Translation.swift` | Queue management, translation execution |
| `ViewModels/SessionViewModel+Transcription.swift` | Event handling that feeds the translation pipeline |
| `ViewModels/SessionViewModel+Editing.swift` | Re-translation after manual text edits |
| `ViewModels/SessionViewModel+Languages.swift` | `prepareTranslationModelIfNeeded(for:)` — proactive download trigger |
| `Views/ContentView.swift` | `TranslationTaskSlots` — per-slot `.translationTask()`; `TranslationPreparation` — proactive model download |
