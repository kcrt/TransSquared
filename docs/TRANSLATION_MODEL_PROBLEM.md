# Translation Model Download Problem

## Summary

`TranslationSession.prepareTranslation()` fails silently for certain language pairs.
The `translationd` XPC daemon crashes (`TranslationErrorDomain Code=14`) during model
preparation, causing the download dialog to flash briefly and disappear without
completing the download. The method does not throw an error — it returns normally
but `session.isReady` remains `false`.

**Observed**: macOS 26.2–26.4 (Tahoe), Xcode 26 beta
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

## Standalone Reproduction (CLI test)

A standalone Swift script (`docs/test_ko_th_translation.swift`) confirms the issue
outside of SwiftUI, eliminating any SwiftUI state change interference.

**Test environment**: macOS 26.4 (Build 25E246), 2026-04-06

### Results

```
--- LanguageAvailability.status() ---
  ✅ Korean → Japanese (control): installed
  ✅ Japanese → Thai (control): installed
  ⚠️ Korean → Thai (problem pair): supported

--- English pivot pairs (all installed) ---
  ✅ Korean → English: installed
  ✅ English → Korean: installed
  ✅ Thai → English: installed
  ✅ English → Thai: installed
  ✅ Japanese → English: installed
  ✅ English → Japanese: installed

--- Translation attempts ---
  [Korean → Japanese]  ✅ "안녕하세요. 오늘 날씨가 좋습니다." → "こんにちは。今日は天気がいいです。"
  [Japanese → Thai]    ✅ "こんにちは。今日はいい天気です。" → "สวัสดี วันนี้เป็นวันที่ดี"
  [Korean → Thai]      ❌ TranslationError(cause: .notInstalled, sourceLanguage: nil, targetLanguage: nil)
                          Error domain: Translation.TranslationError, code: 1
```

### Key findings from CLI test

1. **All six English pivot pairs are `.installed`** — `ko↔en` and `en↔th` both work
2. `ko→th` session creates successfully (`sourceLanguage=ko`, `targetLanguage=th`)
   but `isReady=false`, `canRequestDownloads=false`
3. `translate()` throws `TranslationError.notInstalled` (code 1) — not
   `TranslationErrorDomain Code=14` (the daemon crash seen via `.translationTask()`)
4. Error's `sourceLanguage: nil, targetLanguage: nil` — the error object does not
   populate language fields for `notInstalled` cause (these fields are used for
   language detection errors, not installation errors)
5. This reproduces **without SwiftUI**, ruling out state-change-induced sheet dismissal
   as the sole cause

### Two distinct failure modes

| Context | Session source | Error | Mechanism |
|---------|---------------|-------|-----------|
| SwiftUI `.translationTask()` | Framework-provided | `TranslationErrorDomain Code=14` (daemon crash) | `prepareTranslation()` returns without throwing, `isReady=false` |
| CLI `TranslationSession(installedSource:)` | Direct init | `TranslationError.notInstalled` (code 1) | `translate()` throws because `canRequestDownloads=false` and pair not installed |

The underlying issue is the same — the framework does not recognize `ko→th` as
an installed pair — but the error surfaces differently depending on how the
session was created.

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

> **2026-04-06 Simplification**: The retry/timeout mechanisms (previously mitigations 1–4)
> were removed in favor of a simpler approach. Since manual download from System Settings
> reliably resolves all cases including the `ko→th` bug, the app now attempts
> `prepareTranslation()` once and falls back to directing the user to System Settings.

### 1. Single `prepareTranslation()` attempt

When the user selects a target language, `prepareTranslationModelIfNeeded()` sets
`translationPreparationConfig` to trigger the `.translationTask()` modifier. The handler
calls `session.prepareTranslation()` once. If it succeeds, the model is marked as
installed. If it fails (e.g. daemon crash for `ko→th`), the error is logged and no
retry is attempted. (`SessionViewModel+Languages.swift`, `SessionViewModel+Translation.swift`)

### 2. Session start validation

`startSession()` checks `LanguageAvailability.status(from:to:)` for each target language.
If the status is not `.installed`, the session is blocked with an error message directing
the user to System Settings > General > Language & Region > Translation Languages.
(`SessionViewModel.swift`)

### 3. Status refresh on app activation

When the app becomes active (e.g. after returning from System Settings),
`refreshTranslationInstallStatus()` re-checks `LanguageAvailability.status()` for all
target languages and updates the UI accordingly. (`ContentView.swift`,
`SessionViewModel+Languages.swift`)

## Workaround for Users (Confirmed Working)

If `prepareTranslation()` fails to show the download dialog:

1. Open **System Settings** > **General** > **Language & Region** > **Translation Languages**
2. Download the source language model (e.g., "Korean") manually
3. Return to Trans² and retry

This bypasses `prepareTranslation()` entirely by installing the model at the OS level.

**Confirmed 2026-04-06**: After manually downloading the Korean→Thai model via
System Settings, `LanguageAvailability.status(from: ko, to: th)` changes from
`.supported` to `.installed`, and `translate()` succeeds. This proves that:
- The translation engine itself works correctly for `ko→th`
- Only the `prepareTranslation()` download flow is broken for this pair
- The workaround is reliable

## Root Cause Hypothesis

The `translationd` daemon crashes specifically when preparing the `ko→th` pair.
The crash occurs after the download dialog is presented but before the user can
interact with it. **This is NOT a missing model issue** — both the Korean and
Thai models are installed and functional for other pairs (`ko→ja`, `ja→th`).

This is likely a bug in the Translation framework's **`prepareTranslation()` download
flow** for certain non-trivial pivot combinations. The translation engine itself works
correctly once the model is manually installed via System Settings.

Evidence:
- `ko→ja` works → Korean model is installed and functional
- `ja→th` works → Thai model is installed and functional
- `ko→th` reports `.supported` despite both models being present
- All six English pivot pairs (`ko↔en`, `en↔th`, `ja↔en`) report `.installed`
- `canRequestDownloads=true` confirms the session is properly configured (via `.translationTask()`)
- The dialog briefly appears, proving the UI path is initiated
- The daemon crashes consistently for this pair (Code=14, connection interrupted)
- CLI reproduction (no SwiftUI) also fails with `TranslationError.notInstalled` (code 1)
- **Manual download via System Settings resolves the issue** — `ko→th` translates
  correctly after manual install, confirming the bug is in `prepareTranslation()` only

## Known Issue: State Changes Dismiss the Download Sheet

Apple Developer Forums thread 783311 reports the same symptoms: the download sheet
appears briefly and is immediately dismissed on the first call to `prepareTranslation()`.

**Root cause**: SwiftUI state changes while the Translation framework's download sheet
is being presented cause the sheet to auto-dismiss. The `.translationTask()` modifier
re-evaluates when observed state changes, which can tear down the sheet.

In Trans², potential triggers include:
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

### `TranslationSession(installedSource:target:)` — non-SwiftUI session

- Creates a session without SwiftUI's `.translationTask()` modifier
- `canRequestDownloads` is always `false` — cannot trigger download dialogs
- If the pair is not `.installed`, `translate()` throws `TranslationError.notInstalled`
  (code 1, domain `Translation.TranslationError`)
- The error's `sourceLanguage` and `targetLanguage` fields are `nil` for `notInstalled`
  cause — these fields are only populated for language detection errors
- Useful for testing: confirms whether a pair works without SwiftUI interference

### `LanguageAvailability.status(from:to:)` — pair-dependent

- Returns `.installed`, `.supported`, or `.unsupported`
- Checks availability **per source→target pair**, not per individual language model
- May report `.supported` even when both individual language models are installed
  and functional for other pairs (see the `ko→th` contradiction above)

## Related Files

| File | Role |
|------|------|
| `ViewModels/SessionViewModel+Translation.swift` | Single `prepareTranslation()` call |
| `ViewModels/SessionViewModel+Languages.swift` | `prepareTranslationModelIfNeeded()`, `refreshTranslationInstallStatus()` |
| `ViewModels/SessionViewModel.swift` | Session start validation, error message |
| `Views/ContentView.swift` | `TranslationPreparation` modifier, app-activation refresh |
| `docs/test_ko_th_translation.swift` | Standalone CLI reproduction script |

## Recommendation

File an Apple Feedback report including:
- The `TranslationErrorDomain Code=14` console logs (via `.translationTask()`)
- The `TranslationError.notInstalled` (code 1) error (via `installedSource` init)
- Reproduction steps (`ko_KR→th` via both SwiftUI and CLI)
- CLI reproduction script (`docs/test_ko_th_translation.swift`)
- macOS version: 26.4 (Build 25E246) — also observed on 26.2
- Note that `ja_JP→th` works but `ko_KR→th` does not
- Note that `ko→ja` and `ja→th` both work, proving the individual models are installed
- Note that all six English pivot pairs (`ko↔en`, `en↔th`, `ja↔en`) are `.installed`
- Note that `LanguageAvailability.status(from: ko, to: th)` returns `.supported`
  despite both models being available
- Note that `canRequestDownloads=true` but dialog is dismissed by daemon crash (SwiftUI path)
- Note that this reproduces without SwiftUI, ruling out state-change interference
