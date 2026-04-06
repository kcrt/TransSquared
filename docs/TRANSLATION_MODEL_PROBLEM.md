# Translation Model Download Problem

## Summary

`TranslationSession.prepareTranslation()` fails silently for certain language pairs.
The `translationd` XPC daemon crashes (`TranslationErrorDomain Code=14`) during model
preparation, causing the download dialog to flash briefly and disappear without
completing the download. The method does not throw an error — it returns normally
but `session.isReady` remains `false`.

**Observed**: macOS 26.2 (Tahoe), Xcode 26 beta
**Affected pair (confirmed)**: `ko_KR→th` (Korean → Thai)
**Working pair (confirmed)**: `ja_JP→th` (Japanese → Thai)

## Model Architecture

Apple's Translation framework likely uses an **English-pivot (hub-and-spoke)**
architecture internally, but the exact details are not publicly documented.

```
ja → (en) → th     (Japanese → Thai)
ko → (en) → th     (Korean → Thai)
ko → (en) → ja     (Korean → Japanese)
```

- `LanguageAvailability.status(from:to:)` checks availability **per pair**
- Models appear to be downloaded per-language in System Settings
  (Settings > General > Language & Region > Translation Languages)

### Contradiction: individual models installed but pair unavailable

Testing reveals a contradiction in the pivot hypothesis:

| Pair | `LanguageAvailability.status()` | Translation | Notes |
|------|--------------------------------|-------------|-------|
| `ko→ja` | `.installed` | Works | Korean model is functional |
| `ja→th` | `.installed` | Works | Thai model is functional |
| `ko→th` | `.supported` | **Fails** | Both models should be available via pivot |

If English pivot is used, `ko→th` would require `ko⇔en` + `en⇔th` — both of which
should be installed (proven by `ko→ja` and `ja→th` working). Yet
`LanguageAvailability.status(from: ko, to: th)` reports `.supported`, and
`prepareTranslation()` crashes the `translationd` daemon.

This suggests the issue is NOT about missing models but rather a **framework bug
in pair management or model composition** for `ko→th` specifically.

## Observed Behavior

### Working case: `ja_JP→th`

```
1. User selects Thai as target (source = Japanese)
2. prepareTranslationModelIfNeeded("th") sets translationPreparationConfig
3. .translationTask() fires → TranslationSession provided
4. handleTranslationPreparationSession called
   → isReady=false, canRequestDownloads=true
5. session.prepareTranslation() called
   → System download dialog appears
   → User approves → model downloads
6. session.isReady = true ✓
7. targetLanguageDownloadStatus["th"] = true ✓
8. LanguageAvailability.status(from: ja, to: th) = .installed ✓
9. Session starts successfully ✓
```

### Failing case: `ko_KR→th`

```
1. User selects Thai as target (source = Korean)
2. prepareTranslationModelIfNeeded("th") sets translationPreparationConfig
3. .translationTask() fires → TranslationSession provided
4. handleTranslationPreparationSession called
   → isReady=false, canRequestDownloads=true
5. session.prepareTranslation() called
   → Download dialog appears BRIEFLY then disappears
   → "Connection interrupted, TranslationErrorDomain Code=14"
   → "Reported that remote UI finished but didn't get finished configuration"
   → prepareTranslation() returns WITHOUT throwing
6. session.isReady = false ✗
7. Retry (attempt 2): same result ✗
8. targetLanguageDownloadStatus["th"] remains false
9. LanguageAvailability.status(from: ko, to: th) = .supported (never becomes .installed) ✗
10. Session start blocked with error ✗
```

### Key observations

- `canRequestDownloads=true` in both cases — the session CAN request downloads
- The dialog appears briefly for `ko→th` but the daemon crashes before user interaction
- `prepareTranslation()` does NOT throw — it returns normally despite the failure
- The error appears only in system console logs, not as a thrown Swift error
- The retry mechanism works (attempt 2 fires) but hits the same daemon crash

## Error Details

```
Connection interrupted, finishing translation with error
    Error Domain=TranslationErrorDomain Code=14 "(null)"

Got response from extension with error:
    Error Domain=TranslationErrorDomain Code=14 "(null)"

Reported that remote UI finished but didn't get finished configuration,
    reporting the error as: Error Domain=TranslationErrorDomain Code=14 "(null)"
```

- **Code=14** is not publicly documented by Apple
- The "Connection interrupted" indicates an XPC connection failure to the `translationd` daemon
- "Remote UI finished but didn't get finished configuration" suggests the download sheet
  was torn down before configuration could complete

## App-Side Mitigations

### 1. `session.isReady` verification

After `prepareTranslation()` returns, `session.isReady` is checked to prevent falsely
marking the model as installed. (`SessionViewModel+Translation.swift`)

### 2. Retry within preparation session

If `prepareTranslation()` returns but `isReady=false`, the handler retries up to 2 times
with a 1-second delay. (`SessionViewModel+Translation.swift`)

### 3. Timeout-based retry for session creation

If the `.translationTask()` closure never fires (daemon crashes before providing a
session), a timeout task detects this after 5 seconds, clears the config, and retries
once. (`SessionViewModel+Languages.swift`)

### 4. `targetLanguageDownloadStatus` fallback in `startSession()`

`startSession()` checks `LanguageAvailability.status(from:to:)` but also trusts
`targetLanguageDownloadStatus` if a preparation session previously confirmed readiness
via `isReady`. This handles cases where the API reports `.supported` but the model
is actually usable (shared models). (`SessionViewModel.swift`)

### 5. Error message with manual download guidance

When `startSession()` blocks due to an uninstalled translation model, the error message
directs the user to System Settings > General > Language & Region > Translation Languages
as a manual download fallback. (`SessionViewModel.swift`)

## Workaround for Users

If `prepareTranslation()` fails to show the download dialog:

1. Open **System Settings** > **General** > **Language & Region** > **Translation Languages**
2. Download the source language model (e.g., "Korean") manually
3. Return to TransTrans and retry

This bypasses `prepareTranslation()` entirely by installing the model at the OS level.

## Root Cause Hypothesis

The `translationd` daemon crashes specifically when preparing the `ko→th` pair.
The crash occurs after the download dialog is presented but before the user can
interact with it. **This is NOT a missing model issue** — both the Korean and
Thai models are installed and functional for other pairs (`ko→ja`, `ja→th`).

This is likely a bug in the Translation framework's pair composition logic or
XPC communication for certain non-trivial pivot combinations.

Evidence:
- `ko→ja` works → Korean model is installed and functional
- `ja→th` works → Thai model is installed and functional
- `ko→th` reports `.supported` despite both models being present
- `canRequestDownloads=true` confirms the session is properly configured
- The dialog briefly appears, proving the UI path is initiated
- The daemon crashes consistently for this pair (Code=14, connection interrupted)

## Known Issue: State Changes Dismiss the Download Sheet

Apple Developer Forums thread 783311 reports the same symptoms: the download sheet
appears briefly and is immediately dismissed on the first call to `prepareTranslation()`.

**Root cause**: SwiftUI state changes while the Translation framework's download sheet
is being presented cause the sheet to auto-dismiss. The `.translationTask()` modifier
re-evaluates when observed state changes, which can tear down the sheet.

In TransTrans, potential triggers include:
- `targetLanguageIdentifiers[slot] = ...` immediately before `prepareTranslationModelIfNeeded()`
  in toolbar/menu button handlers
- `errorMessage = "..."` immediately before `prepareTranslationModelIfNeeded()` in `startSession()`
- `translationPreparationConfig` nil→non-nil cycling in `prepareTranslationModelIfNeeded()`

**Forum workaround**: Use separate `TranslationSession.Configuration` objects for
download checking vs. actual translation, and avoid state changes concurrent with
the sheet presentation.

**Reference**: https://developer.apple.com/forums/thread/783311

## API Behavior Notes

### `prepareTranslation()` — undocumented failure mode

Apple documentation states:
> If the languages are already installed or in the middle of downloading,
> the function returns without prompting them.

What is NOT documented:
- The function also returns without throwing when the `translationd` daemon crashes
- There is no way to distinguish "model already available" from "daemon crashed"
  without checking `session.isReady` (macOS 26+)

### `translate()` as alternative

`translate()` also handles model downloads:
> If the source or target language aren't installed, the framework asks the person
> for permission to download the languages.

However, using `translate()` as a fallback during active transcription would cause
repeated download dialogs for each translation request, which is unacceptable UX.

### `LanguageAvailability.status(from:to:)` — pair-dependent

- Returns `.installed`, `.supported`, or `.unsupported`
- Checks availability **per source→target pair**, not per individual language model
- May report `.supported` even when both individual language models are installed
  and functional for other pairs (see the `ko→th` contradiction above)

## Related Files

| File | Mitigation |
|------|------------|
| `ViewModels/SessionViewModel+Translation.swift` | `isReady` check, retry within session |
| `ViewModels/SessionViewModel+Languages.swift` | Timeout-based retry, config cycling |
| `ViewModels/SessionViewModel.swift` | `targetLanguageDownloadStatus` fallback, error message |
| `Views/ContentView.swift` | `TranslationPreparation` modifier |

## Recommendation

File an Apple Feedback report including:
- The `TranslationErrorDomain Code=14` console logs
- Reproduction steps (`ko_KR→th` via `prepareTranslation()`)
- macOS version and device info
- Note that `ja_JP→th` works but `ko_KR→th` does not
- Note that `ko→ja` and `ja→th` both work, proving the individual models are installed
- Note that `LanguageAvailability.status(from: ko, to: th)` returns `.supported`
  despite both models being available
- Note that `canRequestDownloads=true` but dialog is dismissed by daemon crash
