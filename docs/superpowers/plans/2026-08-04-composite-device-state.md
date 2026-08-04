# Composite Device State (6a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A device's entities resolve into one value describing its state, which any surface can read; the modal is the first reader.

**Architecture:** A pure resolver in HavenCore joins a primary entity to the `.companion` entities sharing its registry `deviceId`, and returns them as ordered readings whose words come from `TileState`. `HomeStore` supplies the maps and the exclusion set; `DeviceModalView` renders one section for every domain rather than eleven modals each remembering to.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test`/`#expect`), `xcodegen`.

## Global Constraints

- **The combining happens once, in HavenCore.** No surface computes a composite; every surface reads `DeviceState`.
- **Ordering is part of the contract** — a tile showing only `readings.first` must show the right one.
- **Words come from `TileState`**, never a second vocabulary.
- **An unreachable companion is a reading**, not an absence.
- **Read-only.** No control is offered on a companion row in this revision.
- A device with no companions renders exactly as it does today.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `Packages/HavenCore/Sources/HavenCore/Domain/CompositeState.swift` | `DeviceState`, `DeviceReading`, and the resolver |
| `Packages/HavenCore/Tests/HavenCoreTests/CompositeStateTests.swift` | Discovery, ordering, vocabulary, unreachable |
| `App/HomeStore.swift` | `deviceState(of:)` — supplies the maps and the camera exclusion |
| `App/Renderers/DeviceContextCard.swift` | The section, and one row |
| `App/Renderers/DeviceModalView.swift` | Renders the section beneath every domain modal |

---

### Task 1: The resolver

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Domain/CompositeState.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/CompositeStateTests.swift`

**Interfaces:**
- Consumes: `EntityRegistryInfo`, `CurationTier`, `EntityState`, `TileState`, `DisplayName`, `Domain`.
- Produces: `DeviceState(primary:readings:)`, `DeviceReading(entityId:label:value:isActive:)`,
  `CompositeState.resolve(primary:deviceId:registry:tiers:states:excluding:) -> DeviceState`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import HavenCore

private func info(_ deviceId: String?) -> EntityRegistryInfo {
    EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: deviceId)
}

private func state(_ id: String, _ s: String, _ deviceClass: String? = nil) -> EntityState {
    var attrs: [String: JSONValue] = [:]
    if let deviceClass { attrs["device_class"] = .string(deviceClass) }
    return EntityState(entityId: id, state: s, attributes: attrs,
                       lastUpdated: Date(timeIntervalSince1970: 0))
}

/// A lock and the door sensor on the same physical device: the case the whole feature exists for.
/// The lock says locked; whether the door is actually shut is this other entity.
@Test func aCompanionOnTheSameDeviceBecomesAReading() {
    let out = CompositeState.resolve(
        primary: "lock.front", deviceId: "d1",
        registry: ["lock.front": info("d1"), "binary_sensor.front_door": info("d1")],
        tiers: ["lock.front": .primary, "binary_sensor.front_door": .companion],
        states: ["lock.front": state("lock.front", "locked"),
                 "binary_sensor.front_door": state("binary_sensor.front_door", "off", "door")])
    #expect(out.readings.map(\.entityId) == ["binary_sensor.front_door"])
    // The word is TileState's, so a door reads "Closed" rather than "Off".
    #expect(out.readings.first?.value == "Closed")
    #expect(out.readings.first?.isActive == false)
}

/// Only `.companion` entities. A `.primary` sibling has its own tile and must not also appear as
/// somebody's footnote.
@Test func aPrimarySiblingIsNotACompanion() {
    let out = CompositeState.resolve(
        primary: "lock.front", deviceId: "d1",
        registry: ["lock.front": info("d1"), "switch.chime": info("d1")],
        tiers: ["lock.front": .primary, "switch.chime": .primary],
        states: [:])
    #expect(out.readings.isEmpty)
}

@Test func anotherDevicesEntityIsNotACompanion() {
    let out = CompositeState.resolve(
        primary: "lock.front", deviceId: "d1",
        registry: ["lock.front": info("d1"), "binary_sensor.other": info("d2")],
        tiers: ["lock.front": .primary, "binary_sensor.other": .companion],
        states: [:])
    #expect(out.readings.isEmpty)
}

/// **A device-less primary matches nothing rather than everything.** Many integrations create
/// entities with no `device_id`, and a naive `==` on two optionals would make every one of them a
/// companion of every other — `CameraEvents` records the same trap.
@Test func aPrimaryWithNoDeviceMatchesNothing() {
    let out = CompositeState.resolve(
        primary: "lock.front", deviceId: nil,
        registry: ["lock.front": info(nil), "binary_sensor.loose": info(nil)],
        tiers: ["lock.front": .primary, "binary_sensor.loose": .companion],
        states: [:])
    #expect(out.readings.isEmpty)
}

/// The ordering contract: a tile will show only the first reading, so the first has to be the one
/// that qualifies the device's own state — not its battery.
@Test func theMostContextualReadingComesFirst() {
    let out = CompositeState.resolve(
        primary: "cover.garage", deviceId: "d1",
        registry: ["cover.garage": info("d1"),
                   "sensor.garage_battery": info("d1"),
                   "binary_sensor.garage_closed": info("d1")],
        tiers: ["cover.garage": .primary,
                "sensor.garage_battery": .companion,
                "binary_sensor.garage_closed": .companion],
        states: ["sensor.garage_battery": state("sensor.garage_battery", "88", "battery"),
                 "binary_sensor.garage_closed": state("binary_sensor.garage_closed", "off", "door")])
    #expect(out.readings.map(\.entityId)
            == ["binary_sensor.garage_closed", "sensor.garage_battery"])
}

/// An unreachable companion says so. Dropping it would make an offline door sensor and an absent
/// one look identical, which is the opposite of telling the user what the device knows.
@Test func anUnreachableCompanionIsStillAReading() {
    let out = CompositeState.resolve(
        primary: "lock.front", deviceId: "d1",
        registry: ["lock.front": info("d1"), "binary_sensor.front_door": info("d1")],
        tiers: ["lock.front": .primary, "binary_sensor.front_door": .companion],
        states: ["binary_sensor.front_door": state("binary_sensor.front_door", "unavailable", "door")])
    #expect(out.readings.first?.value == TileState.unavailable.word)
}

/// What the parent's own modal already renders is skipped — a camera's motion sensor is a chip
/// there, and listing it again as a reading is the same fact twice.
@Test func whatTheParentAlreadyRendersIsSkipped() {
    let out = CompositeState.resolve(
        primary: "camera.door", deviceId: "d1",
        registry: ["camera.door": info("d1"), "binary_sensor.motion": info("d1")],
        tiers: ["camera.door": .primary, "binary_sensor.motion": .companion],
        states: ["binary_sensor.motion": state("binary_sensor.motion", "on", "motion")],
        excluding: ["binary_sensor.motion"])
    #expect(out.readings.isEmpty)
}

/// A numeric companion reads as its value and unit, not through the binary vocabulary.
@Test func aNumericCompanionReadsAsItsValue() {
    var attrs: [String: JSONValue] = ["device_class": .string("battery"),
                                      "unit_of_measurement": .string("%")]
    let battery = EntityState(entityId: "sensor.b", state: "88", attributes: attrs,
                              lastUpdated: Date(timeIntervalSince1970: 0))
    attrs = [:]
    let out = CompositeState.resolve(
        primary: "lock.front", deviceId: "d1",
        registry: ["lock.front": info("d1"), "sensor.b": info("d1")],
        tiers: ["lock.front": .primary, "sensor.b": .companion],
        states: ["sensor.b": battery])
    #expect(out.readings.first?.value == "88 %")
    #expect(out.readings.first?.isActive == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd Packages/HavenCore && swift test --filter CompositeState`
Expected: FAIL — no such type `CompositeState`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// One device's state, as the compound of its entities.
///
/// **The value every surface reads, and no surface computes.** A device's state being more than one
/// entity's state is a fact about the device, so it is resolved once here: a modal renders all of
/// it, a tile renders the part that fits, and the two cannot disagree because neither decides.
public struct DeviceState: Sendable, Equatable {
    /// The entity a surface is rendering — the one with the controls.
    public let primary: String
    /// Supporting readings, most contextually important first.
    public let readings: [DeviceReading]

    public init(primary: String, readings: [DeviceReading]) {
        self.primary = primary
        self.readings = readings
    }
}

/// One companion entity, as something to read.
public struct DeviceReading: Sendable, Equatable, Identifiable {
    public let entityId: String
    /// What this reading is *of* — the companion's own display name.
    public let label: String
    /// What it currently says: "Closed", "Detected", "88 %".
    public let value: String
    /// Whether it is in its notable state, for tint. `nil` where the notion does not apply — a
    /// battery percentage is not "active", and tinting it as though it were would invent an alarm.
    public let isActive: Bool?

    public var id: String { entityId }

    public init(entityId: String, label: String, value: String, isActive: Bool?) {
        self.entityId = entityId
        self.label = label
        self.value = value
        self.isActive = isActive
    }
}

public enum CompositeState {
    /// A primary entity and the companions belonging to the same physical device.
    ///
    /// - Parameter deviceId: the primary's own `device_id`, or `nil`. **`nil` matches nothing.**
    ///   Many integrations create entities without a device, and comparing two optionals with `==`
    ///   would make every one of them a companion of every other — the trap `CameraEvents.related`
    ///   documents on the same rung.
    /// - Parameter excluding: entities the caller's own view already renders. A camera's motion
    ///   sensors are chips in `CameraModal`; listing them again here is one fact twice.
    public static func resolve(primary: String, deviceId: String?,
                               registry: [String: EntityRegistryInfo],
                               tiers: [String: CurationTier],
                               states: [String: EntityState],
                               excluding: Set<String> = []) -> DeviceState {
        guard let deviceId, !deviceId.isEmpty else {
            return DeviceState(primary: primary, readings: [])
        }
        let companions = registry.keys.filter { id in
            id != primary
                && !excluding.contains(id)
                && registry[id]?.deviceId == deviceId
                && tiers[id] == .companion
        }
        let readings = companions
            .map { reading($0, states[$0]) }
            .sorted { lhs, rhs in
                let l = rank(lhs.entityId), r = rank(rhs.entityId)
                return l == r ? lhs.entityId < rhs.entityId : l < r
            }
        return DeviceState(primary: primary, readings: readings)
    }

    /// **The ordering contract.** A tile will show only the first reading, so the first has to be the
    /// one that qualifies the device's own state: a door sensor beside a lock, not its battery.
    ///
    /// Binary sensors first because they answer a question the primary raised — *is it actually
    /// shut* — and numeric sensors second because a percentage is background. Ties break on entity
    /// id so a home renders identically on every launch.
    private static func rank(_ entityId: String) -> Int {
        switch Domain.of(entityId) {
        case .binarySensor: return 0
        case .sensor: return 1
        default: return 2
        }
    }

    private static func reading(_ entityId: String, _ state: EntityState?) -> DeviceReading {
        let label = DisplayName.resolve(override: nil,
                                        friendlyName: state?.attributes["friendly_name"]?.asString,
                                        entityId: entityId)
        guard let state, !state.isUnavailable else {
            return DeviceReading(entityId: entityId, label: label,
                                 value: TileState.unavailable.word, isActive: nil)
        }
        if Domain.of(entityId) == .binarySensor {
            let active = state.state == "on"
            let face = TileState.binarySensor(deviceClass: state.deviceClass, isActive: active)
            return DeviceReading(entityId: entityId, label: label, value: face.word,
                                 isActive: active)
        }
        let sensor = SensorState(state)
        let value = [sensor.value, sensor.unit].compactMap { $0 }.joined(separator: " ")
        return DeviceReading(entityId: entityId, label: label, value: value, isActive: nil)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd Packages/HavenCore && swift test --filter CompositeState`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/HavenCore
git commit -m "feat(core): a device's state, as the compound of its entities"
```

---

### Task 2: The store supplies it

**Files:**
- Modify: `App/HomeStore.swift`

**Interfaces:**
- Consumes: `CompositeState.resolve(...)`, and `HomeStore`'s existing camera event-sensor path.
- Produces: `HomeStore.deviceState(of entityId: String) -> DeviceState`.

- [ ] **Step 1: Add the accessor**

```swift
    /// A device's state — the entity being rendered, plus the companions that qualify it.
    ///
    /// Flattens the per-area tier maps once per call. A room holds a handful of entities and this is
    /// read when a modal opens, not per frame, so the map is built where it is needed rather than
    /// cached into a third source of truth.
    ///
    /// **A camera's event sensors are excluded**, because `CameraModal` already renders them as
    /// chips with a curated kind and its own ordering. The exclusion is here rather than in the
    /// resolver: which view draws what is a rendering fact, not a fact about the device.
    func deviceState(of entityId: String) -> DeviceState {
        var tiers: [String: CurationTier] = [:]
        for floor in home.floors {
            for area in floor.areas { tiers.merge(area.tiers) { _, new in new } }
        }
        let excluded = Domain.of(entityId) == .camera
            ? Set(cameraEventSensors(entityId).map(\.entityId))
            : []
        return CompositeState.resolve(primary: entityId,
                                      deviceId: home.registryInfo[entityId]?.deviceId,
                                      registry: home.registryInfo,
                                      tiers: tiers,
                                      states: states,
                                      excluding: excluded)
    }
```

- [ ] **Step 2: Check the camera accessor's real name**

Run: `grep -n "CameraEvents.related" -B 6 App/HomeStore.swift`
Use whatever that function is actually called in place of `cameraEventSensors(_:)` above; do not
add a second one.

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme HavenApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add App/HomeStore.swift
git commit -m "feat(app): the store resolves a device's composite state"
```

---

### Task 3: The modal renders it

**Files:**
- Create: `App/Renderers/DeviceContextCard.swift`
- Modify: `App/Renderers/DeviceModalView.swift`

**Interfaces:**
- Consumes: `HomeStore.deviceState(of:)`, `DeviceReading`.
- Produces: `DeviceContextCard(entityId:)`.

- [ ] **Step 1: Write the card**

```swift
import SwiftUI
import HavenCore

/// What else this device knows.
///
/// **One card for every domain, added where modals are dispatched rather than inside each of the
/// eleven.** A device gains its context by being a device, not by somebody remembering to add a
/// section to its modal — which is the same argument `ConfigurableTile` makes about tiles.
///
/// Read-only in this revision. A companion with controls of its own is reachable as a tile by adding
/// it with the `+`, and whether a chime should be ringable from its doorbell's modal is a question
/// about binding, which is 6b's.
struct DeviceContextCard: View {
    let entityId: String
    @Environment(HomeStore.self) private var store

    var body: some View {
        let readings = store.deviceState(of: entityId).readings
        // Nothing at all for a device with no companions, so every modal that has none is exactly
        // as it was.
        if !readings.isEmpty {
            FacetCard(title: "Also on this device") {
                VStack(spacing: 8) {
                    ForEach(readings) { reading in
                        HStack(alignment: .firstTextBaseline) {
                            Text(reading.label)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            Text(reading.value)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                // Tinted only where "active" means something. A battery percentage
                                // is not an alarm and must not be coloured like one.
                                .foregroundStyle(reading.isActive == true
                                                 ? HavenColor.warning : Color.primary)
                        }
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Add it to the dispatcher**

In `DeviceModalView.body`, wrap the existing `Group` and the card in a `VStack(spacing: 12)` so the
card sits beneath whichever modal was chosen, and the whole thing is measured by `.fittedSheet()`
together:

```swift
    var body: some View {
        VStack(spacing: 12) {
            Group {
                switch Domain.of(entityId) {
                // ... unchanged ...
                }
            }
            DeviceContextCard(entityId: entityId)
        }
        .fittedSheet()
    }
```

- [ ] **Step 3: Regenerate the project and build**

Run:
```bash
xcodegen generate
xcodebuild -scheme HavenApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Add gallery coverage**

Add a page to `TileGallery` rendering `DeviceContextCard` for three fixtures: a device with no
companions (renders nothing), one with a single binary companion, and one with several including an
unreachable one. Seed the fixtures' `registryInfo` and area `tiers` so the resolver has a device to
group on — a fixture store with no registry resolves to no readings and would show an empty card
that proves nothing.

- [ ] **Step 5: Render and check**

Render the new page and confirm: the no-companion case draws nothing, the labels are display names,
the unreachable reading says "Unavailable", and no value is tinted except an active binary sensor.

- [ ] **Step 6: Run both suites and commit**

```bash
cd Packages/HavenCore && swift test && cd -
xcodebuild test -scheme HavenApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
git add -A
git commit -m "feat(app): a modal shows what else its device knows"
```

---

## Self-Review

**Spec coverage.** Discovery by `deviceId` + `.companion` (Task 1); ordering contract (Task 1, `rank`);
`TileState` vocabulary (Task 1, `reading`); unreachable as a reading (Task 1); camera exclusion (Task
1 parameter, Task 2 call site); one section for every domain (Task 3); nothing rendered without
companions (Task 3). The 6b items — tile line, binding, refined face — are deliberately absent.

**Placeholders.** Task 3 step 4 describes the fixtures to add rather than showing them, because the
gallery's fixture builder is a file the implementer will be editing in place and the three cases are
fully specified. Every code step carries its code.

**Type consistency.** `DeviceState(primary:readings:)`, `DeviceReading(entityId:label:value:isActive:)`
and `CompositeState.resolve(primary:deviceId:registry:tiers:states:excluding:)` are used under those
names in all three tasks. `SensorState`, `TileState`, `DisplayName` and `Domain` are existing types
used with their existing signatures.
