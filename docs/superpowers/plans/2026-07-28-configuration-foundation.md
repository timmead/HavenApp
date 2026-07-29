# Configuration Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an explicit configuration mode with the shared write path every later configuration feature will use, proven end to end by two editable things: a room's temperature/humidity sources, and a device's display name.

**Architecture:** A new `HavenConfig` (App layer, `@Observable`) becomes the single owner of Haven's dashboard document and the only thing that writes it — `EnvironmentCoordinator` keeps nomination *resolution* and routes its write-backs through it. Name resolution moves into HavenCore as a pure, tested rule (`DisplayName`) that every surface goes through. Configuration mode is a flag on `Navigation`, which is session-scoped, so a sign-out or reconnect drops it automatically.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test`/`#expect`), Xcode project + local SPM package `HavenCore`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-28-configuration-foundation-design.md`

## Global Constraints

- **Home Assistant is the source of truth for structure.** Haven never renames or deletes an HA entity. A display name is Haven's own override, stored in Haven's document.
- **Configuration mode is shown only to a confirmed HA admin.** `fetchCurrentUserIsAdmin()` returns `Bool?`; only `true` enables it. `nil` ("we could not find out") hides it, and the resulting cost — an admin with no configuration entry until the next successful connect — is accepted, not a bug to fix later.
- **`DashboardDocument.schema` stays at `1`.** Haven has not shipped; there is nothing to migrate and no older build to signal.
- **One writer per document.** Every write goes through `HavenConfig.update`. Nothing else may call `saveConfig` for the dashboard key.
- **Writes happen per edit**, not batched on exit from configuration mode.
- **No "Automatic" and no "None" in the sensor picker.** Auto-nomination is first-time priming; after that a nomination is an ordinary stored value.
- **Tests use Swift Testing**, not XCTest: `@Test func name()` with `#expect(...)`.
- **Run the two suites separately.** HavenCore: `cd Packages/HavenCore && swift test`. App: the `HavenApp` scheme's tests via Xcode (`mcp__xcode__RunAllTests`), which is the only way the App target's tests run.
- **Doc comments carry the reasoning**, matching this codebase: state *why* a rule exists, especially where the obvious alternative is wrong.

---

## File Structure

**Created:**
- `Packages/HavenCore/Sources/HavenCore/Domain/DisplayName.swift` — the name precedence rule, pure.
- `Packages/HavenCore/Tests/HavenCoreTests/DisplayNameTests.swift`
- `App/HavenConfig.swift` — owns the dashboard document; the only writer.
- `App/Views/RoomConfigView.swift` — the room's sensor pickers.
- `App/Views/TileConfigView.swift` — the device's display name.
- `App/DesignSystem/EntityPickerRow.swift` — shared picker row (bold name over entity id).
- `Tests/HavenAppTests/HavenConfigTests.swift` — write path and gating.

**Modified:**
- `Packages/HavenCore/Sources/HavenCore/Config/DashboardDocument.swift` — the `entities` subtree.
- `Packages/HavenCore/Tests/HavenCoreTests/DashboardDocumentTests.swift`
- `App/EnvironmentCoordinator.swift` — keeps resolution, gives up ownership of the document.
- `App/HomeStore.swift` — owns `HavenConfig`; gains `displayName(of:)`.
- `App/Navigation.swift` — configuration flag and one presentation enum.
- `App/Views/DashboardView.swift` — menu entry, Done control, editing banner, sheet routing.
- `App/Views/RoomSectionView.swift` — room title becomes a configuration target in the mode.
- `App/Renderers/TileName.swift` — `of` is deleted; `words` delegates to `DisplayName`.
- 21 tile/modal files — name resolution routed through the store (Task 7).

---

## Task 1: The name precedence rule

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Domain/DisplayName.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/DisplayNameTests.swift`
- Modify: `App/Renderers/TileName.swift`

**Interfaces:**
- Produces: `DisplayName.resolve(override:friendlyName:entityId:) -> String`, `DisplayName.words(_:) -> String`. Task 2 stores the override, Task 6 supplies it, Task 7 routes every surface through it.

- [ ] **Step 1: Write the failing test**

Create `Packages/HavenCore/Tests/HavenCoreTests/DisplayNameTests.swift`:

```swift
import Foundation
import Testing
@testable import HavenCore

@Test func theOverrideOutranksHomeAssistantsOwnName() {
    #expect(DisplayName.resolve(override: "Reading Lamp",
                                friendlyName: "Kitchen Light",
                                entityId: "light.kitchen") == "Reading Lamp")
}

@Test func withoutAnOverrideHomeAssistantsNameWins() {
    #expect(DisplayName.resolve(override: nil,
                                friendlyName: "Kitchen Light",
                                entityId: "light.kitchen") == "Kitchen Light")
}

@Test func withNeitherTheNameIsDerivedFromTheEntityId() {
    #expect(DisplayName.resolve(override: nil, friendlyName: nil,
                                entityId: "light.kitchen_bench") == "Kitchen Bench")
}

/// Clearing the field in the rename sheet must reset to Home Assistant's name rather than render a
/// blank tile — so an override that is empty, or only whitespace, is treated as no override at all.
/// The same rule applies to `friendly_name`, which Home Assistant can carry as an empty string.
@Test func blankNamesAreTreatedAsAbsentAtEveryRung() {
    #expect(DisplayName.resolve(override: "", friendlyName: "Kitchen Light",
                                entityId: "light.kitchen") == "Kitchen Light")
    #expect(DisplayName.resolve(override: "   ", friendlyName: "Kitchen Light",
                                entityId: "light.kitchen") == "Kitchen Light")
    #expect(DisplayName.resolve(override: nil, friendlyName: "  ",
                                entityId: "light.kitchen") == "Kitchen")
}

@Test func namesAreTrimmedBeforeUse() {
    #expect(DisplayName.resolve(override: "  Reading Lamp  ", friendlyName: nil,
                                entityId: "light.kitchen") == "Reading Lamp")
}

@Test func snakeCaseTokensRenderAsWords() {
    #expect(DisplayName.words("heat_cool") == "Heat Cool")
    #expect(DisplayName.words("fan_only") == "Fan Only")
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd Packages/HavenCore && swift test --filter DisplayName`
Expected: FAIL — `cannot find 'DisplayName' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Packages/HavenCore/Sources/HavenCore/Domain/DisplayName.swift`:

```swift
import Foundation

/// What a device is called, in one place.
///
/// Three rungs, highest first:
///
/// 1. **Haven's own override** — what the user typed in configuration mode.
/// 2. **Home Assistant's `friendly_name`.**
/// 3. **The entity id**, rendered as words.
///
/// The override outranking Home Assistant is the deliberate part, and it has a consequence worth
/// naming: renaming the entity in HA afterwards will *not* show up in Haven. An explicit choice
/// outranks a default, which is the right precedence — and it is why the rename sheet shows what HA
/// calls the device underneath, so an override reads as an override rather than as a mystery.
///
/// A rule rather than a chain inside a view, because the whole app has to agree on it: tiles,
/// modals, accessibility labels, and every picker row. It was previously three lines inside
/// `TileName.of` that no test could reach.
public enum DisplayName {
    /// The name to show. `override` and `friendlyName` are both treated as absent when blank —
    /// clearing the rename field must reset to Home Assistant's name, not render an empty tile,
    /// and HA itself can carry `friendly_name` as an empty string.
    public static func resolve(override: String?, friendlyName: String?, entityId: String) -> String {
        if let override = present(override) { return override }
        if let friendly = present(friendlyName) { return friendly }
        return words(String(entityId.drop(while: { $0 != "." }).dropFirst()))
    }

    /// Renders a raw HA-style snake_case token (`"heat_cool"`, `"kitchen_light"`) for display:
    /// underscores become spaces, then each word is capitalized. Shared by the entity-id rung above
    /// and by mode/enum strings shown verbatim from HA (climate hvac/fan modes), so neither renders
    /// "Heat_cool".
    public static func words(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func present(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `cd Packages/HavenCore && swift test --filter DisplayName`
Expected: PASS, 6 tests.

- [ ] **Step 5: Point `TileName.words` at the new rule**

`TileName.of` is left alone in this task — Task 7 deletes it. Only `words` is redirected, so there is one implementation of the snake_case rendering rather than two.

Replace the body of `words` in `App/Renderers/TileName.swift`:

```swift
    /// Delegates to `DisplayName.words`, which is the same rendering under test in HavenCore.
    /// Kept as a name here because ~10 call sites render HA mode strings (`heat_cool`, `fan_only`)
    /// through it and none of them are about a device's *name*.
    static func words(_ raw: String) -> String { DisplayName.words(raw) }
```

- [ ] **Step 6: Build and run both suites**

Run: `cd Packages/HavenCore && swift test`, then `mcp__xcode__BuildProject` and `mcp__xcode__RunAllTests`.
Expected: HavenCore 671 passing (665 + 6), app tests 88 passing.

- [ ] **Step 7: Commit**

```bash
git add Packages/HavenCore/Sources/HavenCore/Domain/DisplayName.swift \
        Packages/HavenCore/Tests/HavenCoreTests/DisplayNameTests.swift \
        App/Renderers/TileName.swift
git commit -m "feat(core): one rule for what a device is called"
```

---

## Task 2: The `entities` subtree

**Files:**
- Modify: `Packages/HavenCore/Sources/HavenCore/Config/DashboardDocument.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/DashboardDocumentTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `DashboardDocument.displayNames: [String: String]` and `DashboardDocument.settingDisplayName(_ name: String?, for entityId: String) -> DashboardDocument`. Passing `nil` (or a blank string) removes the override. Task 3 writes through it; Task 6 calls it.

- [ ] **Step 1: Write the failing tests**

Append to `Packages/HavenCore/Tests/HavenCoreTests/DashboardDocumentTests.swift`:

```swift
// MARK: - Display names

@Test func aDisplayNameRoundTrips() {
    let doc = DashboardDocument().settingDisplayName("Reading Lamp", for: "light.kitchen")
    #expect(doc.displayNames == ["light.kitchen": "Reading Lamp"])
}

/// The property this whole type exists to defend, extended to the new subtree: a build that knows
/// about `entities` must not strip what a newer build wrote — neither unknown top-level keys, nor
/// unknown keys *inside* an entity it is editing.
@Test func writingANameKeepsEveryKeyItDoesNotOwn() {
    let raw = JSONValue.object([
        "schema": .int(1),
        "tiles": .object(["order": .array([.string("light.kitchen")])]),
        "entities": .object([
            "light.kitchen": .object(["name": .string("Old"), "icon": .string("mdi:lamp")]),
            "light.hall": .object(["name": .string("Hall")]),
        ]),
    ])
    let doc = DashboardDocument(raw: raw).settingDisplayName("New", for: "light.kitchen")
    let root = doc.raw.asObject
    #expect(root?["tiles"] != nil)
    let kitchen = root?["entities"]?.asObject?["light.kitchen"]?.asObject
    #expect(kitchen?["name"]?.asString == "New")
    #expect(kitchen?["icon"]?.asString == "mdi:lamp")
    #expect(root?["entities"]?.asObject?["light.hall"]?.asObject?["name"]?.asString == "Hall")
}

/// Clearing an override deletes the key rather than storing an empty string, so the document does
/// not accumulate a tombstone per device the user ever renamed and changed their mind about.
@Test func clearingANameRemovesTheKeyButKeepsTheEntitysOtherKeys() {
    let raw = JSONValue.object([
        "entities": .object(["light.kitchen": .object(["name": .string("Old"),
                                                       "icon": .string("mdi:lamp")])]),
    ])
    let doc = DashboardDocument(raw: raw).settingDisplayName(nil, for: "light.kitchen")
    #expect(doc.displayNames.isEmpty)
    #expect(doc.raw.asObject?["entities"]?.asObject?["light.kitchen"]?.asObject?["icon"]?.asString == "mdi:lamp")
}

/// A blank name is the same instruction as clearing it — see `DisplayName`, which treats a
/// whitespace-only override as absent. Storing it would leave a document whose name is present but
/// means nothing.
@Test func aBlankNameClearsRatherThanStores() {
    let doc = DashboardDocument()
        .settingDisplayName("Reading Lamp", for: "light.kitchen")
        .settingDisplayName("   ", for: "light.kitchen")
    #expect(doc.displayNames.isEmpty)
}

@Test func namesAndNominationsDoNotDisturbEachOther() {
    let doc = DashboardDocument()
        .merging(["living": RoomEnvironmentOverride(
            temperature: UpliftedSensor(role: .temperature, entityId: "sensor.t", source: .state))])
        .settingDisplayName("Reading Lamp", for: "light.kitchen")
    #expect(doc.nominations["living"]?.temperature?.entityId == "sensor.t")
    #expect(doc.displayNames["light.kitchen"] == "Reading Lamp")
}

@Test func aMalformedEntitiesSubtreeIsIgnoredNotFatal() {
    let raw = JSONValue.object(["entities": .string("nonsense")])
    #expect(DashboardDocument(raw: raw).displayNames.isEmpty)
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `cd Packages/HavenCore && swift test --filter DashboardDocument`
Expected: FAIL — `value of type 'DashboardDocument' has no member 'settingDisplayName'`.

- [ ] **Step 3: Write the implementation**

In `DashboardDocument.swift`, add beside `private static let roomsKey`:

```swift
    private static let entitiesKey = "entities"
    private static let nameKey = "name"
```

And add these members after `merging(_:)`:

```swift
    /// Haven's own display names, keyed by entity id.
    ///
    /// At the document root rather than under a room, deliberately: an entity's name does not depend
    /// on which room it is in, and moving a device between areas in Home Assistant must not silently
    /// lose the name a user gave it.
    ///
    /// Blank stored names are dropped on the way out as well as refused on the way in — a document
    /// written by hand, or by a build with a different idea of blankness, must not produce a nameless
    /// tile. `DisplayName` applies the same rule at the point of use.
    public var displayNames: [String: String] {
        guard let entities = raw.asObject?[Self.entitiesKey]?.asObject else { return [:] }
        return entities.compactMapValues { entity in
            guard let name = entity.asObject?[Self.nameKey]?.asString,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return name
        }
    }

    /// This document with one entity's display name set, or — for a `nil` or blank name — removed.
    ///
    /// One entity at a time rather than a bulk merge, because that is how the feature works: a
    /// rename sheet edits one device. It merges at every level for the reason in the type's doc
    /// comment, so an entity's other keys (an icon, a tile size, whatever a later build adds) survive
    /// a rename, and clearing a name removes only that key rather than the entity's whole record.
    public func settingDisplayName(_ name: String?, for entityId: String) -> DashboardDocument {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        var root = raw.asObject ?? [:]
        root[Self.schemaKey] = .int(max(declaredSchema, Self.schema))
        var entities = root[Self.entitiesKey]?.asObject ?? [:]
        var entity = entities[entityId]?.asObject ?? [:]
        if let trimmed, !trimmed.isEmpty {
            entity[Self.nameKey] = .string(trimmed)
        } else {
            entity.removeValue(forKey: Self.nameKey)
        }
        // An entity record holding nothing at all is removed outright, so clearing the only name a
        // device ever had leaves the document exactly as it started rather than a shell keyed by
        // every entity anyone has ever opened.
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
Expected: PASS — the 10 existing tests plus 6 new ones.

- [ ] **Step 5: Commit**

```bash
git add Packages/HavenCore/Sources/HavenCore/Config/DashboardDocument.swift \
        Packages/HavenCore/Tests/HavenCoreTests/DashboardDocumentTests.swift
git commit -m "feat(core): the dashboard document carries Haven's own display names"
```

---

## Task 3: `HavenConfig`, the single writer

**Files:**
- Create: `App/HavenConfig.swift`
- Modify: `App/EnvironmentCoordinator.swift`, `App/HomeStore.swift`
- Test: `Tests/HavenAppTests/HavenConfigTests.swift` (create)

**Interfaces:**
- Consumes: `DashboardDocument.settingDisplayName(_:for:)` (Task 2).
- Produces:
  - `HavenConfig.document: DashboardDocument`
  - `HavenConfig.isLoaded: Bool`, `HavenConfig.isAdmin: Bool?`, `HavenConfig.canConfigure: Bool`
  - `HavenConfig.load() async -> Void`
  - `HavenConfig.update(_ mutate: @MainActor (DashboardDocument) -> DashboardDocument) async -> HavenConfig.Outcome`
  - `enum Outcome { case written, unchanged, notAuthorized, failed }`
  - `EnvironmentCoordinator.resolve(home:states:document:)` — now takes the document
  - `HomeStore.config: HavenConfig`

- [ ] **Step 1: Write the failing tests**

Create `Tests/HavenAppTests/HavenConfigTests.swift`. It reuses the scripted-socket shape from `DashboardConfigWriteBackTests`; copy that file's `ScriptedSocket`, `fixtureRegistry`, `fixtureStates`, `ok`, `absent` and `decode` helpers into this file as `private` (the two files cannot share privates, and duplicating a 40-line fake is cheaper than a shared test-support target for two callers).

```swift
@Suite @MainActor struct HavenConfigTests {

    /// `canConfigure` is the whole gate on configuration mode, and every one of its inputs denies
    /// on its own. Written as one test over the matrix because the interesting property is that
    /// *each* is sufficient to deny — a version that ANDed two of them would pass any single-case
    /// test.
    @Test func everyGateDeniesConfigurationOnItsOwn() {
        let config = HavenConfig()
        // Nothing attached, nothing loaded, no admin answer: denied three times over.
        #expect(!config.canConfigure)

        config.setForTesting(isAdmin: true, isLoaded: true, isWritable: true, isConnected: true)
        #expect(config.canConfigure)

        config.setForTesting(isAdmin: false, isLoaded: true, isWritable: true, isConnected: true)
        #expect(!config.canConfigure)
        config.setForTesting(isAdmin: nil, isLoaded: true, isWritable: true, isConnected: true)
        #expect(!config.canConfigure)      // "could not find out" is not a yes
        config.setForTesting(isAdmin: true, isLoaded: false, isWritable: true, isConnected: true)
        #expect(!config.canConfigure)      // editing over an unread document overwrites it
        config.setForTesting(isAdmin: true, isLoaded: true, isWritable: false, isConnected: true)
        #expect(!config.canConfigure)
        config.setForTesting(isAdmin: true, isLoaded: true, isWritable: true, isConnected: false)
        #expect(!config.canConfigure)      // every edit is a write
    }

    /// A write that changes nothing must not reach the socket at all: a no-op write churns the
    /// shared record's version and `updated_by` for nothing, which is what the household sees as
    /// "someone edited the dashboard".
    @Test func aMutationThatChangesNothingSendsNoFrame() async throws {
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get": return absent(id)
            case "havenapp/config/set": return ok(id)
            default: return nil
            }
        }
        let before = await socket.frameTexts(ofType: "havenapp/config/set").count
        let outcome = await store.config.update { $0 }
        #expect(outcome == .unchanged)
        #expect(await socket.frameTexts(ofType: "havenapp/config/set").count == before)
    }

    /// A version conflict means another admin's phone wrote first. The mutation is reapplied to
    /// *their* document — not to ours, which would discard their change — and retried once.
    @Test func aConflictReappliesTheEditToTheOtherPhonesDocumentAndRetriesOnce() async throws {
        let conflicted = LockedBox(false)
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get": return absent(id)
            case "havenapp/config/set":
                // The bootstrap's own nomination write goes through; the *next* one conflicts once.
                if conflicted.takeIfUnset() {
                    return #"""
                    {"id":\#(id),"type":"result","success":true,"result":{"status":"version_conflict",
                     "current":{"version":7,"payload":{"schema":1,
                     "entities":{"light.hall":{"name":"Hall"}}},"updated":"2026-07-28T00:00:00+00:00"}}}
                    """#
                }
                return #"{"id":\#(id),"type":"result","success":true,"result":{"status":"ok","version":8}}"#
            default: return nil
            }
        }
        let outcome = await store.config.update { $0.settingDisplayName("Lamp", for: "light.kitchen") }
        #expect(outcome == .written)
        // Their name survived ours: the retry was applied to their document, not to the stale one.
        #expect(store.config.document.displayNames["light.hall"] == "Hall")
        #expect(store.config.document.displayNames["light.kitchen"] == "Lamp")
        let writes = await socket.frameTexts(ofType: "havenapp/config/set").compactMap(decode)
        #expect(writes.last?["base_version"] as? Int == 7)
    }

    /// Not an admin is an expected steady state for a household member, not a fault: it is reported
    /// as an outcome the caller can explain, never thrown or logged as an error.
    @Test func aRefusedWriteIsReportedAsNotAuthorized() async throws {
        let (store, _) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get": return absent(id)
            case "havenapp/config/set":
                return #"""
                {"id":\#(id),"type":"result","success":false,
                 "error":{"code":"not_authorized","message":"admin required"}}
                """#
            default: return nil
            }
        }
        let outcome = await store.config.update { $0.settingDisplayName("Lamp", for: "light.kitchen") }
        #expect(outcome == .notAuthorized)
        // And the refusal closes the door behind it: the spec requires leaving configuration mode,
        // which happens because `canConfigure` goes false and `DashboardView` watches it. Wiring it
        // through `isAdmin` rather than through each sheet is what makes that automatic.
        #expect(store.config.isAdmin == false)
        #expect(!store.config.canConfigure)
    }

    /// A document that could not be read leaves `isLoaded` false — which is what stops the mode
    /// being entered at all. The distinction from an *absent* record (an ordinary first run, which
    /// loads fine) is the whole point.
    @Test func anUnreadableDocumentIsNotLoadedButAnAbsentOneIs() async throws {
        let (absentStore, _) = try await boot { id, type, _ in
            type == "havenapp/config/get" ? absent(id) : ok(id)
        }
        #expect(absentStore.config.isLoaded)

        let (brokenStore, _) = try await boot { id, type, _ in
            guard type == "havenapp/config/get" else { return ok(id) }
            return #"""
            {"id":\#(id),"type":"result","success":false,
             "error":{"code":"unknown_error","message":"nope"}}
            """#
        }
        #expect(!brokenStore.config.isLoaded)
    }
}

/// A one-shot flag usable from the socket's `@Sendable` responder.
private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var taken: Bool
    init(_ taken: Bool) { self.taken = taken }
    /// True exactly once — the second call and every one after it returns false.
    func takeIfUnset() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
```

Add `boot` to the suite, identical in shape to `DashboardConfigWriteBackTests.boot` but also answering the admin probe:

```swift
    private func boot(
        config: @escaping @Sendable (Int, String, [String: Any]) -> String?
    ) async throws -> (HomeStore, ScriptedSocket) {
        let socket = ScriptedSocket()
        await socket.setResponder { id, type, msg in
            if let body = fixtureRegistry[type] {
                return #"{"id":\#(id),"type":"result","success":true,"result":\#(body)}"#
            }
            switch type {
            case "get_states":
                return #"{"id":\#(id),"type":"result","success":true,"result":\#(fixtureStates)}"#
            case "subscribe_events":
                return #"{"id":\#(id),"type":"result","success":true,"result":null}"#
            case "auth/current_user":
                return #"{"id":\#(id),"type":"result","success":true,"result":{"is_admin":true}}"#
            default:
                return config(id, type, msg)
            }
        }
        await socket.enqueue(#"{"type":"auth_required"}"#)
        await socket.enqueue(#"{"type":"auth_ok"}"#)
        let client = HAWebSocketClient(connection: socket)
        try await client.authenticate(token: "t")
        let store = HomeStore()
        store.attach(HomeConnection(client: client))
        try await store.bootstrap()
        return (store, socket)
    }
```

- [ ] **Step 2: Run them and watch them fail**

Run: `mcp__xcode__RunAllTests`
Expected: FAIL to compile — `cannot find 'HavenConfig' in scope`.

- [ ] **Step 3: Write `HavenConfig`**

Create `App/HavenConfig.swift`:

```swift
import SwiftUI
import HavenCore

/// Haven's own configuration — the dashboard document — and the **only** thing that writes it.
///
/// Home Assistant owns the home: the devices, their readings, and which room they are in. This owns
/// the thin layer on top that HA has no opinion about — which of a room's several temperature
/// sources is *the* room's, and what the user calls a device.
///
/// **One writer, deliberately.** Two components each doing their own read-modify-write against one
/// versioned record means two retry loops racing on one version, and the loser silently reapplies
/// stale state. `EnvironmentCoordinator` used to own the document and its write path; it now keeps
/// the *resolution* — a domain rule — and routes its write-backs through `update` like everything
/// else.
@MainActor @Observable
final class HavenConfig {
    static let dashboardKey = "dashboard"

    /// The result of a write. An enum rather than a throw because `notAuthorized` is not a failure:
    /// only HA admins curate the shared dashboard, and for everyone else in the household that is
    /// the expected steady state. Callers explain it; nothing logs it as an error.
    enum Outcome: Equatable { case written, unchanged, notAuthorized, failed }

    private(set) var document = DashboardDocument()
    /// The version the held document was read at, and the base version of the next write.
    private(set) var version = 0
    /// Whether the document was *read*. False after a failure to read, and — critically — true for a
    /// home that simply has no configuration yet. Editing over a document we could not read is how a
    /// household's configuration gets overwritten, so this gates the mode.
    private(set) var isLoaded = false
    /// From `auth/current_user`. `nil` means the question could not be answered, which is not a yes:
    /// see `canConfigure`.
    private(set) var isAdmin: Bool?

    private var connection: HomeConnection?

    func attach(_ connection: HomeConnection?) {
        self.connection = connection
        isAdmin = nil
        isLoaded = false
    }

    func reset() {
        connection = nil
        document = DashboardDocument()
        version = 0
        isLoaded = false
        isAdmin = nil
    }

    /// Whether configuration mode may be entered at all.
    ///
    /// Five conditions, each sufficient to deny on its own, and each denying for a different reason:
    ///
    /// - **not a confirmed admin** — the `shared` scope is admin-writable only, and `nil` ("could not
    ///   find out") is not a yes. The cost is accepted: an admin whose probe failed has no
    ///   configuration entry until the next connect. The alternative offers a household member a
    ///   control that cannot act.
    /// - **not loaded** — see `isLoaded`.
    /// - **not writable** — a newer build wrote this document and we cannot know its invariants.
    /// - **not connected** — every edit is a write.
    var canConfigure: Bool {
        isAdmin == true && isLoaded && document.isWritable && connection != nil
    }

    /// Reads the shared dashboard record. Never throws: a configuration the app could not read must
    /// not take the dashboard down with it — the user still sees their home, they just cannot edit
    /// it.
    func load() async {
        guard let connection else { return }
        do {
            let record = try await connection.loadConfig(scope: HavenConfigScope.shared,
                                                         key: Self.dashboardKey)
            // An absent record is a successful read of a home with no configuration yet — the
            // ordinary first run — and must count as loaded. Only a throw means "we could not find
            // out".
            document = DashboardDocument(raw: record?.payload)
            version = record?.version ?? 0
            isLoaded = true
        } catch {
            havenLog.error("dashboard config unreadable: \(error)")
            document = DashboardDocument()
            version = 0
            isLoaded = false
        }
        isAdmin = await connection.fetchCurrentUserIsAdmin()
    }

    /// Applies an edit to the document and saves it.
    ///
    /// `mutate` is a *function of the current document* rather than a finished document, because a
    /// version conflict means someone else wrote first and the edit has to be reapplied to **their**
    /// document — applying our stale one would discard their change. That is also why the retry
    /// re-invokes the closure instead of resending the payload.
    ///
    /// One retry, then give up. A second conflict means a genuinely busy document, and nothing here
    /// is time-critical enough to spin on.
    @discardableResult
    func update(_ mutate: @MainActor (DashboardDocument) -> DashboardDocument) async -> Outcome {
        await attemptUpdate(mutate, isRetry: false)
    }

    private func attemptUpdate(_ mutate: @MainActor (DashboardDocument) -> DashboardDocument,
                               isRetry: Bool) async -> Outcome {
        guard let connection, document.isWritable else { return .failed }
        let merged = mutate(document)
        // A no-op write would churn the shared record's version and `updated_by` for nothing, which
        // the rest of the household sees as somebody editing the dashboard.
        guard merged != document else { return .unchanged }
        do {
            switch try await connection.saveConfig(scope: HavenConfigScope.shared,
                                                   key: Self.dashboardKey,
                                                   baseVersion: version, payload: merged.raw) {
            case .ok(let newVersion):
                document = merged
                version = newVersion
                return .written
            case .versionConflict(let current):
                document = DashboardDocument(raw: current?.payload)
                version = current?.version ?? 0
                guard !isRetry else { return .failed }
                return await attemptUpdate(mutate, isRetry: true)
            }
        } catch let error as WSError where error.isNotAuthorized {
            // New evidence about a question we thought we had answered: this user is not an admin
            // after all, or has just been demoted. Recording it here is what makes the mode close
            // itself — `canConfigure` goes false, and `DashboardView` watches that — so the spec's
            // "explain and leave configuration mode" needs no separate wiring in each sheet.
            isAdmin = false
            return .notAuthorized
        } catch {
            havenLog.error("could not write dashboard config: \(error)")
            return .failed
        }
    }
}

#if DEBUG
extension HavenConfig {
    /// Drives `canConfigure`'s inputs directly, so the gate can be tested without four sockets.
    /// `isConnected` cannot be faked without a live `HomeConnection`, so it is modelled here as the
    /// same absence the property reads.
    func setForTesting(isAdmin: Bool?, isLoaded: Bool, isWritable: Bool, isConnected: Bool) {
        self.isAdmin = isAdmin
        self.isLoaded = isLoaded
        self.document = isWritable
            ? DashboardDocument()
            : DashboardDocument(raw: .object(["schema": .int(DashboardDocument.schema + 1)]))
        self.connection = isConnected ? HomeConnection(client: HAWebSocketClient(connection: NullSocket())) : nil
    }
}

/// A socket that never answers. Only ever used to make `connection != nil` true in a gate test.
private struct NullSocket: WebSocketConnection {
    func connect() async throws {}
    func close() {}
    func send(_ data: Data) async throws {}
    func receive() async throws -> Data { try await Task.sleep(for: .seconds(3600)); return Data() }
}
#endif
```

- [ ] **Step 4: Move the document out of `EnvironmentCoordinator`**

In `App/EnvironmentCoordinator.swift`: delete the `dashboardKey` constant, the `dashboard` property, `load(home:states:)` and `persistProposedNominations(...)`. Keep `byArea`, `attach`, `reset`. Change `resolve` to take the document, and add a write-back that routes through `HavenConfig`:

```swift
    /// Resolves every room's environment from the current registry, the current states and the
    /// household's dashboard document.
    ///
    /// The document is a parameter rather than a stored property now that `HavenConfig` owns it:
    /// this type decides *which sensor is the room's*, which is a domain rule, and owns none of the
    /// storage that decision is read from or written to.
    func resolve(home: ResolvedHome, states: [String: EntityState], document: DashboardDocument) {
        byArea = RoomEnvironmentResolver.resolve(
            home: home,
            sources: states.mapValues(RoomEnvironmentSource.init),
            stored: document.nominations,
            isReadable: { sensor in
                EnvironmentReading.value(sensor, state: states[sensor.entityId]) != nil
            })
    }

    /// Resolves against the current document and writes back any nomination this device *proposed*
    /// — the auto-pick that primes a room the first time Haven sees it.
    ///
    /// The mutation re-resolves rather than closing over a finished set of proposals, because
    /// `HavenConfig.update` may hand it a *different* document on a conflict retry: another admin's
    /// phone may have nominated the same rooms first, and proposing over their picks would undo
    /// them. Re-resolving means the retry proposes only what is still unproposed.
    func loadAndPropose(home: ResolvedHome, states: [String: EntityState],
                        config: HavenConfig) async {
        resolve(home: home, states: states, document: config.document)
        await config.update { [weak self] document in
            guard let self else { return document }
            self.resolve(home: home, states: states, document: document)
            let proposals = self.byArea.compactMapValues(\.nominationsToPersist)
            return proposals.isEmpty ? document : document.merging(proposals)
        }
    }
```

- [ ] **Step 5: Wire it into `HomeStore`**

In `App/HomeStore.swift`:

```swift
    /// Haven's own configuration document and the only writer of it — see `HavenConfig`.
    let config = HavenConfig()
```

In `attach(_:)`, add `config.attach(connection)` beside the other two. In `reset()`, add `config.reset()`.

Replace the last line of `bootstrap()`:

```swift
        // Config first, then resolve-and-propose against it. `HavenConfig.load` swallows its own
        // errors (see its doc comment), so a configuration problem still cannot fail `bootstrap()`.
        await config.load()
        await environmentCoordinator.loadAndPropose(home: home, states: states, config: config)
```

And update `resolveEnvironment()`:

```swift
    func resolveEnvironment() {
        environmentCoordinator.resolve(home: home, states: states, document: config.document)
    }
```

- [ ] **Step 6: Run every test**

Run: `mcp__xcode__BuildProject`, then `mcp__xcode__RunAllTests`.
Expected: PASS. **`DashboardConfigWriteBackTests` must pass unmodified** — it is the safety property for this refactor: same frames, same base versions, same conflict behaviour. If it fails, the refactor changed behaviour and the refactor is wrong, not the test.

- [ ] **Step 7: Commit**

```bash
git add App/HavenConfig.swift App/EnvironmentCoordinator.swift App/HomeStore.swift \
        Tests/HavenAppTests/HavenConfigTests.swift
git commit -m "refactor(app): one owner, and one writer, for Haven's configuration"
```

---

## Task 4: The mode shell

**Files:**
- Modify: `App/Navigation.swift`, `App/Views/DashboardView.swift`, `App/Views/RoomSectionView.swift`
- Modify: every tile that writes `navigation.presentedEntityId` (see Step 3)

**Interfaces:**
- Consumes: `HavenConfig.canConfigure` (Task 3).
- Produces: `Navigation.isConfiguring: Bool`, `Navigation.presented: Navigation.Presentation?`, and `Navigation.open(_ entityId: String)` — the call every tile makes, which routes to control or configuration depending on the mode.

- [ ] **Step 1: Rewrite `Navigation`**

```swift
@MainActor @Observable
final class Navigation {
    /// What is on screen above the dashboard. One value, not one flag per sheet: two independent
    /// booleans can both be true, and SwiftUI will present whichever it notices first while the
    /// other silently does nothing.
    enum Presentation: Equatable {
        /// The device's controls — the ordinary tap or long-press outside configuration mode.
        case control(entityId: String)
        /// The device's configuration — what a tap does *in* configuration mode.
        case tileConfig(entityId: String)
        /// A room's configuration, from its title.
        case roomConfig(areaId: String)
    }

    var presented: Presentation?

    /// Whether the dashboard is being configured. Lives here rather than in `DashboardView`'s own
    /// state for the reason this whole type exists: `Navigation` is owned by the view that only
    /// exists while `phase == .ready`, so a sign-out, reauthentication or reconnect drops
    /// configuration mode on the way past instead of leaving a half-edited dashboard behind a
    /// login screen.
    var isConfiguring = false

    /// What a tile's activation means, resolved in one place: its controls normally, its
    /// configuration while configuring. Tiles call this instead of writing `presented` directly, so
    /// a new tile cannot forget the mode and silently stay live during configuration.
    func open(_ entityId: String) {
        presented = isConfiguring ? .tileConfig(entityId: entityId) : .control(entityId: entityId)
    }
}
```

- [ ] **Step 2: Update every tile's activation**

Every tile currently assigns `navigation.presentedEntityId = entityId`. Replace each with `navigation.open(entityId)` — **both** the tap and the long-press assignments, so a long press in configuration mode opens the tile's configuration rather than becoming a dead gesture.

Find them: `grep -rn "presentedEntityId" App/`

Files and their gestures:
- `Tiles/LightTile.swift`, `Tiles/SwitchTile.swift`, `Tiles/CoverTile.swift`, `Tiles/LockTile.swift` — long-press (their tap commands the device).
- `Tiles/ClimateTile.swift` — both tap and long-press.
- `Tiles/CameraTile.swift` — both tap and long-press.
- `Tiles/SceneTile.swift`, `Tiles/SensorTile.swift`, `Tiles/BinarySensorTile.swift`, `Tiles/GenericTile.swift` — per file; follow the existing gesture.
- `Tiles/MediaPlayerTile.swift` — the `.accessibilityAction(named: "Open controls")` and the long-press.
- `Renderers/DeviceTileView.swift` — no change; it dispatches only.

**A tile whose tap commands the device must not command it in configuration mode.** For those tiles (light, switch, cover, lock, and the climate tile's power and stepper buttons), wrap the command in the mode check:

```swift
.onTapGesture { navigation.isConfiguring ? navigation.open(entityId) : store.toggle(entityId) }
```

Use each tile's own existing command call in place of `store.toggle(entityId)`.

- [ ] **Step 3: Update `DashboardView`**

Replace the sheet binding and add the toolbar:

```swift
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if navigation.isConfiguring {
                        Button("Done") { navigation.isConfiguring = false }
                            .fontWeight(.semibold)
                    } else {
                        Menu {
                            // Shown only to a confirmed HA admin with a document we actually read.
                            // Omitted rather than disabled, which is this app's rule for a control
                            // that cannot act — see `HavenConfig.canConfigure` for each denial.
                            if store.config.canConfigure {
                                Button("Edit Dashboard", systemImage: "slider.horizontal.3") {
                                    navigation.isConfiguring = true
                                }
                            }
                            Button("Connection", systemImage: "wifi") {
                                showingConnectionSettings = true
                            }
                            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right",
                                   role: .destructive) {
                                Task { await app.signOut() }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
```

Replace the sheet:

```swift
        .sheet(item: Binding(get: { navigation.presented },
                             set: { navigation.presented = $0 })) { presentation in
            switch presentation {
            case .control(let id): DeviceModalView(entityId: id)
            case .tileConfig(let id): TileConfigView(entityId: id)
            case .roomConfig(let areaId): RoomConfigView(areaId: areaId)
            }
        }
```

`Presentation` needs `Identifiable` for `sheet(item:)`. Add to `Navigation`:

```swift
extension Navigation.Presentation: Identifiable {
    /// Identity includes the case, not just the entity id: opening a tile's *configuration* while
    /// its *controls* are open must be a different sheet, not the same one relabelled.
    var id: String {
        switch self {
        case .control(let id): return "control:\(id)"
        case .tileConfig(let id): return "tileConfig:\(id)"
        case .roomConfig(let areaId): return "roomConfig:\(areaId)"
        }
    }
}
```

Add the editing banner as a safe-area inset above the floor bar, so it is impossible to miss which mode you are in:

```swift
        .safeAreaInset(edge: .top) {
            if navigation.isConfiguring {
                Text("Editing dashboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(HavenColor.domain(.cover))
            }
        }
```

Add a guard so the mode cannot outlive its own preconditions — an admin demoted mid-session, or a dropped connection:

```swift
        .onChange(of: store.config.canConfigure) { _, canConfigure in
            if !canConfigure { navigation.isConfiguring = false }
        }
```

- [ ] **Step 4: Make the room title a configuration target**

In `App/Views/RoomSectionView.swift`, the heading is wrapped in a `NavigationLink(value: room.id)`. In configuration mode it must open room configuration instead of pushing room detail:

```swift
            if navigation.isConfiguring {
                Button {
                    navigation.presented = .roomConfig(areaId: room.areaId)
                } label: {
                    roomHeading
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(value: room.id) { roomHeading }
                    .buttonStyle(.plain)
            }
```

Extract the existing `HStack` of name + `RoomEnvironmentChips` into a `private var roomHeading: some View` so both branches render exactly the same thing. Add `@Environment(Navigation.self) private var navigation` to the view.

- [ ] **Step 5: Build and check the mode by rendering**

Run: `mcp__xcode__BuildProject`, then `mcp__xcode__RunAllTests` (expected: still 88 + the new `HavenConfigTests`).

The two sheet views do not exist yet, so this step will not compile until Tasks 5 and 6 land. **Write empty placeholder views first** so the mode is testable on its own:

```swift
// App/Views/RoomConfigView.swift
struct RoomConfigView: View { let areaId: String; var body: some View { Text(areaId) } }
// App/Views/TileConfigView.swift
struct TileConfigView: View { let entityId: String; var body: some View { Text(entityId) } }
```

- [ ] **Step 6: Commit**

```bash
git add App/Navigation.swift App/Views/DashboardView.swift App/Views/RoomSectionView.swift \
        App/Views/RoomConfigView.swift App/Views/TileConfigView.swift App/Renderers/Tiles/
git commit -m "feat(app): an explicit configuration mode, for admins with a document we read"
```

---

## Task 5: Room configuration

**Files:**
- Create: `App/DesignSystem/EntityPickerRow.swift`
- Rewrite: `App/Views/RoomConfigView.swift`
- Modify: `App/HomeStore.swift`

**Interfaces:**
- Consumes: `HavenConfig.update` (Task 3), `Navigation.Presentation.roomConfig` (Task 4), `DisplayName.resolve` (Task 1).
- Produces: `EntityPickerRow(title:entityId:detail:isSelected:)`, and `HomeStore.nominate(_ sensor: UpliftedSensor, areaId: String) async -> HavenConfig.Outcome`.

- [ ] **Step 1: Write the picker row**

Create `App/DesignSystem/EntityPickerRow.swift`:

```swift
import SwiftUI

/// One row of an entity picker: what the thing is called, over the id that identifies it.
///
/// The id is on the row deliberately. Two sensors in a room are routinely both called "Temperature"
/// — Home Assistant names them after the measurement, not the place — so a picker showing names
/// alone asks the user to choose between two identical rows. The id is the only thing that always
/// distinguishes them.
///
/// A shared component rather than part of the room sheet, because the tile, add-tile and composite
/// flows all need this same row and should not each grow their own.
struct EntityPickerRow: View {
    /// The display name, already resolved through `DisplayName` by the caller — so a device the user
    /// renamed reads that way here too.
    let title: String
    let entityId: String
    /// An optional third fact: the current reading, or which attribute is read. Nil for a plain
    /// entity where the id says everything.
    var detail: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(entityId)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            // A checkmark, not a tint on the row: the row already carries three lines of text and a
            // coloured background behind them is the least readable way to say "this one".
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(HavenColor.domain(.cover))
                .opacity(isSelected ? 1 : 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
```

- [ ] **Step 2: Add the store's write**

In `App/HomeStore.swift`:

```swift
    /// Nominates one sensor as a room's temperature or humidity source, and writes it to the
    /// household's dashboard document.
    ///
    /// Re-resolves after a successful write so the room's pills change immediately rather than at
    /// the next structure load — `byArea` is deliberately not recomputed from live state (see
    /// `EnvironmentCoordinator`), so nothing else would notice.
    func nominate(_ sensor: UpliftedSensor, areaId: String) async -> HavenConfig.Outcome {
        let outcome = await config.update { document in
            var override = document.nominations[areaId] ?? RoomEnvironmentOverride()
            override[sensor.role] = sensor
            return document.merging([areaId: override])
        }
        if outcome == .written { resolveEnvironment() }
        return outcome
    }
```

- [ ] **Step 3: Write the room sheet**

Rewrite `App/Views/RoomConfigView.swift`:

```swift
import SwiftUI
import HavenCore

/// Which sensors a room's heading reads from.
///
/// Haven nominates one of each the first time it sees a room and writes that down; this is where a
/// user changes it. There is deliberately **no "Automatic" and no "None"**: the auto-pick is
/// first-time priming rather than a mode to return to, so once a room has a nomination it is an
/// ordinary stored value like any other.
struct RoomConfigView: View {
    let areaId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Set when a write fails, so a refusal is explained rather than silently doing nothing.
    @State private var failure: String?

    var body: some View {
        let room = store.rooms().first { $0.areaId == areaId }
        let environment = store.environment[areaId]
        VStack(alignment: .leading, spacing: 12) {
            ModalHeader(systemImage: "thermometer.medium",
                        title: room?.name ?? "Room",
                        subtitle: "Readings shown in the heading",
                        accent: HavenColor.domain(.cover), unavailable: false)
            if let failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(HavenColor.warning)
            }
            role(.temperature, title: "Temperature", environment: environment)
            role(.humidity, title: "Humidity", environment: environment)
        }
    }

    @ViewBuilder
    private func role(_ role: UpliftedSensor.Role, title: String,
                      environment: RoomEnvironment?) -> some View {
        let candidates = environment?.candidates(for: role) ?? []
        FacetCard(title: title) {
            if candidates.isEmpty {
                // Not an error and not a bug: plenty of rooms have no humidity source at all. Saying
                // so is better than an empty card that reads as a failed load.
                Text("No \(title.lowercased()) sources in this room")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(candidates) { candidate in
                        Button {
                            Task { await select(candidate) }
                        } label: {
                            EntityPickerRow(title: store.displayName(of: candidate.entityId),
                                            entityId: candidate.entityId,
                                            detail: detail(for: candidate),
                                            isSelected: environment?[role] == candidate)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 7)
                    }
                }
            }
        }
    }

    /// Names the attribute for an attribute source. Without it a thermostat offering the room's
    /// temperature and its humidity appears twice, identically — the entity id alone does not say
    /// which reading is meant.
    private func detail(for sensor: UpliftedSensor) -> String? {
        sensor.attributeName.map { "Attribute · \($0)" }
    }

    private func select(_ sensor: UpliftedSensor) async {
        switch await store.nominate(sensor, areaId: areaId) {
        case .written, .unchanged:
            failure = nil
        case .notAuthorized:
            failure = "Only Home Assistant admins can change the household dashboard."
        case .failed:
            failure = "Couldn't save that. Check your connection and try again."
        }
    }
}
```

`candidates` are `UpliftedSensor`, whose `id` is its **role** — unique per room, but *not* unique within a candidate list. `ForEach(candidates)` would therefore collapse every row into one. Use an explicit id:

```swift
                    ForEach(candidates, id: \.self) { candidate in
```

`UpliftedSensor` is `Equatable` but not `Hashable`. Add `Hashable` conformance in HavenCore — `Source` and `Role` are both already value types:

```swift
public struct UpliftedSensor: Sendable, Equatable, Hashable, Identifiable {
    public enum Source: Sendable, Equatable, Hashable {
```

- [ ] **Step 4: Build, run tests, and render the sheet**

Run: `mcp__xcode__BuildProject` and `mcp__xcode__RunAllTests`.

Then add this preview to the bottom of `RoomConfigView.swift`. The fixture store is built on the main actor and held in `@State`, exactly as `TileGallery` and `LockModal`'s preview do — `HomeStore.states` is main-actor isolated and a `#Preview` body is not.

```swift
#if DEBUG
private struct RoomConfigPreviewHost: View {
    @State private var store = RoomConfigPreviewHost.populatedStore()
    let areaId: String
    var body: some View {
        RoomConfigView(areaId: areaId).padding(16).environment(store)
    }
    @MainActor
    private static func populatedStore() -> HomeStore {
        let store = HomeStore()
        func set(_ id: String, _ state: String, _ attrs: [String: JSONValue]) {
            store.states[id] = EntityState(entityId: id, state: state, attributes: attrs,
                                           lastUpdated: Date(timeIntervalSince1970: 0))
        }
        set("sensor.lounge_temp", "21.5", ["friendly_name": .string("Lounge Temperature"),
                                           "device_class": .string("temperature"),
                                           "unit_of_measurement": .string("°C")])
        set("sensor.lounge_temp_2", "20.9", ["friendly_name": .string("Temperature"),
                                             "device_class": .string("temperature"),
                                             "unit_of_measurement": .string("°C")])
        set("sensor.lounge_hum", "44", ["friendly_name": .string("Lounge Humidity"),
                                        "device_class": .string("humidity"),
                                        "unit_of_measurement": .string("%")])
        // The thermostat-only room: its temperature is an attribute, not a state.
        set("climate.study", "heat", ["friendly_name": .string("Study Thermostat"),
                                      "current_temperature": .double(19.5),
                                      "temperature": .double(21)])
        store.home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "Ground", level: 0, areas: [
            ResolvedArea(id: "lounge", name: "Lounge",
                         entityIds: ["sensor.lounge_temp", "sensor.lounge_temp_2", "sensor.lounge_hum"],
                         tiers: [:]),
            ResolvedArea(id: "study", name: "Study", entityIds: ["climate.study"], tiers: [:]),
            ResolvedArea(id: "hall", name: "Hall", entityIds: [], tiers: [:]),
        ])])
        store.resolveEnvironment()
        return store
    }
}

#Preview("Room config — several candidates") { RoomConfigPreviewHost(areaId: "lounge") }
#Preview("Room config — thermostat attribute only") { RoomConfigPreviewHost(areaId: "study") }
#Preview("Room config — nothing to pick") { RoomConfigPreviewHost(areaId: "hall") }
#endif
```

Check `ResolvedFloor` and `ResolvedArea`'s initialiser signatures in `Packages/HavenCore/Sources/HavenCore/Models/ResolvedHome.swift` before writing this and match them exactly — if they differ, the fixture is what changes, not the model.

Render all three with `mcp__xcode__RenderPreview` (indices 0, 1, 2) and check: bold names over ids; the two identically-named lounge sensors distinguishable *only* by their id, which is why the id is on the row; the checkmark on the current pick; the attribute row naming its attribute; and the hall's empty-state copy rather than a blank card.

- [ ] **Step 5: Commit**

```bash
git add App/DesignSystem/EntityPickerRow.swift App/Views/RoomConfigView.swift App/HomeStore.swift \
        Packages/HavenCore/Sources/HavenCore/Models/RoomEnvironment.swift
git commit -m "feat(app): pick a room's temperature and humidity sources"
```

---

## Task 6: Renaming a device

**Files:**
- Rewrite: `App/Views/TileConfigView.swift`
- Modify: `App/HomeStore.swift`

**Interfaces:**
- Consumes: `DisplayName.resolve` (Task 1), `DashboardDocument.settingDisplayName` (Task 2), `HavenConfig.update` (Task 3).
- Produces: `HomeStore.displayName(of:) -> String` and `HomeStore.rename(_ entityId: String, to name: String?) async -> HavenConfig.Outcome`. Task 7 routes every surface through `displayName(of:)`.

- [ ] **Step 1: Add the store's read and write**

In `App/HomeStore.swift`:

```swift
    /// What a device is called: Haven's override if the user set one, otherwise Home Assistant's
    /// name, otherwise the entity id as words. The rule is `DisplayName`'s, in HavenCore with tests.
    ///
    /// **Every surface must go through here** rather than reading `friendly_name` itself, or a
    /// renamed device would keep its old name wherever the sweep was missed. That is a
    /// grep-checkable invariant: `TileName.of` no longer exists.
    func displayName(of entityId: String) -> String {
        DisplayName.resolve(override: config.document.displayNames[entityId],
                            friendlyName: states[entityId]?.attributes["friendly_name"]?.asString,
                            entityId: entityId)
    }

    /// Sets or clears Haven's own name for a device. Never renames the entity in Home Assistant —
    /// HA stays the source of truth for structure, and this is Haven's layer on top.
    func rename(_ entityId: String, to name: String?) async -> HavenConfig.Outcome {
        await config.update { $0.settingDisplayName(name, for: entityId) }
    }
```

- [ ] **Step 2: Write the sheet**

Rewrite `App/Views/TileConfigView.swift`:

```swift
import SwiftUI
import HavenCore

/// A device's configuration. Today: what it is called.
///
/// The name is **Haven's own**, never a rename of the Home Assistant entity — HA stays the source of
/// truth for structure and Haven layers on top. That has a consequence this sheet is obliged to make
/// visible: an override shadows HA permanently, so renaming the entity in Home Assistant afterwards
/// will not show up here. Hence the line naming what HA calls the device, and the reset beside it.
struct TileConfigView: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// The field's live text. Seeded once from the current name — deliberately not bound straight
    /// through to the store, which would write on every keystroke.
    @State private var draft: String = ""
    @State private var failure: String?

    var body: some View {
        let e = store.state(entityId)
        let haName = e?.attributes["friendly_name"]?.asString
        let hasOverride = store.config.document.displayNames[entityId] != nil
        VStack(alignment: .leading, spacing: 12) {
            ModalHeader(systemImage: IconMap.symbol(domain: Domain.of(entityId),
                                                    deviceClass: e?.deviceClass),
                        title: store.displayName(of: entityId),
                        subtitle: entityId,
                        accent: HavenColor.domain(Domain.of(entityId)), unavailable: false)
            FacetCard(title: "Name") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                        .onSubmit { Task { await save() } }
                    // What HA calls it, so an override reads as an override rather than as a mystery.
                    Text(haName.map { "Home Assistant calls this \($0)" }
                         ?? "Home Assistant has no name for this device")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if let failure {
                        Text(failure).font(.system(size: 12)).foregroundStyle(HavenColor.warning)
                    }
                    HStack {
                        if hasOverride {
                            Button("Reset to Home Assistant's name") {
                                Task { await clear() }
                            }
                            .font(.system(size: 12, weight: .semibold))
                        }
                        Spacer()
                        Button("Save") { Task { await save() } }
                            .font(.system(size: 13, weight: .bold))
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines)
                                      == (store.config.document.displayNames[entityId] ?? ""))
                    }
                }
            }
        }
        // Seeded from the *override*, not from the resolved name: pre-filling with Home Assistant's
        // name would turn every "have a look at this device" into a rename the moment the user hit
        // Save.
        .onAppear { draft = store.config.document.displayNames[entityId] ?? "" }
    }

    private func save() async { await write(draft) }
    private func clear() async { await write(nil) }

    private func write(_ name: String?) async {
        switch await store.rename(entityId, to: name) {
        case .written, .unchanged:
            dismiss()
        case .notAuthorized:
            failure = "Only Home Assistant admins can change the household dashboard."
        case .failed:
            failure = "Couldn't save that. Check your connection and try again."
        }
    }
}
```

- [ ] **Step 3: Build and render**

Run: `mcp__xcode__BuildProject`, then add this preview to the bottom of `TileConfigView.swift`:

```swift
#if DEBUG
private struct TileConfigPreviewHost: View {
    @State private var store: HomeStore
    let entityId: String
    init(entityId: String, overridden: Bool) {
        self.entityId = entityId
        _store = State(initialValue: TileConfigPreviewHost.populatedStore(overridden: overridden))
    }
    var body: some View {
        TileConfigView(entityId: entityId).padding(16).environment(store)
    }
    @MainActor
    private static func populatedStore(overridden: Bool) -> HomeStore {
        let store = HomeStore()
        store.states["light.kitchen"] = EntityState(
            entityId: "light.kitchen", state: "on",
            attributes: ["friendly_name": .string("Kitchen Light")],
            lastUpdated: Date(timeIntervalSince1970: 0))
        if overridden {
            store.config.seedForTesting(
                DashboardDocument().settingDisplayName("Reading Lamp", for: "light.kitchen"))
        }
        return store
    }
}

#Preview("Tile config — renamed") { TileConfigPreviewHost(entityId: "light.kitchen", overridden: true) }
#Preview("Tile config — not renamed") { TileConfigPreviewHost(entityId: "light.kitchen", overridden: false) }
#endif
```

This needs one more DEBUG hook on `HavenConfig`, beside `setForTesting` from Task 3 — a preview cannot reach a document through a socket:

```swift
    /// Seeds the held document directly, for previews of views that render configuration.
    func seedForTesting(_ document: DashboardDocument) {
        self.document = document
        self.isLoaded = true
    }
```

Render both (indices 0 and 1) and check: the field pre-filled only when an override exists — a device you have merely opened must not arrive pre-filled with Home Assistant's name, or Save silently converts it into an override; the "Home Assistant calls this Kitchen Light" line in both; and the reset appearing only in the renamed one.

- [ ] **Step 4: Commit**

```bash
git add App/Views/TileConfigView.swift App/HomeStore.swift
git commit -m "feat(app): name a device in Haven, without touching Home Assistant"
```

---

## Task 7: Route every name through the override

**Files:**
- Modify: `App/Renderers/TileName.swift` (delete `of`)
- Modify: 21 tile and modal files — the 29 call sites listed below

**Interfaces:**
- Consumes: `HomeStore.displayName(of:)` (Task 6).
- Produces: the invariant `grep -rn "TileName.of" App/ | wc -l == 0`.

- [ ] **Step 1: Delete `TileName.of`**

Remove the `of` function from `App/Renderers/TileName.swift`, leaving only `words`. Add to the type's doc comment:

```swift
/// **`of` deliberately no longer exists.** Resolving a name means consulting Haven's own overrides,
/// which live in `HomeStore.config` — a static function has no way to reach them, and one that took
/// only an `EntityState` would silently render Home Assistant's name for a device the user renamed.
/// `HomeStore.displayName(of:)` is the only resolver, and this file's absence of an `of` is what
/// makes that grep-checkable.
```

- [ ] **Step 2: Run the build and collect every error**

Run: `mcp__xcode__BuildProject`
Expected: FAIL with ~29 errors, one per call site. That list *is* the work.

- [ ] **Step 3: Replace every call site**

In each file, replace `TileName.of(entityId, e)` with `store.displayName(of: entityId)`. Every one of these views already holds `@Environment(HomeStore.self) private var store`.

The 21 files: `Tiles/LightTile`, `Tiles/SwitchTile`, `Tiles/CoverTile`, `Tiles/LockTile`, `Tiles/ClimateTile`, `Tiles/CameraTile`, `Tiles/SceneTile`, `Tiles/SensorTile`, `Tiles/BinarySensorTile`, `Tiles/GenericTile`, `Tiles/MediaPlayerTile`, `Modals/LightModal`, `Modals/SwitchModal`, `Modals/CoverModal`, `Modals/LockModal`, `Modals/ClimateModal`, `Modals/CameraModal`, `Modals/SceneModal`, `Modals/SensorModal`, `Modals/BinarySensorModal`, `Modals/MediaPlayerModal`, `Modals/GenericModal`.

Note `LockModal` and `TileConfigView` construct their own previews with a bare `HomeStore`; those keep working, since `displayName(of:)` falls through to the entity id when nothing is configured.

- [ ] **Step 4: Verify the invariant and the suites**

```bash
grep -rn "TileName.of" App/ | wc -l     # must print 0
grep -rn "friendly_name" App/ | grep -v TileConfigView | wc -l   # must print 0
```

The second check matters as much as the first: a view reading `friendly_name` directly bypasses the override just as effectively as `TileName.of` did. `TileConfigView` is the one legitimate reader — it shows HA's name *as* HA's name.

Run: `mcp__xcode__BuildProject`, `mcp__xcode__RunAllTests`, and render `TileGallery` pages 1–3 to confirm no tile lost its name.

- [ ] **Step 5: Commit**

```bash
git add App/
git commit -m "refactor(app): every name on screen goes through Haven's overrides"
```

---

## Task 8: The configuration gallery page

**Files:**
- Modify: `App/Renderers/TileGallery.swift`

- [ ] **Step 1: Add a fourth page**

Tasks 5 and 6 each added previews next to their own view, which is enough to *build* them. This page is for the thing those cannot show: the two sheets side by side, in one place someone reviews before shipping — the same argument `TileGallery`'s own doc comment makes about the tiles.

Add `case fourth` to `Page`, and this branch to the `switch`:

```swift
                case .fourth:
                    section("Room configuration") {
                        VStack(alignment: .leading, spacing: 14) {
                            RoomConfigView(areaId: "lounge")
                            Divider()
                            RoomConfigView(areaId: "hall")
                        }
                    }
                    section("Tile configuration") { TileConfigView(entityId: "light.kitchen") }
```

Extend `populatedStore()` with the fixtures those need — the existing `set(...)` helper is already in scope:

```swift
        set("sensor.lounge_temp", "21.5", ["friendly_name": .string("Lounge Temperature"),
                                           "device_class": .string("temperature"),
                                           "unit_of_measurement": .string("°C")])
        set("sensor.lounge_temp_2", "20.9", ["friendly_name": .string("Temperature"),
                                             "device_class": .string("temperature"),
                                             "unit_of_measurement": .string("°C")])
        set("sensor.lounge_hum", "44", ["friendly_name": .string("Lounge Humidity"),
                                        "device_class": .string("humidity"),
                                        "unit_of_measurement": .string("%")])
        store.home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "Ground", level: 0, areas: [
            ResolvedArea(id: "lounge", name: "Lounge",
                         entityIds: ["sensor.lounge_temp", "sensor.lounge_temp_2", "sensor.lounge_hum"],
                         tiers: [:]),
            ResolvedArea(id: "hall", name: "Hall", entityIds: [], tiers: [:]),
        ])])
        store.config.seedForTesting(
            DashboardDocument().settingDisplayName("Reading Lamp", for: "light.kitchen"))
        store.resolveEnvironment()
```

`light.kitchen` already exists in the gallery's fixtures as `light.on`; add the id above as its own entry if it does not, rather than renaming the existing one — the other pages render it.

Add the preview:

```swift
/// The configuration sheets, which have no other verification.
#Preview("Tiles 4 — configuration") {
    TileGallery(page: .fourth)
}
```

- [ ] **Step 2: Render and check**

Run `mcp__xcode__RenderPreview` on index 3. Confirm: bold names over ids; the two identically-named lounge sensors told apart only by their id; a checkmark on the current pick; the hall's empty-state copy; and the rename sheet pre-filled with "Reading Lamp" over the line saying Home Assistant calls it Kitchen Light.

If page four overflows one screen — it renders two full sheets — split it rather than shrinking it, exactly as climate's eight fixtures forced a third page. A page that overflows has stopped being a baseline.

- [ ] **Step 3: Commit**

```bash
git add App/Renderers/TileGallery.swift
git commit -m "test(app): the configuration sheets get looked at, like the tiles do"
```

---

## Verification

Before considering the plan complete:

```bash
cd Packages/HavenCore && swift test          # 665 + 12 new = 677
```
Then `mcp__xcode__BuildProject` and `mcp__xcode__RunAllTests` (88 + 5 new = 93), and render `TileGallery` pages 1–4.

Manual check against a real Home Assistant, since no test covers the round trip: enter configuration mode as an admin, rename a device, force-quit, relaunch, and confirm the name survived — that is the only proof the write actually reached the household document rather than only the local one.
