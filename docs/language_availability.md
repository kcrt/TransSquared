# Language Model Availability

## Overview

Trans² uses on-device models for both speech recognition and translation.
These models may or may not be downloaded on the user's device. The app checks
download status at startup and displays a cloud icon next to languages that
require a download, so users know before starting a session.

## APIs Used

### Speech Recognition (Source Languages)

| API | Type | Returns |
|-----|------|---------|
| `SpeechTranscriber.supportedLocales` | async | All locales (installed + downloadable) |
| `AssetInventory.status(forModules:)` | async | `.installed`, `.supported`, `.downloading`, or `.unsupported` |

`loadSupportedLocales()` fetches `supportedLocales`, then checks each locale's
actual on-device installation status via `AssetInventory.status(forModules:)` using
a `SpeechTranscriber` configured with the `.timeIndexedProgressiveTranscription`
preset — the same preset used at session start.

> **Why not `SpeechTranscriber.installedLocales`?**
> `installedLocales` is a static property that does not account for the specific
> preset. It may report a locale as installed even when the model required for
> `.timeIndexedProgressiveTranscription` has not been downloaded. This caused a
> mismatch where the UI showed no cloud icon (appears installed) but session start
> failed with `.supported` status (not actually installed for the required preset).
> Using `AssetInventory.status` with the exact module configuration ensures the UI
> and session start use the same source of truth.

### Translation (Target Languages)

| API | Type | Returns |
|-----|------|---------|
| `LanguageAvailability.status(from:to:)` | async | `.installed`, `.supported`, or `.unsupported` |

This is already called for every language in `updateTargetLanguages()` to filter
out unsupported pairs. The status value is now stored instead of discarded.

## State

```swift
// SessionViewModel.swift — Speech model state
var installedSourceLocaleIdentifiers: Set<String> = []
var downloadingSourceLocaleIdentifiers: Set<String> = []

// SessionViewModel.swift — Translation model state
var targetLanguageDownloadStatus: [String: Bool] = [:]  // true = installed
var translationPreparationConfig: TranslationSession.Configuration?
```

- `installedSourceLocaleIdentifiers` — set of locale identifiers (e.g. `"ja_JP"`)
  where the speech recognition model is already downloaded.
- `downloadingSourceLocaleIdentifiers` — set of locale identifiers currently being
  downloaded (used for UI wiggle indicator on the record button).
- `targetLanguageDownloadStatus` — keyed by `Locale.Language.minimalIdentifier`
  (e.g. `"en"`, `"zh-Hans"`). `true` means the translation model is installed
  **for the current source language pair**. Rebuilt when the source language changes.
- `translationPreparationConfig` — a `TranslationSession.Configuration` that triggers
  proactive download via `prepareTranslation()` when set.

## Lifecycle

### Startup

```
ContentView .task
  └── loadSupportedLocales()
        ├── supportedSourceLocales = await SpeechTranscriber.supportedLocales
        ├── installedSourceLocaleIdentifiers = await checkInstalledLocales(...)
        │     └── for each locale:
        │           AssetInventory.status(forModules: [SpeechTranscriber(locale, preset: .timeIndexedProgressiveTranscription)])
        │           → .installed ⇒ add to set
        └── updateTargetLanguages()
              └── for each supported target:
                    status = await availability.status(from:to:)
                    targetLanguageDownloadStatus[id] = (status == .installed)
```

### Session Stop

```
stopSession()
  └── refreshSourceLocaleInstallStatus()
        └── installedSourceLocaleIdentifiers = await checkInstalledLocales(...)
              └── (same AssetInventory.status check as startup)
```

Models may have been downloaded during the session (the `TranscriptionManager`
calls `AssetInventory.assetInstallationRequest` which triggers automatic
download). Refreshing after session stop ensures the cloud icon disappears.

### Translation Session Provided

```
handleTranslationSession(session, slot)
  └── targetLanguageDownloadStatus[langId] = true
```

When SwiftUI's `.translationTask()` provides a `TranslationSession`, the model
is guaranteed to be available. The status is updated immediately so the cloud
icon disappears without waiting for a full refresh.

## UI Indicator

`CheckmarkLabel` (in `HelperViews.swift`) has an `isDownloaded` parameter:

```swift
struct CheckmarkLabel: View {
    let title: String
    let isSelected: Bool
    var isDownloaded: Bool = true
    var isDownloading: Bool = false

    var body: some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else if isDownloading {
            Label(title, systemImage: "arrow.down.circle")
        } else if !isDownloaded {
            Label(title, systemImage: "icloud.and.arrow.down")
        } else {
            Text(title)
        }
    }
}
```

- Selected language: checkmark
- Downloading: `arrow.down.circle` SF Symbol (used for speech models being downloaded)
- Not downloaded: `icloud.and.arrow.down` SF Symbol
- Downloaded but not selected: plain text

Additionally, when a speech model is downloading for the currently selected source
language, the record button itself switches to an `arrow.down.circle` icon with a
wiggle animation (`.symbolEffect(.wiggle.byLayer)`). Clicking the button during
this state cancels the download visually.

This is used in both the toolbar menus (`ContentView+Toolbar.swift`) and the
menu bar commands (`MenuCommands.swift`).

## Download Behavior

### Source Languages (Speech)

**On language selection**: When the user selects an undownloaded source language,
`downloadSpeechAssetsIfNeeded(for:)` fires a background `Task.detached` that
calls `AssetInventory.assetInstallationRequest(supporting:).downloadAndInstall()`.
This downloads the model silently — no system dialog is shown. On completion,
`installedSourceLocaleIdentifiers` is updated and the cloud icon disappears.

The system consolidates redundant download requests, so calling this multiple
times or concurrently with the session-start path is safe.

**On session start**: `startSession()` checks `AssetInventory.status(forModules:)`
before proceeding. If the model is not yet installed, the session is aborted
with a user-visible error message:

| Status | Behavior |
|--------|----------|
| `.installed` | Session proceeds normally |
| `.downloading` | Error: "Speech recognition model is still downloading. Please wait and try again." |
| `.supported` | Error: "Speech recognition model is not installed." + triggers background download |
| `.unsupported` | Error: "Speech recognition is not supported for this language." |

This replaces the previous behavior where `TranscriptionManager.start()` would
block the session start while downloading. The download now happens earlier
(at language selection time), and the session start simply validates readiness.

### Target Languages (Translation)

**On language selection**: When the user selects an undownloaded target language,
`prepareTranslationModelIfNeeded(for:)` sets `translationPreparationConfig` with
the current source→target pair. This triggers a `.translationTask()` modifier in
`ContentView` (via `TranslationPreparation`), which calls
`session.prepareTranslation()`. The system presents a download confirmation dialog.
On completion, `targetLanguageDownloadStatus[langId]` is set to `true`.

**On session start**: `startSession()` checks `LanguageAvailability.status(from:to:)`
for every active target language (source→target pair). If any target is not
`.installed`, the session is aborted with an error message directing the user to
System Settings > General > Language & Region > Translation Languages.

| Status | Behavior |
|--------|----------|
| `.installed` | Session proceeds normally |
| `.supported` | Error: "Translation model for X is not installed." with System Settings guidance |
| `.unsupported` | Filtered out by `updateTargetLanguages()`, should not occur |

**Important**: Translation availability is **pair-dependent** — a model installed
for `ja→en` does not imply `zh→en` is installed. The `targetLanguageDownloadStatus`
dictionary reflects the current source language and is rebuilt whenever the source
changes (via `updateTargetLanguages()`).

Note the difference: Speech framework downloads are silent (no UI), while
Translation framework downloads show a system confirmation dialog via
`prepareTranslation()`.

### Translation Preparation Session

```
handleTranslationPreparationSession(session)
  └── session.prepareTranslation()   ← shows system download dialog if needed
        ├── success: targetLanguageDownloadStatus[langId] = true
        └── failure: log error (user can install manually from System Settings)
  └── translationPreparationConfig = nil
```

A separate `.translationTask()` modifier (`TranslationPreparation` in `ContentView`)
is dedicated to proactive model preparation. It is driven by
`translationPreparationConfig` and is independent of the per-slot translation tasks.

If `prepareTranslation()` fails (e.g. `translationd` daemon crash for certain language
pairs like `ko→th`), the user can install models manually from System Settings >
General > Language & Region > Translation Languages. See
`docs/TRANSLATION_MODEL_PROBLEM.md` for details on known daemon crash issues.

### App Activation Refresh

```
ContentView .onReceive(NSApplication.didBecomeActiveNotification)
  └── refreshTranslationInstallStatus()
        └── for each supported target:
              status = await availability.status(from:to:)
              targetLanguageDownloadStatus[id] = (status == .installed)
```

When the user returns from System Settings after installing a translation model,
the app refreshes `targetLanguageDownloadStatus` so the cloud icon disappears
and the session start check passes.

## Related Files

| File | Role |
|------|------|
| `ViewModels/SessionViewModel.swift` | `installedSourceLocaleIdentifiers`, `downloadingSourceLocaleIdentifiers`, `targetLanguageDownloadStatus`, `translationPreparationConfig`, `loadSupportedLocales()`, `refreshSourceLocaleInstallStatus()`, `startSession()` speech + translation asset checks |
| `ViewModels/SessionViewModel+Languages.swift` | `updateTargetLanguages()` — stores translation model status; `downloadSpeechAssetsIfNeeded(for:)` — triggers speech download; `prepareTranslationModelIfNeeded(for:)` — triggers translation preparation; `refreshTranslationInstallStatus()` — refreshes translation model status on app activation |
| `ViewModels/SessionViewModel+Translation.swift` | `handleTranslationSession()` — marks language as installed; `handleTranslationPreparationSession()` — single `prepareTranslation()` call |
| `Views/ContentView.swift` | `TranslationTaskSlots` — per-slot `.translationTask()` for actual translations; `TranslationPreparation` — `.translationTask()` for proactive model download; app-activation refresh |
| `Views/HelperViews.swift` | `CheckmarkLabel` — cloud icon rendering |
| `Views/ContentView+Toolbar.swift` | Toolbar language pickers with `isDownloaded`, triggers speech/translation download on selection |
| `Views/MenuCommands.swift` | Menu bar language menus with `isDownloaded`, triggers speech/translation download on selection |
| `Services/TranscriptionManager.swift` | `AssetInventory` download (legacy fallback, still present) |
