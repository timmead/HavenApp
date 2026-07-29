# Tile Membership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user take a device off a Haven surface and put one back — a red *Remove from dashboard* in a tile's configuration sheet, and a dashed **+** tile that offers whatever the surface isn't showing.

**Architecture:** A new pure layer in HavenCore (`HavenSurface`, `SurfaceMembership`) answers "does this surface show this entity", combining the curation tier with a per-entity, per-surface user override read from the dashboard document. `RoomSection`'s two hard-coded surface accessors collapse into one method taking a surface. Every write goes through `HavenConfig.update`, as the foundation established.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test`/`#expect`), Xcode project + local SPM package `HavenCore`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-29-tile-membership-design.md`
**Builds on:** `docs/superpowers/specs/2026-07-28-configuration-foundation-design.md`

## Global Constraints

- **Home Assistant is the source of truth.** Nothing here writes to HA's registry. Removal takes a tile off a Haven surface; it deletes nothing.
- **Entities HA hid are never offered and never shown.** `hidden_by`/`entity_category` land on `CurationTier.hidden`; the picker omits them and `SurfaceMembership.shows` refuses a `shown` override on them, so a hand-edited document cannot make Haven contradict HA.
- **`CurationTier` is not modified by any of this.** The user layer sits on top and answers a question about a *surface*.
- **One writer.** All writes go through `HavenConfig.update`. Nothing else calls `saveConfig` for the dashboard key.
- **`DashboardDocument.schema` stays at `1`** — additive, and Haven has not shipped.
- **Tests use Swift Testing:** `@Test func name()` with `#expect(...)`.
- **Run the suites separately.** HavenCore: `cd Packages/HavenCore && swift test`. App: `xcodebuild test -scheme HavenApp -destination 'id=<sim>'` from the repo root — find a 26.5 iPhone simulator id with `xcodebuild test -scheme HavenApp -destination 'id=x' 2>&1 | grep "iPhone 1.*OS:26.5"`. **`timeout` does not exist on macOS**; do not wrap these.
- **`xcodegen generate` after adding any file**, or it is not in the target and the build fails with "cannot find type in scope". It rewrites the gitignored `HavenApp.xcodeproj`.
- **Every new sheet gets three checks**, because the last sub-project shipped three defects invisible to a build and a static render: presented through `.fittedSheet()` at the call site, carrying an explicit `ModalDoneButton`, and **rendered over content** rather than only at rest.
- **Doc comments carry the reasoning**, matching this codebase: state *why*, especially where the obvious alternative is wrong.

---

## File Structure

**Created:**
- `Packages/HavenCore/Sources/HavenCore/Curation/SurfaceMembership.swift` — the surfaces, the override, and the rule.
- `Packages/HavenCore/Tests/HavenCoreTests/SurfaceMembershipTests.swift`
- `App/Views/AddTileView.swift` — the picker sheet.
- `App/DesignSystem/AddTilePlaceholder.swift` — the dashed **+** tile.

**Modified:**
- `Packages/HavenCore/Sources/HavenCore/Config/DashboardDocument.swift` — the `surfaces` subtree.
- `Packages/HavenCore/Tests/HavenCoreTests/DashboardDocumentTests.swift`
- `Packages/HavenCore/Sources/HavenCore/Models/HomeSection.swift` — `refs(for:)`, and `SectionBuilder` takes overrides.
- `Packages/HavenCore/Tests/HavenCoreTests/HomeSectionTests.swift`
- `App/HomeStore.swift` — `setMembership`, `addableEntities`, and `rooms()` passing overrides.
- `App/Navigation.swift` — `tileConfig` carries a surface; new `addTile` case.
- `App/Views/DashboardView.swift` — route the new sheet.
- `App/Views/RoomSectionView.swift` — the **+** at the end of the 4-column grid.
- `App/Views/RoomDetailView.swift` — the **+**, and its surface for tile config.
- `App/Views/TileConfigView.swift` — the remove button.
- `App/Renderers/TileGallery.swift` — page four extended.
- `Tests/HavenAppTests/HavenConfigTests.swift` — the membership write path.

---

## Task 1: The membership rule

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Curation/SurfaceMembership.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/SurfaceMembershipTests.swift`

**Interfaces:**
- Produces: `HavenSurface` (`.overview`, `.roomDetail`), `SurfaceMembership` (`.hidden`, `.shown`), and `SurfaceMembership.shows(tier:on:override:) -> Bool`. Task 2 stores the override, Task 3 applies the rule, Tasks 5–7 drive it from the UI.

- [ ] **Step 1: Write the failing test**

Create `Packages/HavenCore/Tests/HavenCoreTests/SurfaceMembershipTests.swift`:

```swift
import Foundation
import Testing
@testable import HavenCore

/// The whole matrix: four tiers × two surfaces × three override states. Written out rather than
/// looped because the interesting content is *which* cells differ, and a loop over the rule would
/// only restate the rule.
@Test func withoutAnOverrideEachSurfaceRendersItsOwnTiers() {
    // The overview is controls only.
    #expect(SurfaceMembership.shows(tier: .primary, on: .overview, override: nil))
    #expect(!SurfaceMembership.shows(tier: .secondary, on: .overview, override: nil))
    #expect(!SurfaceMembership.shows(tier: .companion, on: .overview, override: nil))
    #expect(!SurfaceMembership.shows(tier: .hidden, on: .overview, override: nil))

    // Room detail adds the sensors curation demoted off the grid.
    #expect(SurfaceMembership.shows(tier: .primary, on: .roomDetail, override: nil))
    #expect(SurfaceMembership.shows(tier: .secondary, on: .roomDetail, override: nil))
    #expect(!SurfaceMembership.shows(tier: .companion, on: .roomDetail, override: nil))
    #expect(!SurfaceMembership.shows(tier: .hidden, on: .roomDetail, override: nil))
}

@Test func hiddenTakesADeviceOffThatSurfaceWhateverItsTier() {
    #expect(!SurfaceMembership.shows(tier: .primary, on: .overview, override: .hidden))
    #expect(!SurfaceMembership.shows(tier: .primary, on: .roomDetail, override: .hidden))
    #expect(!SurfaceMembership.shows(tier: .secondary, on: .roomDetail, override: .hidden))
}

/// `shown` is what makes the + an addition rather than an undo: it puts a device on a surface
/// curation left off it, including `.companion` telemetry a user genuinely wants a tile for.
@Test func shownPutsADeviceOnASurfaceCurationLeftItOff() {
    #expect(SurfaceMembership.shows(tier: .secondary, on: .overview, override: .shown))
    #expect(SurfaceMembership.shows(tier: .companion, on: .overview, override: .shown))
    #expect(SurfaceMembership.shows(tier: .companion, on: .roomDetail, override: .shown))
}

/// **The one exception, and the reason the rule is a function rather than a set lookup.** A
/// `.hidden` tier is Home Assistant's own doing (`hidden_by`) or its `entity_category`, and HA
/// outranks anything Haven decides. The picker never offers these, so a `shown` override cannot
/// arise through the UI — this refuses it anyway, so a hand-edited document cannot make Haven
/// contradict Home Assistant.
@Test func shownCannotResurrectWhatHomeAssistantHid() {
    #expect(!SurfaceMembership.shows(tier: .hidden, on: .overview, override: .shown))
    #expect(!SurfaceMembership.shows(tier: .hidden, on: .roomDetail, override: .shown))
}

@Test func theSurfacesAndOverridesRoundTripAsStrings() {
    #expect(HavenSurface(rawValue: "overview") == .overview)
    #expect(HavenSurface(rawValue: "room_detail") == .roomDetail)
    #expect(HavenSurface.allCases.count == 2)
    #expect(SurfaceMembership(rawValue: "hidden") == .hidden)
    #expect(SurfaceMembership(rawValue: "shown") == .shown)
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd Packages/HavenCore && swift test --filter SurfaceMembership`
Expected: FAIL — `cannot find 'SurfaceMembership' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Packages/HavenCore/Sources/HavenCore/Curation/SurfaceMembership.swift`:

```swift
import Foundation

/// A place in Haven that renders a room's devices.
///
/// Two, and they show different things by design: the dashboard's room section is a *summary* of
/// what you control, and room detail is the room's *inventory*. Curation decides the default for
/// each (see `CurationTier`), and a user's decision is per surface — taking a light off the
/// dashboard says nothing about whether it is reachable one tap deeper.
public enum HavenSurface: String, Sendable, Codable, CaseIterable {
    case overview
    /// `room_detail` on the wire: the stored document is JSON read by other builds, so the raw
    /// values are spelled deliberately rather than left to Swift's case names.
    case roomDetail = "room_detail"

    /// The tiers this surface renders when the user has said nothing.
    var defaultTiers: Set<CurationTier> {
        switch self {
        case .overview: return [.primary]
        case .roomDetail: return [.primary, .secondary]
        }
    }
}

/// What a user decided about one entity on one surface.
///
/// Deliberately **not** a boolean, and deliberately absent by default, which makes three states:
///
/// - *absent* — follow curation. Where nearly everything stays.
/// - `hidden` — the user took it off this surface.
/// - `shown` — the user put it on this surface though curation did not.
///
/// The third is what makes the configuration mode's `+` an *addition* rather than an undo: putting a
/// humidity sensor on the dashboard grid overrides curation upward, and a design holding only a
/// hidden set could restore what the user removed and nothing else.
public enum SurfaceMembership: String, Sendable, Codable {
    case hidden, shown

    /// Whether `surface` shows an entity of `tier`, given the user's decision about it.
    ///
    /// A function rather than a set lookup because of the last clause: **`shown` cannot resurrect a
    /// `.hidden` tier.** That tier is Home Assistant's own doing — `hidden_by`, or an
    /// `entity_category` marking a configuration/diagnostic entity — and HA outranks everything
    /// Haven decides, the same order of authority `EntityCuration` and `LockTile` already obey. The
    /// picker never offers those entities, so such an override cannot be made through the UI; this
    /// refuses it anyway, so a document edited by hand or by a future build cannot make Haven
    /// contradict Home Assistant.
    public static func shows(tier: CurationTier, on surface: HavenSurface,
                             override: SurfaceMembership?) -> Bool {
        guard tier != .hidden else { return false }
        switch override {
        case .hidden: return false
        case .shown: return true
        case nil: return surface.defaultTiers.contains(tier)
        }
    }
}
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `cd Packages/HavenCore && swift test --filter SurfaceMembership`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/HavenCore/Sources/HavenCore/Curation/SurfaceMembership.swift \
        Packages/HavenCore/Tests/HavenCoreTests/SurfaceMembershipTests.swift
git commit -m "feat(core): which surface shows which device, as a rule"
```

---

## Task 2: The `surfaces` subtree

**Files:**
- Modify: `Packages/HavenCore/Sources/HavenCore/Config/DashboardDocument.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/DashboardDocumentTests.swift`

**Interfaces:**
- Consumes: `HavenSurface`, `SurfaceMembership` (Task 1).
- Produces: `DashboardDocument.surfaceOverrides: [String: [HavenSurface: SurfaceMembership]]` and `settingMembership(_ membership: SurfaceMembership?, for entityId: String, on surface: HavenSurface) -> DashboardDocument`. `nil` clears.

- [ ] **Step 1: Write the failing tests**

Append to `DashboardDocumentTests.swift`:

```swift
// MARK: - Surface membership

@Test func aMembershipRoundTripsPerSurface() {
    let doc = DashboardDocument()
        .settingMembership(.hidden, for: "light.kitchen", on: .overview)
        .settingMembership(.shown, for: "sensor.hum", on: .overview)
    #expect(doc.surfaceOverrides["light.kitchen"]?[.overview] == .hidden)
    #expect(doc.surfaceOverrides["sensor.hum"]?[.overview] == .shown)
    // Untouched surfaces stay absent, which is what "follow curation" is.
    #expect(doc.surfaceOverrides["light.kitchen"]?[.roomDetail] == nil)
}

/// The surfaces are independent, which is the whole decision this feature rests on: removing a
/// device from the dashboard must say nothing about room detail.
@Test func writingOneSurfaceLeavesTheOtherAlone() {
    let doc = DashboardDocument()
        .settingMembership(.hidden, for: "light.kitchen", on: .overview)
        .settingMembership(.hidden, for: "light.kitchen", on: .roomDetail)
        .settingMembership(nil, for: "light.kitchen", on: .overview)
    #expect(doc.surfaceOverrides["light.kitchen"]?[.overview] == nil)
    #expect(doc.surfaceOverrides["light.kitchen"]?[.roomDetail] == .hidden)
}

/// The property this type exists to defend, now across two subtrees of one entity: a name and a
/// membership are written by different sheets and must not disturb each other, and neither may strip
/// a key a newer build wrote.
@Test func membershipAndNameAndUnknownKeysCoexist() {
    let raw = JSONValue.object([
        "entities": .object(["light.kitchen": .object([
            "name": .string("Reading Lamp"),
            "icon": .string("mdi:lamp"),
            "surfaces": .object(["room_detail": .string("hidden")]),
        ])]),
    ])
    let doc = DashboardDocument(raw: raw)
        .settingMembership(.hidden, for: "light.kitchen", on: .overview)
    #expect(doc.displayNames["light.kitchen"] == "Reading Lamp")
    #expect(doc.surfaceOverrides["light.kitchen"]?[.overview] == .hidden)
    #expect(doc.surfaceOverrides["light.kitchen"]?[.roomDetail] == .hidden)
    let entity = doc.raw.asObject?["entities"]?.asObject?["light.kitchen"]?.asObject
    #expect(entity?["icon"]?.asString == "mdi:lamp")
}

/// Clearing the last membership removes `surfaces`, and clearing the last key removes the entity —
/// so a document that has been edited and un-edited ends where it started rather than carrying a
/// shell per device anyone ever opened.
@Test func clearingTheLastMembershipLeavesNoResidue() {
    let doc = DashboardDocument()
        .settingMembership(.hidden, for: "light.kitchen", on: .overview)
        .settingMembership(nil, for: "light.kitchen", on: .overview)
    #expect(doc.surfaceOverrides.isEmpty)
    #expect(doc.raw.asObject?["entities"] == nil)
}

@Test func aMalformedOrUnknownMembershipIsIgnoredNotFatal() {
    let raw = JSONValue.object([
        "entities": .object([
            "light.a": .object(["surfaces": .string("nonsense")]),
            "light.b": .object(["surfaces": .object(["overview": .string("sideways")])]),
            "light.c": .object(["surfaces": .object(["kitchen_wall": .string("hidden")])]),
        ]),
    ])
    // An unreadable value, an unknown membership and an unknown surface all drop out rather than
    // taking the document with them — a build that adds a third surface must not brick this one.
    #expect(DashboardDocument(raw: raw).surfaceOverrides.isEmpty)
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd Packages/HavenCore && swift test --filter DashboardDocument`
Expected: FAIL — no member `settingMembership`.

- [ ] **Step 3: Write the implementation**

Add beside `nameKey` in `DashboardDocument.swift`:

```swift
    private static let surfacesKey = "surfaces"
```

And after `settingDisplayName(_:for:)`:

```swift
    /// Every user decision about which surfaces show which entity, keyed by entity id.
    ///
    /// Unknown surfaces and unknown membership values are dropped rather than defaulted: a build
    /// that adds a third surface, or a fourth membership state, must leave this one working rather
    /// than brick it on a value it cannot read.
    public var surfaceOverrides: [String: [HavenSurface: SurfaceMembership]] {
        guard let entities = raw.asObject?[Self.entitiesKey]?.asObject else { return [:] }
        return entities.compactMapValues { entity -> [HavenSurface: SurfaceMembership]? in
            guard let surfaces = entity.asObject?[Self.surfacesKey]?.asObject else { return nil }
            var out: [HavenSurface: SurfaceMembership] = [:]
            for (rawSurface, rawMembership) in surfaces {
                guard let surface = HavenSurface(rawValue: rawSurface),
                      let value = rawMembership.asString,
                      let membership = SurfaceMembership(rawValue: value) else { continue }
                out[surface] = membership
            }
            return out.isEmpty ? nil : out
        }
    }

    /// This document with one entity's membership of one surface set, or — for `nil` — cleared back
    /// to following curation.
    ///
    /// One entity and one surface at a time, because that is how the feature works: a tap removes a
    /// tile from the surface it was on. Merging at every level so a rename survives a removal and
    /// vice versa, and so clearing the last membership leaves no residue — see the tests.
    public func settingMembership(_ membership: SurfaceMembership?, for entityId: String,
                                  on surface: HavenSurface) -> DashboardDocument {
        var root = raw.asObject ?? [:]
        root[Self.schemaKey] = .int(max(declaredSchema, Self.schema))
        var entities = root[Self.entitiesKey]?.asObject ?? [:]
        var entity = entities[entityId]?.asObject ?? [:]
        var surfaces = entity[Self.surfacesKey]?.asObject ?? [:]
        if let membership {
            surfaces[surface.rawValue] = .string(membership.rawValue)
        } else {
            surfaces.removeValue(forKey: surface.rawValue)
        }
        if surfaces.isEmpty {
            entity.removeValue(forKey: Self.surfacesKey)
        } else {
            entity[Self.surfacesKey] = .object(surfaces)
        }
        if entity.isEmpty {
            entities.removeValue(forKey: entityId)
        } else {
            entities[entityId] = .object(entity)
        }
        if entities.isEmpty {
            root.removeValue(forKey: Self.entitiesKey)
        } else {
            root[Self.entitiesKey] = .object(entities)
        }
        return DashboardDocument(raw: .object(root))
    }
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `cd Packages/HavenCore && swift test --filter DashboardDocument`
Expected: PASS — the existing 16 plus 5 new.

- [ ] **Step 5: Commit**

```bash
git add Packages/HavenCore/Sources/HavenCore/Config/DashboardDocument.swift \
        Packages/HavenCore/Tests/HavenCoreTests/DashboardDocumentTests.swift
git commit -m "feat(core): the document remembers which surfaces show which device"
```

---

## Task 3: One surface accessor on `RoomSection`

**Files:**
- Modify: `Packages/HavenCore/Sources/HavenCore/Models/HomeSection.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/HomeSectionTests.swift`
- Modify: `App/HomeStore.swift`, `App/Views/RoomSectionView.swift`, `App/Views/RoomDetailView.swift` (call sites)

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces: `RoomSection.refs(for surface: HavenSurface) -> [DeviceRef]`, `RoomSection.overrides` (stored), and `SectionBuilder.rooms(from:environment:overrides:)`. `overviewRefs`/`detailRefs` are **deleted**.

- [ ] **Step 1: Write the failing test**

Append to `Packages/HavenCore/Tests/HavenCoreTests/HomeSectionTests.swift`:

```swift
/// A room with one entity per tier, plus the two user decisions, read from both surfaces.
@Test func aSurfaceShowsItsOwnTiersPlusWhatTheUserPutThere() {
    let area = ResolvedArea(id: "lounge", name: "Lounge",
                            entityIds: ["light.a", "sensor.b", "sensor.batt", "light.hidden"],
                            tiers: ["light.a": .primary, "sensor.b": .secondary,
                                    "sensor.batt": .companion, "light.hidden": .hidden])
    let home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "F", level: 0, areas: [area])])
    let rooms = SectionBuilder.rooms(from: home, environment: [:], overrides: [
        // Off the dashboard, still in room detail — the case this whole design exists for.
        "light.a": [.overview: .hidden],
        // On the dashboard though curation demoted it.
        "sensor.b": [.overview: .shown],
        // Home Assistant hid this one; a stored override must not resurrect it.
        "light.hidden": [.overview: .shown],
    ])
    let room = rooms[0]

    #expect(room.refs(for: .overview).map(\.id) == ["sensor.b"])
    #expect(room.refs(for: .roomDetail).map(\.id) == ["light.a", "sensor.b"])
}

@Test func withNoOverridesEachSurfaceIsExactlyItsTiers() {
    let area = ResolvedArea(id: "lounge", name: "Lounge",
                            entityIds: ["light.a", "sensor.b", "sensor.batt"],
                            tiers: ["light.a": .primary, "sensor.b": .secondary,
                                    "sensor.batt": .companion])
    let home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "F", level: 0, areas: [area])])
    let room = SectionBuilder.rooms(from: home, environment: [:], overrides: [:])[0]
    #expect(room.refs(for: .overview).map(\.id) == ["light.a"])
    #expect(room.refs(for: .roomDetail).map(\.id) == ["light.a", "sensor.b"])
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd Packages/HavenCore && swift test --filter HomeSection`
Expected: FAIL — `rooms(from:environment:overrides:)` does not exist.

- [ ] **Step 3: Write the implementation**

In `HomeSection.swift`, replace the two accessors and the private filter:

```swift
    /// The user's decisions about which surfaces show which of this room's entities, keyed by entity
    /// id. Read from the dashboard document; absent for nearly everything.
    public let overrides: [String: [HavenSurface: SurfaceMembership]]

    /// What `surface` shows.
    ///
    /// One method taking a surface rather than an `overviewRefs`/`detailRefs` pair: the pair had the
    /// tier sets hard-coded at two call sites, and a user override has to be applied at both. Two
    /// places to apply one rule is one place to forget it.
    public func refs(for surface: HavenSurface) -> [DeviceRef] {
        deviceRefs.filter { ref in
            // A composite carries no single entity id, so no tier and no membership — nothing
            // constructs them yet (see `DeviceRef`), and when something does it will be a curated
            // unit by definition.
            guard case .entity(let id) = ref else { return true }
            return SurfaceMembership.shows(tier: tier(of: id), on: surface,
                                           override: overrides[id]?[surface])
        }
    }
```

Add `overrides` to the initialiser (`RoomSection` is a memberwise struct — the compiler will surface every construction site), and to `SectionBuilder`:

```swift
    /// - Parameter overrides: each entity's per-surface membership — see `SurfaceMembership`.
    ///   Required rather than defaulted for the same reason `environment` is: an omitted map means
    ///   every removal the household has made silently reverts, and that failure is invisible from
    ///   the call site.
    public static func rooms(from home: ResolvedHome,
                            environment: [String: RoomEnvironment],
                            overrides: [String: [HavenSurface: SurfaceMembership]]) -> [RoomSection] {
```

Pass `overrides: overrides` into the `RoomSection(...)` construction inside it.

- [ ] **Step 4: Fix the call sites the compiler names**

`App/HomeStore.swift`:

```swift
    func rooms() -> [RoomSection] {
        SectionBuilder.rooms(from: home, environment: environment,
                             overrides: config.document.surfaceOverrides)
    }
```

And in `deviceEntityIds` (the roll-up helper), `room.overviewRefs` becomes `room.refs(for: .overview)` — which is also what makes a user-hidden tile fall out of the roll-up count and out of its bulk action, as the spec requires.

`App/Views/RoomSectionView.swift`: four uses of `room.overviewRefs` become `room.refs(for: .overview)`.
`App/Views/RoomDetailView.swift`: `room.detailRefs` becomes `room.refs(for: .roomDetail)`.

- [ ] **Step 5: Run everything**

Run: `cd Packages/HavenCore && swift test`, then `xcodegen generate`, build, and the app suite.
Expected: PASS. HavenCore gains 2; the app suite is unchanged in count.

- [ ] **Step 6: Commit**

```bash
git add Packages/HavenCore App/HomeStore.swift App/Views/RoomSectionView.swift App/Views/RoomDetailView.swift
git commit -m "refactor(core): one accessor per surface, so the user's decision reaches both"
```

---

## Task 4: The store's reads and writes

**Files:**
- Modify: `App/HomeStore.swift`
- Test: `Tests/HavenAppTests/HavenConfigTests.swift`

**Interfaces:**
- Produces:
  - `HomeStore.setMembership(_ entityId: String, on surface: HavenSurface, to membership: SurfaceMembership?) async -> HavenConfig.Outcome`
  - `HomeStore.addableEntityIds(in room: RoomSection, on surface: HavenSurface) -> [String]` — the
    spec calls this `addableEntities`; renamed here because it returns ids, not entities, and a name
    that promises objects is how a caller ends up expecting states attached.

- [ ] **Step 1: Write the failing test**

Append to `Tests/HavenAppTests/HavenConfigTests.swift`, inside the suite:

```swift
    /// Removing a tile writes one surface's membership and leaves the other alone — the property the
    /// whole design rests on, checked through the real write path rather than on the document.
    @Test func removingFromOneSurfaceLeavesTheOtherFollowingCuration() async throws {
        let (store, _) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get": return absent(id)
            case "havenapp/config/set": return ok(id)
            default: return nil
            }
        }
        let outcome = await store.setMembership("sensor.lr_temp", on: .overview, to: .hidden)
        #expect(outcome == .written)
        #expect(store.config.document.surfaceOverrides["sensor.lr_temp"]?[.overview] == .hidden)
        #expect(store.config.document.surfaceOverrides["sensor.lr_temp"]?[.roomDetail] == nil)
    }
```

- [ ] **Step 2: Run it and watch it fail**

Run the app suite. Expected: FAIL to compile — no `setMembership`.

- [ ] **Step 3: Write the implementation**

In `App/HomeStore.swift`, beside `nominate` and `rename`:

```swift
    /// Takes a device off a Haven surface, puts one on it, or clears the decision so curation
    /// decides again.
    ///
    /// Never touches Home Assistant: this is Haven's own layer, and the entity is exactly as it was
    /// in HA afterwards — see `SurfaceMembership`.
    func setMembership(_ entityId: String, on surface: HavenSurface,
                       to membership: SurfaceMembership?) async -> HavenConfig.Outcome {
        await config.update { $0.settingMembership(membership, for: entityId, on: surface) }
    }

    /// What the `+` on `surface` offers: every entity in the room that surface is not currently
    /// showing.
    ///
    /// Entities Home Assistant hid are absent, and that is a deliberate ceiling rather than an
    /// oversight — `SurfaceMembership.shows` refuses to show them at all, so offering them would
    /// mean offering a tap that does nothing. A user who wants one on their dashboard un-hides it
    /// where they hid it.
    ///
    /// Ordered by entity id so the sheet does not reshuffle between openings.
    func addableEntityIds(in room: RoomSection, on surface: HavenSurface) -> [String] {
        let showing = Set(room.refs(for: surface).map(\.id))
        return room.deviceRefs.compactMap { ref -> String? in
            guard case .entity(let id) = ref, !showing.contains(id),
                  room.tier(of: id) != .hidden else { return nil }
            return id
        }.sorted()
    }
```

- [ ] **Step 4: Run the suites**

Run: `xcodegen generate`, build, app suite. Expected: PASS, one test more.

- [ ] **Step 5: Commit**

```bash
git add App/HomeStore.swift Tests/HavenAppTests/HavenConfigTests.swift
git commit -m "feat(app): the store can take a tile off a surface and say what could go on it"
```

---

## Task 5: Removing a tile

**Files:**
- Modify: `App/Navigation.swift`, `App/Views/TileConfigView.swift`, `App/Views/DashboardView.swift`, `App/Views/RoomSectionView.swift`, `App/Views/RoomDetailView.swift`, `App/DesignSystem/ConfigurableTile.swift`

**Interfaces:**
- Consumes: Task 4.
- Produces: `Navigation.Presentation.tileConfig(entityId: String, surface: HavenSurface)` and `Navigation.open(_ entityId: String, on surface: HavenSurface)`.

- [ ] **Step 1: Carry the surface into the sheet**

The sheet must know which surface it was opened from, or *Remove* cannot know what to remove it from. In `Navigation.swift`:

```swift
        /// The device's configuration — what a tap does *in* configuration mode. Carries the surface
        /// it was opened from, because "remove" means "off this surface" and the sheet is opened from
        /// both the dashboard and room detail.
        case tileConfig(entityId: String, surface: HavenSurface)
```

`open` takes the surface, and `id` includes it:

```swift
    func open(_ entityId: String, on surface: HavenSurface) {
        presented = isConfiguring
            ? .tileConfig(entityId: entityId, surface: surface)
            : .control(entityId: entityId)
    }
```

```swift
        case .tileConfig(let entityId, let surface): return "tileConfig:\(surface.rawValue):\(entityId)"
```

`ConfigurableTile` takes a surface and passes it through:

```swift
struct ConfigurableTile: ViewModifier {
    let entityId: String
    /// Which surface this tile is on, so its configuration sheet knows what "remove" removes it
    /// from. **No default**: the two surfaces are the whole point of this feature, and a default
    /// would let a new call site silently claim to be the dashboard.
    let surface: HavenSurface
    @Environment(Navigation.self) private var navigation

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!navigation.isConfiguring)
            .overlay {
                if navigation.isConfiguring {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { navigation.open(entityId, on: surface) }
                        .accessibilityElement()
                        .accessibilityLabel("Configure")
                        .accessibilityAddTraits(.isButton)
                }
            }
    }
}

extension View {
    func configurable(entityId: String, on surface: HavenSurface) -> some View {
        modifier(ConfigurableTile(entityId: entityId, surface: surface))
    }
}
```

`DeviceTileView` gains the same parameter and passes it on:

```swift
struct DeviceTileView: View {
    let entityId: String
    /// The surface this grid is. Explicit for the reason `ConfigurableTile.surface` is.
    let surface: HavenSurface
    @Environment(HomeStore.self) private var store
    var body: some View {
        tile.configurable(entityId: entityId, on: surface)
    }
    ...
}
```

Then the compiler names every construction site. `RoomSectionView` passes `.overview` (four places: the climate grid, the 4-column grid, media, cameras), `RoomDetailView` passes `.roomDetail` (its `group(...)` helper and the two hoisted grids), and `TileGallery` passes `.overview`.

- [ ] **Step 2: Add the colour token**

In `App/DesignSystem/Theme.swift`, beside `warning`:

```swift
    /// Destructive actions — removing a tile from a surface. Its own token rather than `Color.red`
    /// so the one destructive control in the app has one colour, and rather than `warning`, which is
    /// amber and already means "this needs attention" on locks and sensors.
    static let destructive = Color(red: 0.84, green: 0.19, blue: 0.19)
```

- [ ] **Step 3: Write the remove card**

In `TileConfigView.swift`, add `let surface: HavenSurface` and append below the Name card:

```swift
            FacetCard {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task { await remove() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                            Text(removeTitle).font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(HavenColor.destructive))
                    }
                    .buttonStyle(.plain)
                    // Says what it does and what it does not. A red button that turns out to be
                    // reversible is a better surprise than a grey one that isn't — but the sentence
                    // is what stops someone believing they have deleted a device from their home.
                    Text("The device stays in Home Assistant. Add it back with the + in \(surfaceNoun).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
```

with, on the type:

```swift
    /// **"Remove", never "Delete".** It takes a tile off one Haven surface; Haven deletes nothing in
    /// Home Assistant, and a button labelled delete would promise otherwise.
    private var removeTitle: String {
        switch surface {
        case .overview: return "Remove from dashboard"
        case .roomDetail: return "Remove from this room"
        }
    }

    private var surfaceNoun: String {
        switch surface {
        case .overview: return "this room on the dashboard"
        case .roomDetail: return "this room"
        }
    }

    /// No confirmation dialog, deliberately: one tap on the same screen's + puts it back, and a
    /// confirmation on a reversible action is how people learn to dismiss confirmations unread.
    private func remove() async {
        switch await store.setMembership(entityId, on: surface, to: .hidden) {
        case .written, .unchanged: dismiss()
        case .notAuthorized: failure = "Only Home Assistant admins can change the household dashboard."
        case .failed: failure = "Couldn't save that. Check your connection and try again."
        }
    }
```

- [ ] **Step 4: Build, run the suites, and render**

Run `xcodegen generate`, build, the app suite, and render `TileConfigView`'s two previews. Check the red card, its explanatory line, and that the title changes with the surface. Add a third preview for `.roomDetail`:

```swift
#Preview("Tile config — room detail") {
    TileConfigPreviewHost(entityId: "light.kitchen", overridden: false, surface: .roomDetail)
}
```

(extend `TileConfigPreviewHost` with a `surface` parameter defaulting to `.overview`).

- [ ] **Step 5: Commit**

```bash
git add App/ && git commit -m "feat(app): take a tile off a surface, without touching Home Assistant"
```

---

## Task 6: The + tile and its picker

**Files:**
- Create: `App/DesignSystem/AddTilePlaceholder.swift`, `App/Views/AddTileView.swift`
- Modify: `App/Navigation.swift`, `App/Views/DashboardView.swift`, `App/Views/RoomSectionView.swift`, `App/Views/RoomDetailView.swift`

**Interfaces:**
- Consumes: `HomeStore.addableEntityIds` (Task 4), `EntityPickerRow`, `ModalDoneButton`.
- Produces: `AddTilePlaceholder(action:)`, `AddTileView(areaId:surface:)`, `Navigation.Presentation.addTile(areaId: String, surface: HavenSurface)`.

- [ ] **Step 1: The placeholder tile**

Create `App/DesignSystem/AddTilePlaceholder.swift`:

```swift
import SwiftUI

/// The dashed **+** at the end of a room's grid, in configuration mode.
///
/// Sized and cornered like a 1×1 `GlassTile` so it sits in the grid rather than beside it, but
/// deliberately drawn as an outline: it is a place where a tile could be, not a tile. A filled
/// version reads as a device you own called "+".
struct AddTilePlaceholder: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(HavenColor.domain(.cover).opacity(0.5),
                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(minHeight: 66)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(HavenColor.domain(.cover))
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a device")
    }
}
```

- [ ] **Step 2: The picker sheet**

Create `App/Views/AddTileView.swift`:

```swift
import SwiftUI
import HavenCore

/// What this surface could show and isn't.
///
/// **No checkmarks**, unlike the room's sensor picker: nothing in this list is currently selected —
/// that is what makes it addable — so a column of empty checkmark slots would be furniture. Tapping
/// adds and dismisses.
struct AddTileView: View {
    let areaId: String
    let surface: HavenSurface
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?

    var body: some View {
        let room = store.rooms().first { $0.areaId == areaId }
        let addable = room.map { store.addableEntityIds(in: $0, on: surface) } ?? []
        VStack(alignment: .leading, spacing: 12) {
            ModalHeader(systemImage: "plus.circle",
                        title: "Add to \(room?.name ?? "room")",
                        subtitle: subtitle,
                        accent: HavenColor.domain(.cover), unavailable: false,
                        accessory: AnyView(ModalDoneButton { dismiss() }))
            if let failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(HavenColor.warning)
            }
            FacetCard {
                if addable.isEmpty {
                    // Not an error: a room can genuinely be showing everything it has. Saying so
                    // beats an empty card, which reads as a failed load.
                    Text("Everything in this room is already here.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(addable, id: \.self) { entityId in
                            Button {
                                Task { await add(entityId) }
                            } label: {
                                EntityPickerRow(title: store.displayName(of: entityId),
                                                entityId: entityId,
                                                isSelected: false)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 7)
                        }
                    }
                }
            }
        }
    }

    private var subtitle: String {
        switch surface {
        case .overview: return "Devices this room has that the dashboard isn't showing"
        case .roomDetail: return "Devices this room has that aren't shown here"
        }
    }

    private func add(_ entityId: String) async {
        switch await store.setMembership(entityId, on: surface, to: .shown) {
        case .written, .unchanged: dismiss()
        case .notAuthorized: failure = "Only Home Assistant admins can change the household dashboard."
        case .failed: failure = "Couldn't save that. Check your connection and try again."
        }
    }
}
```

- [ ] **Step 3: Route it**

`Navigation.Presentation` gains `case addTile(areaId: String, surface: HavenSurface)`, with `id` `"addTile:\(surface.rawValue):\(areaId)"`. `DashboardView`'s sheet switch gains:

```swift
            case .addTile(let areaId, let surface):
                AddTileView(areaId: areaId, surface: surface).fittedSheet()
```

- [ ] **Step 4: Place it in both surfaces**

In `RoomSectionView`, inside the 4-column grid, after the `ForEach` over `otherRefs`:

```swift
                    if navigation.isConfiguring {
                        AddTilePlaceholder {
                            navigation.presented = .addTile(areaId: room.areaId, surface: .overview)
                        }
                    }
```

**The grid must render when it would otherwise be empty**, or a room whose devices are all hoisted into the climate/media/camera grids has nowhere to put the +. Change the condition from `if !otherRefs.isEmpty` to `if !otherRefs.isEmpty || navigation.isConfiguring`.

In `RoomDetailView`, add the same at the end of the last group, passing `.roomDetail`, with `@Environment(Navigation.self)` added to the view.

- [ ] **Step 5: Build, run the suites, and render — including over content**

Run `xcodegen generate`, build, both suites. Then render:
- `AddTileView`'s previews (add two: a room with candidates, and one with none).
- The gallery's page four, extended with the + tile and the picker.

**And render the sheet over content**, not only at rest — the translucent-banner defect was invisible any other way. A `ZStack` putting `AddTileView` over a bright block is enough to prove its background is opaque.

- [ ] **Step 6: Commit**

```bash
git add App/ && git commit -m "feat(app): a + at the end of a room, offering what it isn't showing"
```

---

## Task 7: The gallery page

**Files:**
- Modify: `App/Renderers/TileGallery.swift`

- [ ] **Step 1: Extend page four**

Add to the `.fourth` branch, after the room-configuration section:

```swift
                    section("Add a device") {
                        VStack(alignment: .leading, spacing: 14) {
                            LazyVGrid(columns: Self.columns, spacing: 10) {
                                DeviceTileView(entityId: "light.on", surface: .overview)
                                AddTilePlaceholder { }
                            }
                            Divider()
                            AddTileView(areaId: "lounge", surface: .overview)
                        }
                    }
```

The picker needs a row to draw, which means the `lounge` area needs an entity the overview is not
showing. Add a second humidity sensor to the fixtures and to the area — the resolver nominates one of
the two for the heading, and `EntityCuration` puts both at `.secondary`, so whichever is not
nominated is exactly an addable candidate:

```swift
        set("sensor.lounge_hum_2", "46", ["friendly_name": .string("Lounge Humidity (window)"),
                                          "device_class": .string("humidity"),
                                          "unit_of_measurement": .string("%")])
```

and in the `lounge` area's `entityIds`, alongside the existing three:

```swift
                         entityIds: ["sensor.lounge_temp", "sensor.lounge_temp_window",
                                     "sensor.lounge_hum", "sensor.lounge_hum_2"],
```

If page four now overflows one screen, split it — a page that overflows has stopped being a baseline, exactly as climate's eight fixtures forced a third page.

- [ ] **Step 2: Render and check**

Render page four. Confirm: the dashed + sits in the grid at the same size as a tile, the picker lists rows with no checkmark column, and the empty-room copy appears where a room has nothing to add.

- [ ] **Step 3: Commit**

```bash
git add App/Renderers/TileGallery.swift
git commit -m "test(app): the + and its picker get looked at"
```

---

## Verification

```bash
cd Packages/HavenCore && swift test          # 677 + 12 = 689
```
Then from the repo root: `xcodegen generate`, build, and `xcodebuild test -scheme HavenApp -destination 'id=<sim>'` (95 + 1 = 96).

Renders: `TileConfigView` ×3, `AddTileView` ×2, gallery page four, and `AddTileView` over a bright block to prove the sheet is opaque.

Manual check against a real Home Assistant, since no test covers the round trip: enter configuration mode, remove a tile from the dashboard, confirm it is still in room detail, add it back from the +, then force-quit and relaunch to confirm the document survived.
