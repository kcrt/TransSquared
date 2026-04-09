# SwiftUI LazyVStack Freeze: Per-Row Interactive Modifiers

**Date**: 2026-04-09
**Affected file**: `TranscriptPaneView.swift`
**Symptom**: Main thread freeze during recording sessions (UI completely unresponsive)

## Root Causes

Two per-row modifiers inside a `LazyVStack` independently caused the app to freeze:

### 1. `.onHover` (primary)

During scrolling, macOS fires rapid hover enter/exit events as items pass under the
cursor. Each event mutated `@State hoveredLineID`, which triggered a SwiftUI re-render
**during the scroll layout pass**. This created an infinite layout invalidation loop in
SwiftUI's internal `AG::Graph::UpdateStack::update`.

### 2. `.textSelection(.enabled)` (secondary)

`.textSelection(.enabled)` on each `Text` view creates an `NSTextView`-backed
interaction area per row. In a `LazyVStack`, these are created and destroyed during
scrolling — the same class of problem as `.onHover`. Even after removing `.onHover`,
the freeze persisted until `.textSelection(.enabled)` was also removed.

### Why LazyVStack makes this worse

`LazyVStack` creates and destroys views on demand during scrolling. Each newly created
view registers interactive backing state (`NSTrackingArea` for `.onHover`,
`NSTextView` for `.textSelection`). As items scroll past the cursor, these trigger
layout invalidation mid-pass.

A regular `VStack` would not exhibit this behavior as severely because all views exist
at all times and their backing state is stable.

## Diagnostic Process

The freeze was identified through **binary-search elimination** of view features:

1. Full `TranscriptPaneView` → **freeze**
2. Stripped to minimal `ScrollView > VStack > ForEach > Text` → **no freeze**
3. Restored `LazyVStack` + `.defaultScrollAnchor(.bottom)` + simple `Text` → **no freeze**
4. Restored full `lineRow` without `timestampColumn` → **no freeze** during data updates, but **freeze on manual scroll**
5. Restored `timestampColumn` (which contained `.onHover`) → **freeze on scroll**
6. Removed `.onHover` → **no freeze**

Key log evidence: `captureOutput` continued running on background threads while the
main thread was stuck in `TranscriptPaneView body START`, confirming the freeze was
in SwiftUI's view rendering/layout, not in audio processing.

## Fixes Applied

### Fix 1: Remove `.onHover` per-row (ROOT CAUSE)

Removed `@State private var hoveredLineID` and all `.onHover` modifiers from row views.
The play button is now always visible when a row is highlighted (via `isHighlighted`),
rather than appearing only on hover.

### Fix 2: `TranscriptLine: Equatable`

Added `Equatable` conformance to `TranscriptLine` to enable meaningful array comparison.

### Fix 3: Equality guard in `recomputeDisplayLines()`

`@Observable` triggers observation on **any property write**, even if the new value is
identical to the old one. Added explicit equality checks before assigning
`sourceLines` and `translationLinesPerSlot`:

```swift
if newSourceLines != sourceLines { sourceLines = newSourceLines }
if newTranslationLines != translationLinesPerSlot { translationLinesPerSlot = newTranslationLines }
```

This prevents unnecessary SwiftUI observation cascades when transcript data hasn't
actually changed.

### Fix 4: Replace `ScrollViewReader` + `scrollTo` with `.defaultScrollAnchor(.bottom)`

The imperative `ScrollViewReader` + `withAnimation { scrollTo }` approach was replaced
with the declarative `.defaultScrollAnchor(.bottom)` modifier, which lets SwiftUI
handle auto-scrolling without triggering additional layout passes.

### Fix 5: Remove `.textSelection(.enabled)` per-row

Removed `.textSelection(.enabled)` from per-row `Text` views inside the `LazyVStack`.
This modifier creates `NSTextView`-backed interaction areas for every row, causing the
same layout invalidation cascades as `.onHover` during scrolling on macOS.

## Lessons Learned

1. **Avoid per-row interactive modifiers in `LazyVStack` on macOS**: `.onHover`,
   `.textSelection(.enabled)`, and similar modifiers that create per-view backing state
   (`NSTrackingArea`, `NSTextView`) can cause layout invalidation loops during scrolling.

2. **`@Observable` is write-sensitive, not value-sensitive**: Always guard property
   assignments with equality checks to avoid spurious observation triggers.

3. **Binary-search elimination** is an effective strategy for diagnosing SwiftUI freezes:
   strip the view to a minimum, then add features back one at a time.

4. **Check background threads to confirm main-thread freeze**: If audio capture or other
   background work continues while UI is frozen, the issue is in the UI layer.
