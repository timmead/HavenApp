# Deferred Save in the Tile Configuration Sheet — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `TileConfigView` stops writing as you touch it. Edits are held as drafts and committed once, on dismissal.

**Architecture:** The field's text is already a draft (`@State draft`); what changes is that nothing writes until the sheet closes. A single private `commit()` in the view is the only write path, so plan 4 widens it to carry a size by changing one call rather than by restructuring the sheet. The blank-means-no-override rule moves into `HavenCore` as a pure function, because it is the one part of this with a decision in it.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test`/`#expect`), `xcodegen`.

## Global Constraints

- Haven never renames the Home Assistant entity; the override lives in Haven's dashboard document.
- Every configuration write goes through `HavenConfig.update` — one owner, one writer.
- **Done blocks and surfaces failures**; the sheet stays open when a write fails.
- **Swipe-to-dismiss commits, fire-and-forget** — a dismissed sheet has nowhere to show an error.
- **Remove discards pending edits** — it is immediate and dismisses.
- A commit must happen **exactly once** per sheet, whichever way it closes.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `Packages/HavenCore/Sources/HavenCore/Domain/DisplayName.swift` | Gains `override(from:)` — the draft-text-to-stored-value rule |
| `Packages/HavenCore/Tests/HavenCoreTests/DisplayNameTests.swift` | Tests for that rule |
| `App/Views/TileConfigView.swift` | Draft-and-commit; Save button removed |

---

### Task 1: The rule that turns typed text into a stored override

**Files:**
- Modify: `Packages/HavenCore/Sources/HavenCore/Domain/DisplayName.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/DisplayNameTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `DisplayName.override(from draft: String) -> String?`

- [ ] **Step 1: Write the failing tests**

```swift
/// **Blank is not a name, it is the absence of one.** The sheet's field starts empty for a device
/// nobody has renamed, so "" has to mean "no override" rather than an override to nothing — which
/// would shadow Home Assistant's name with a blank tile caption.
@Test func anEmptyDraftIsNoOverrideAtAll() {
    #expect(DisplayName.override(from: "") == nil)
    #expect(DisplayName.override(from: "   ") == nil)
    #expect(DisplayName.override(from: "\n\t ") == nil)
}

@Test func aDraftIsStoredTrimmed() {
    #expect(DisplayName.override(from: "  Reading Lamp  ") == "Reading Lamp")
    #expect(DisplayName.override(from: "Reading Lamp") == "Reading Lamp")
}

/// Interior spacing is the user's business — only the ends are noise.
@Test func interiorSpacingSurvives() {
    #expect(DisplayName.override(from: " Hall  Light ") == "Hall  Light")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd Packages/HavenCore && swift test --filter DisplayName`
Expected: FAIL — no member `override(from:)`.

- [ ] **Step 3: Implement**

```swift
    /// What a typed draft becomes when stored: trimmed, and `nil` when that leaves nothing.
    ///
    /// **The same rule `resolve` already applies when reading**, stated once for writing so the two
    /// cannot drift. A blank stored override would shadow Home Assistant's name with an empty
    /// caption — a device that looks broken rather than one nobody renamed.
    public static func override(from draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd Packages/HavenCore && swift test --filter DisplayName`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/HavenCore
git commit -m "feat(core): blank is the absence of a name, when writing as well as reading"
```

---

### Task 2: The sheet holds its edits until it closes

**Files:**
- Modify: `App/Views/TileConfigView.swift`

**Interfaces:**
- Consumes: `DisplayName.override(from:)`, `HomeStore.rename(_:to:)`, `HomeStore.setMembership(_:on:to:)`.
- Produces: nothing other tasks depend on. Plan 4 widens `commit()` to carry a size.

- [ ] **Step 1: Replace the Save/Reset row**

Delete the `HStack` holding **Save** and **Reset to Home Assistant's name**, and the `write(_:)`
method. Reset becomes a draft edit rather than a write:

```swift
                    if storedOverride != nil {
                        Button("Reset to Home Assistant's name") { draft = "" }
                            .font(.system(size: 12, weight: .semibold))
                    }
```

Reset now clears the field instead of writing — an empty draft *is* "no override" per Task 1, so the
reset and the commit are the same mechanism rather than two paths to one outcome.

- [ ] **Step 2: Add the single commit path**

```swift
    /// True once this sheet has written, so a dismissal cannot write a second time.
    @State private var committed = false

    /// The one write this sheet performs. Returns whether the sheet may close.
    ///
    /// **Exactly once per sheet, whichever way it closes** — `committed` is what makes that true,
    /// because Done and a swipe both end in `onDisappear`.
    private func commit() async -> Bool {
        guard !committed else { return true }
        guard hasChanges else { committed = true; return true }
        committed = true
        switch await store.rename(entityId, to: DisplayName.override(from: draft)) {
        case .written, .unchanged:
            return true
        case .notAuthorized:
            failure = "Only Home Assistant admins can change the household dashboard."
        case .failed:
            failure = "Couldn't save that. Check your connection and try again."
        }
        // A failed write must not be silently swallowed: the sheet stays open holding the edit, so
        // the next Done can try again.
        committed = false
        return false
    }
```

- [ ] **Step 3: Wire Done, submit, and dismissal**

```swift
                        accessory: AnyView(ModalDoneButton {
                            Task { if await commit() { dismiss() } }
                        }))
```

```swift
                    TextField("Name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                        .onSubmit { Task { if await commit() { dismiss() } } }
```

```swift
        // **Swiping the sheet away commits too**, because there is no Cancel on this screen and
        // discarding a typed name with no warning is a worse outcome than a write the user cannot
        // watch. It is fire-and-forget by necessity: a sheet that has gone has nowhere to put an
        // error. Done is the path that waits and can tell you.
        .onDisappear {
            guard !committed, hasChanges else { return }
            let name = DisplayName.override(from: draft)
            committed = true
            Task { _ = await store.rename(entityId, to: name) }
        }
```

- [ ] **Step 4: Make Remove discard pending edits**

In `remove()`, before dismissing, mark the sheet as committed so `onDisappear` does not then write a
name for a tile that was just taken off the surface:

```swift
    private func remove() async {
        switch await store.setMembership(entityId, on: surface, to: .hidden) {
        // Removing discards whatever was typed: the tile is leaving this surface, and writing a
        // name for it on the way out is work nobody asked for.
        case .written, .unchanged: committed = true; dismiss()
        case .notAuthorized: failure = "Only Home Assistant admins can change the household dashboard."
        case .failed: failure = "Couldn't save that. Check your connection and try again."
        }
    }
```

- [ ] **Step 5: Build and run both suites**

Run:
```bash
xcodebuild -scheme HavenApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
cd Packages/HavenCore && swift test
cd - && xcodebuild test -scheme HavenApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```
Expected: build succeeds, 710 HavenCore tests pass, 97 app tests pass.

- [ ] **Step 6: Render the sheet in both states**

Render preview index 0 and 1 of `HavenApp/App/Views/TileConfigView.swift` and confirm: no **Save**
button; **Reset to Home Assistant's name** present only in the renamed case; the header's **Done**
is the only commit affordance.

- [ ] **Step 7: Commit**

```bash
git add App/Views/TileConfigView.swift
git commit -m "feat(app): the configuration sheet saves once, when it closes"
```

---

## Self-Review

**Spec coverage.** Plan 1's three stated behaviours each have a step: Done blocks and surfaces
failures (Task 2 step 2–3), swipe commits fire-and-forget (step 3), remove discards (step 4). The
spec's "one write, not two" is not yet exercised — there is one field to write until plan 4 adds a
size, and inventing a two-field entry point now would be a wrapper around `rename` with nothing to
combine. The seam that plan 4 needs is `commit()`, and it exists after this plan.

**Placeholders.** None: every step carries the code it changes.

**Type consistency.** `commit() async -> Bool`, `committed`, `hasChanges` and `failure` are used
under those names throughout, and `DisplayName.override(from:)` matches Task 1's signature.
