# Room Subsections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rooms render as per-domain subsection containers on both surfaces — sized and arranged by
household choice (scroll or wrap), hidden when empty — per
`docs/superpowers/specs/2026-08-15-room-subsections-design.md`. Read that spec before starting any
task; its "Decisions" section is settled and not to be re-litigated.

**Architecture:** Policy in HavenCore under test (`SubsectionKind`, `SubsectionMode`,
`Subsections.resolve`, document accessors); one new App container (`SubsectionView`) consumed by
both surfaces; existing tile renderers untouched. Tasks 1–3 are Core and fully specified. Tasks
4–7 are App-layer; their *interfaces* are fixed here, and each begins by reading the files it
modifies — the code blocks given are the target shape, not blind patches.

**Tech Stack:** Swift 6.0 (strict concurrency `complete`), iOS 26, SwiftUI + Observation, Swift
Testing, XcodeGen, no third-party dependencies.

## Global Constraints

- **Policy lives in HavenCore under test; `App/` glues and renders.** No `import SwiftUI`/`UIKit`
  in the package.
- **Comment loss is a failing check.** Moved code keeps its comments; the bucketing switch moves
  *verbatim* with its rationale.
- **A new test is not finished until it has been watched to fail.** Break the code, watch red,
  restore from a **file copy** (`cp` a backup first — `git checkout` destroys uncommitted work),
  report the mutation. Three prior incidents in this repo of green tests proving nothing.
- **Both suites green before every commit:**
  `swift test --package-path Packages/HavenCore` (baseline 800) and
  `xcodebuild test -scheme HavenApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
  (baseline 111). If the simulator wedges ("Early unexpected exit", "signal kill"):
  `pkill -9 -f HavenApp; pkill -9 -f xctest; xcrun simctl shutdown all`, retry once.
- **One task per commit.** Adding files under `App/` or `Tests/` requires `xcodegen generate`.
- **Swift Testing only** (`import Testing`, `@Suite`, `@Test`, `#expect`). Tests never touch the
  real Keychain or `UserDefaults.standard` (hosted test bundle) — use `makeTestDefaults()` /
  `FakeTokenStore` from `Tests/HavenAppTests/Fakes.swift`.
- Commit messages in the repo voice: lowercase, prose, the user-visible truth. End with
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `SubsectionKind` and `SubsectionMode` in Core

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Curation/Subsection.swift`
- Modify: `App/Views/RoomDetailView.swift` (delete the `Grouped` struct + `grouped` property; see Step 4)
- Test: `Packages/HavenCore/Tests/HavenCoreTests/SubsectionTests.swift`

**Interfaces (produced, relied on by every later task):**

```swift
public enum SubsectionKind: String, CaseIterable, Sendable {
    case climate, lights, shades, media, cameras, other, sensors

    public var displayName: String   // "Scenes & more" for .other
    public static func of(_ primaryEntityId: String) -> SubsectionKind
    public func defaultSpan(on surface: HavenSurface) -> TileSpan
    public var availableSpans: [TileSpan]
}

public enum SubsectionMode: String, Sendable, Codable {
    case scroll, wrap
}
```

- [ ] **Step 1: Write the failing tests** in `SubsectionTests.swift`:

```swift
import Foundation
import Testing
@testable import HavenCore

// The bucketing rule: which subsection an entity's primary lands in. Moved from
// `RoomDetailView.grouped`, where nothing could test it.
@Test func everyDomainBucketsWhereTheDetailViewPutIt() {
    #expect(SubsectionKind.of("climate.hall") == .climate)
    #expect(SubsectionKind.of("light.kitchen") == .lights)
    #expect(SubsectionKind.of("cover.blind") == .shades)
    #expect(SubsectionKind.of("media_player.tv") == .media)
    #expect(SubsectionKind.of("camera.front") == .cameras)
    #expect(SubsectionKind.of("scene.movie") == .other)
    #expect(SubsectionKind.of("script.night") == .other)
    #expect(SubsectionKind.of("lock.front") == .other)
    #expect(SubsectionKind.of("switch.pump") == .other)
    #expect(SubsectionKind.of("sensor.temp") == .sensors)
    #expect(SubsectionKind.of("binary_sensor.door") == .sensors)
    #expect(SubsectionKind.of("garbage.x") == .other)   // Domain.unknown
}

/// Default spans are exactly today's `TileSpan.default` values, so an unconfigured document
/// renders exactly today's proportions — the spec's compatibility promise.
@Test func defaultSpansMatchTheDomainDefaultsTheyReplace() {
    for surface in HavenSurface.allCases {
        #expect(SubsectionKind.climate.defaultSpan(on: surface) == TileSpan.default(for: .climate, on: surface))
        #expect(SubsectionKind.lights.defaultSpan(on: surface) == TileSpan.default(for: .light, on: surface))
        #expect(SubsectionKind.shades.defaultSpan(on: surface) == TileSpan.default(for: .cover, on: surface))
        #expect(SubsectionKind.media.defaultSpan(on: surface) == TileSpan.default(for: .mediaPlayer, on: surface))
        #expect(SubsectionKind.cameras.defaultSpan(on: surface) == TileSpan.default(for: .camera, on: surface))
        #expect(SubsectionKind.other.defaultSpan(on: surface) == TileSpan(columns: 1, rows: 1))
        #expect(SubsectionKind.sensors.defaultSpan(on: surface) == TileSpan(columns: 1, rows: 1))
    }
}

/// The size picker's option list per kind. Every offered span must be drawable by the kind's
/// *most capable* member (`TileSpan.available`), because subsection sizing is uniform: a kind
/// whose members disagree offers only what the least capable can occupy without a bespoke
/// rendering — the existing smallest-rendering fallback covers the rest.
@Test func offeredSpansComeFromTheMembersRealRenderings() {
    #expect(SubsectionKind.lights.availableSpans == [TileSpan(columns: 1, rows: 1)])
    #expect(SubsectionKind.other.availableSpans == [TileSpan(columns: 1, rows: 1)])
    #expect(SubsectionKind.sensors.availableSpans == TileSpan.available(for: .sensor))
    #expect(SubsectionKind.climate.availableSpans == TileSpan.available(for: .climate))
    #expect(SubsectionKind.media.availableSpans == TileSpan.available(for: .mediaPlayer))
    #expect(SubsectionKind.cameras.availableSpans == TileSpan.available(for: .camera))
}

@Test func storedRawValuesAreTheSchemaVocabulary() {
    #expect(SubsectionKind.allCases.map(\.rawValue)
            == ["climate", "lights", "shades", "media", "cameras", "other", "sensors"])
    #expect(SubsectionMode.scroll.rawValue == "scroll")
    #expect(SubsectionMode.wrap.rawValue == "wrap")
}
```

- [ ] **Step 2: Run** `swift test --package-path Packages/HavenCore` — expect compile failure
  (`SubsectionKind` unknown). That is RED-by-absence; the behavioural mutation check comes in
  Step 5.

- [ ] **Step 3: Implement** `Subsection.swift`. The bucketing switch is `RoomDetailView.grouped`'s,
  moved **verbatim including its comments** (the composite-buckets-by-primary note and the
  camera-has-no-1-column note). `of(_:)` switches on `Domain.of(id)` exhaustively, no `default`.
  `defaultSpan(on:)` delegates to `TileSpan.default(for:on:)` for kinds with one governing domain
  and returns 1×1 for `.other`/`.sensors`. `availableSpans` delegates to `TileSpan.available(for:)`
  per the test. `displayName`: Climate, Lights, Shades, Media, Cameras, Scenes & more, Sensors.

- [ ] **Step 4: Delete `RoomDetailView.Grouped`/`grouped`** and rebuild that view's `body` groups on
  `SubsectionKind.of(_:)` — minimal change: `grouped.climate` becomes a local
  `bucket(.climate)` helper filtering `room.refs(for: .roomDetail)` by kind. (The full subsection
  rendering replaces this in Task 5; this step only removes the duplicated switch so it cannot
  drift against Core's.) Run the app suite.

- [ ] **Step 5: Mutation check.** `cp` a backup of `Subsection.swift`; change `.cover`'s bucket to
  `.other`; expect `everyDomainBucketsWhereTheDetailViewPutIt` red. Restore from the backup, re-run
  green. Record the observed failure.

- [ ] **Step 6: Both suites, then commit:** `feat(core): which subsection a device belongs to is now a tested fact`

### Task 2: Document accessors and mutators for subsections

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Config/SubsectionConfig.swift` (extension on `DashboardDocument`)
- Test: `Packages/HavenCore/Tests/HavenCoreTests/SubsectionConfigTests.swift`

**Interfaces:**

```swift
extension DashboardDocument {
    public var displayMode: SubsectionMode?                       // "display": {"mode": …}
    public func subsectionSpan(_ kind: SubsectionKind) -> TileSpan?
    public func subsectionMode(_ kind: SubsectionKind) -> SubsectionMode?
    public func settingDisplayMode(_ mode: SubsectionMode?) -> DashboardDocument
    public func settingSubsectionSpan(_ span: TileSpan?, kind: SubsectionKind) -> DashboardDocument
    public func settingSubsectionMode(_ mode: SubsectionMode?, kind: SubsectionKind) -> DashboardDocument
}
```

- [ ] **Step 1: Write the failing tests.** Follow `DashboardDocumentTests`' existing style
  (round-trip through raw `JSONValue`). Must cover: set-then-read for all three; `nil` clears the
  key rather than writing null; unknown keys elsewhere in the document survive a subsection write
  (the merge-discipline test every mutator here has); a garbage `size` string reads as `nil`; a
  document written by this build stamps `schema`.

- [ ] **Step 2: Run to see them fail** (compile failure on the missing extension).

- [ ] **Step 3: Implement**, modelled line-for-line on `settingDevice`/`devices`
  (`DashboardDocument.swift:343-380`): read `raw.asObject`, merge only the owned subtree, stamp
  `schemaKey`, never touch unknown keys. Private keys: `"display"`, `"subsections"`, `"size"`,
  `"mode"`.

- [ ] **Step 4: Mutation check** — make `settingSubsectionSpan` drop unknown sibling keys inside
  `subsections`; the merge-discipline test must go red. Restore from file copy.

- [ ] **Step 5: Both suites, commit:** `feat(core): the household document can say how a subsection displays`

### Task 3: The resolver, and the store's join

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Curation/SubsectionResolver.swift`
- Modify: `App/HomeStore.swift` (add the forwarding join beside `device(_:)`)
- Test: `Packages/HavenCore/Tests/HavenCoreTests/SubsectionResolverTests.swift`,
  `Tests/HavenAppTests/ObservationTests.swift` (one new case)

**Interfaces:**

```swift
public struct RoomSubsection: Sendable, Equatable, Identifiable {
    public let kind: SubsectionKind
    public let refs: [DeviceRef]
    public let span: TileSpan
    public let mode: SubsectionMode
    public var id: String { kind.rawValue }
}

public enum Subsections {
    /// Pure function of its inputs, same shape as RegistryResolver. Consumes
    /// `room.refs(for: surface)` so membership, tiers, and per-room order keep working untouched.
    public static func resolve(room: RoomSection, surface: HavenSurface,
                               document: DashboardDocument) -> [RoomSubsection]
}

// App/HomeStore.swift — beside device(_:), same observation rationale:
func subsections(_ room: RoomSection, on surface: HavenSurface) -> [RoomSubsection] {
    Subsections.resolve(room: room, surface: surface, document: config.document)
}
```

- [ ] **Step 1: Failing tests.** Build a `RoomSection` fixture (mixed domains + one composite whose
  primary is a cover) and cover: empty kinds dropped; output in fixed kind order (climate, lights,
  shades, cameras, media, other, sensors — **note: cameras before media**, the approved order,
  which is *not* `CaseIterable` order; assert it explicitly); refs preserve `refs(for:)` sequence
  within a kind (per-room order intact); mode chain `subsection → display → .scroll` (three tests,
  one per link); span chain `subsection → defaultSpan(on:)` including the media/camera per-surface
  defaults; composite bucketed by primary.
- [ ] **Step 2: Run, watch red** (compile absence). **Step 3: Implement** — a single pass over
  `room.refs(for: surface)` into `[SubsectionKind: [DeviceRef]]`, then map the fixed order.
- [ ] **Step 4: Mutation check** — swap the fixed order's cameras/media; the order test must red.
  Restore from copy.
- [ ] **Step 5: The ObservationTests case:** reading `store.subsections(room, on: .overview)`
  must register dependencies on `config.document`'s storage. Follow the file's existing
  `withObservationTracking` pattern; include its negative control. Watch it fail by pointing the
  join at a captured document copy first.
- [ ] **Step 6: Both suites, commit:** `feat: a room resolves into its subsections, in Core`

### Task 4: `SubsectionView`, gallery-first

**Files:**
- Create: `App/Renderers/SubsectionView.swift`
- Modify: `App/Renderers/TileGallery.swift` (new fixtures page),
  `App/Navigation.swift` (add `case subsectionConfig(kind: SubsectionKind)` to `Presentation` —
  here, not Task 5, because this view's configure-mode header references it and must compile;
  `DashboardView`'s sheet `switch` gets a temporary `EmptyView` arm until Task 6 supplies the real
  sheet). `project.yml` untouched — run `xcodegen generate` after the file add.

**Interfaces (consumed by Task 5):**

```swift
enum SubsectionDensity { case regular, compact }

struct SubsectionView: View {
    let room: RoomSection            // for rollup dispatch + add flow context
    let subsection: RoomSubsection
    /// **Added in Task 4, not in this plan as written.** `DeviceTileView(entityId:surface:span:)`
    /// requires a surface and `ConfigurableTile` uses it for "remove from *this* surface", so it
    /// cannot be derived from `density` without letting a styling axis decide a membership fact.
    let surface: HavenSurface
    let density: SubsectionDensity
    /// Configure mode forces wrap (spec decision 8); the view reads Navigation.isConfiguring
    /// itself and derives the effective mode.
    /// **Added in Task 5:** `@State private var drag: TileDragState`, with a memberwise-shaped
    /// `init(room:subsection:surface:density:drag:)` whose `drag` defaults — the injectability
    /// `RoomSectionView` had, moved down with the state. Existing call sites are unaffected.
}
```

`RoomGrid` gained `columnWidth(inContainerOfWidth:)`, `width(for:inContainerOfWidth:)` and
`unmeasuredHeight(for:)` in Task 4: the cell arithmetic was inside `placeSubviews` where the scroll
body could not reach it. `SubsectionView` holds one `RoomGrid` value and uses it both as the wrap
mode's layout and as the scroll mode's source of widths and multi-row heights.

Body per the spec: header (displayName styled by density; matching rollup via
`store.rollups(room)` filtered to the kind — lights→`.lights`, shades→`.covers`; configure-mode
tap target opening `.subsectionConfig(kind:)`), then scroll body (`ScrollView(.horizontal)` +
`HStack`, each tile `DeviceTileView(entityId:surface:span:)` framed to
`span.columns × cellWidth + (span.columns-1) × 9` where `cellWidth = (containerWidth - 3*9)/4`
via `GeometryReader` or `containerRelativeFrame`) or wrap body (existing `RoomGrid`, tiles
carrying `.tileSpan(subsection.span)`).

- [ ] **Step 1: Read first:** `RoomSectionView` in full (grid construction, drag wiring, rollup
  row), `RoomGrid`'s `TileSpanKey`, `DeviceTileView`. The code above is target shape; anchor it in
  what exists.
- [ ] **Step 2: Build `SubsectionView`** with both bodies and both densities. Rollup row moves in
  from `RoomSectionView.rollupRow` — take the *floor* implementation, delete neither yet (Task 5
  deletes both originals).
- [ ] **Step 3: Gallery page.** `TileGallery` gains a "Subsections" page rendering each kind in
  both modes and both densities from fixture states. This is the visual verification for
  everything in this task — nothing else renders it. Compare by eye in the preview canvas, both
  themes, before committing.
- [ ] **Step 4:** `xcodegen generate`; both suites (app count unchanged — nothing wired yet);
  commit: `feat(app): the subsection container, in the gallery before the app`

### Task 5: Both surfaces render subsections

**Files:**
- Modify: `App/Views/RoomSectionView.swift` (grid + rollup row + drag state → subsection stack),
  `App/Views/RoomDetailView.swift` (grouped rendering → subsection stack),
  `App/Renderers/SubsectionView.swift` (per-subsection `TileDragState`)
- Test: existing app suite must stay green; `ObservationTests` unchanged reads still pass.

- [ ] **Step 1: Read both surface views in full.** The drag machinery (`TileDragState`,
  `RearrangeableTile`) moves from room scope to subsection scope: each `SubsectionView` owns its
  own `@State private var drag: TileDragState`, seeded-injectable exactly as `RoomSectionView`'s
  is today (the doc comment explains why; it moves with the property). Configure mode forces the
  wrap body (decision 8), so drag only ever composes with `RoomGrid`.
- [ ] **Step 2: Rewire `RoomSectionView`:** heading (name + env chips, unchanged) →
  `ForEach(store.subsections(room, on: .overview)) { SubsectionView(room: room, subsection: $0, surface: .overview, density: .compact) }`
  → add-tile affordance in configure mode. Delete the room-level rollup row and the four-grid
  remnant comments *by moving them* onto `SubsectionView` where they now apply. Note that this
  `ForEach` leans on `RoomSubsection.id == kind.rawValue`, which no test pins — decide here whether
  to pin it, because a changed `id` would cost every subsection its view identity on each resolve.
- [ ] **Step 3: Rewire `RoomDetailView`** the same way with `surface: .roomDetail`/`.regular`; delete its
  `group(_:_:rollup:)` and Task 1's interim `bucket(_:)`. Both duplicated rollup implementations
  are now gone; `SubsectionView` holds the only one.
- [ ] **Step 4: Order write-back sanity.** ~~Reordering within a subsection writes the same per-room
  `order` key it does today~~ — **superseded by spec decision 9**, added during this task's review.
  Reordering writes that *surface's* order key. `DashboardConfigWriteBackTests`' "must pass
  unmodified" tripwire was deliberately lifted with the schema change; those tests were updated to
  the per-surface write path and extended to pin that a write on one surface preserves the other's
  stored list.
- [ ] **Step 5: Both suites; hands-on pass on device/simulator** (spec's testing section: gallery
  covers looks, not feel — scroll a row, long-press a tile, enter configure mode and watch scroll
  rows become grids, drag within a subsection, confirm nothing drags across). Commit:
  `feat(app): a room is its subsections, on both surfaces`

**Written from the repo during Task 5** — three things this plan did not anticipate, recorded per
the plan's own "the code in the repo wins" rule:

0. **Superseded: order is per surface** (spec decision 9, added mid-task from this task's review).
   `rooms.<areaId>.order` is now `{"overview": [...], "room_detail": [...]}`; `DashboardDocument`
   gained `orders(forRoom:)` / `order(forRoom:on:)` / `settingOrder(_:forRoom:on:)`;
   `RoomSection.order` became `orders: [HavenSurface: [String]]` and `refs(for:)` resolves
   **surface → other surface → none** at read time, with `TileOrder` itself untouched. Two
   implementation calls not in the fix brief, both disclosed in the fix report: the fallback switch
   is a private helper on `RoomSection` rather than a public `other` on `HavenSurface` (it is
   meaningful only for exactly two surfaces and should not become a general concept), and
   `HomeStore.resetOrder(areaId:)` clears **both** surfaces rather than taking a surface — clearing
   one alone makes it *follow* its sibling, so a "reset to default" that cleared only the overview
   would make the dashboard adopt room detail's arrangement.

1. **`visibleIds` stays room-scoped while the drag state goes per-subsection.** `TileDropDelegate`
   writes through `store.setOrder(_:areaId:)`, whose key is the room's *whole* arrangement, so
   handing it one subsection's ids would store those as the room's entire order and let
   `TileOrder.resolve` re-derive every other subsection from `defaultOrder`. `SubsectionView`
   therefore computes `room.refs(for: surface).map(\.id)`. Bucketing preserves sequence, so a move
   within the room's list is exactly a move within one bucket.
2. **The `+`'s second job as the "put it last" drop target is gone**, because the `+` now sits
   outside every `SubsectionView` and the drag state it consulted is inside one. Not replaced with a
   per-subsection end cell: insert-before alone generates every permutation, so this is a
   convenience loss rather than a capability loss. `isEnd`/`targetIsEnd` stay in the machinery,
   currently unexercised. Named on the hands-on checklist.
3. **Room detail gains drag-to-rearrange**, which it never had — the consequence of both surfaces
   rendering the one container, and not gated on surface (a `surface ==` check would be exactly the
   special case decision 2 rejects). Its `visibleIds` is `refs(for: .roomDetail)`, a superset;
   overview reads the same key and `TileOrder.resolve` filters to what it shows, so relative order
   survives. Also on the hands-on checklist.

### Task 6: Configuration — the subsection sheet, the global default, and the picker that leaves

**Files:**
- Create: `App/Views/SubsectionConfigView.swift`
- Modify: `App/Views/DashboardView.swift` (present `.subsectionConfig`; overflow-menu row for the
  household default mode), `App/Views/TileConfigView.swift` (remove the size picker section and
  `sizeEdit`), `App/DesignSystem/TileSizePicker.swift` (options now come from
  `kind.availableSpans`; the picker itself survives)
- Test: `Tests/HavenAppTests/DashboardConfigWriteBackTests.swift` — size cases replaced by
  subsection-sheet equivalents

- [ ] **Step 1:** `SubsectionConfigView(kind:)` — size (a `TileSizePicker` over
  `kind.availableSpans`, hidden when there is one option) and mode (Household default / Scroll /
  Wrap). Deferred-save like `TileConfigView`: commit once on dismiss via `config.update`,
  `settingSubsectionSpan`/`settingSubsectionMode`, `nil` for "back to default".
- [ ] **Step 2:** Overflow menu row ("Subsections scroll / wrap") writing `settingDisplayMode`.
- [ ] **Step 3:** Remove `TileConfigView`'s size section, its `sizeEdit` dirty-check, and its
  write of `settingSize`. (The Core-side deletion of `settingSize` itself is Task 7 — this task
  only stops the app calling it.)
- [ ] **Step 4:** Write-back tests: subsection span/mode round-trip through a fake connection,
  watched to fail first by pointing the sheet's commit at the wrong mutator. Both suites; commit:
  `feat(app): a subsection is configured where it is seen`

### Task 7: Per-entity sizing leaves the schema

**Files:**
- Modify: `Packages/HavenCore/Sources/HavenCore/Config/DashboardDocument.swift` (delete `sizes`
  accessor, `settingSize`, `sizesKey`), `App/HomeStore.swift` (delete `span(of:on:)`),
  callers found by `grep -rn "span(of:\|settingSize\|sizes" App/ Packages/`
- Test: `DashboardDocumentTests` size cases deleted; one new test pinning that a legacy document
  *carrying* `entities.<id>.sizes` still round-trips untouched (merge discipline preserves what we
  no longer understand — the spec's no-migration promise).

- [ ] **Step 1:** Grep-driven deletion, Core then App; the compiler enumerates the stragglers.
- [ ] **Step 2:** The legacy-keys test: build a document with a `sizes` subtree, run an unrelated
  mutator, assert the subtree survives byte-identical. Watch it fail by making the mutator strip
  unknown entity keys.
- [ ] **Step 3:** Both suites; `xcodegen generate` not needed (no file adds); commit:
  `refactor: a tile's size belongs to its subsection, and nothing else remembers one`

---

## Execution notes

- Tasks 1→2→3 are strictly sequential (each consumes the previous interface). 4 depends on 3;
  5 on 4; 6 on 5; 7 on 6. No parallel dispatch — every task after 3 touches `HomeStore` or the
  views around it.
- Task 5 is the risk concentration: it changes what two shipped surfaces render and how drag
  works. Its hands-on step is not optional, and `TileGallery` before/after in both themes is the
  review evidence for it.
- If any task's read step contradicts this plan's target code, the code in the repo wins — update
  the plan file in the same commit and say so. This plan was written from files read on
  2026-08-15; the session that authored it learned four times that summaries drift.
