# HavenApp Sub-project D — Renderer Catalog & Dashboard UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the live-but-minimal dashboard into the full product: per-domain native renderers (tiles + long-press control modals) for 9 device domains, organized by registry-derived floors→rooms, with uplifted room climate, Lights/Covers roll-ups, sensor history, and room detail — in the theme-aware Light-Glass-Vibrant language.

**Architecture:** All pure logic (domain parsing, typed per-domain state, command payloads, roll-up computation, icon map, history parsing, section/room model) lives in the `HavenCore` Swift package and is unit-tested via `swift test`. The SwiftUI layer (`App/`) encapsulates the glass look in a small `DesignSystem` of reusable components, then each renderer is a thin view over its typed state; views are verified by `xcodebuild`. A renderer *dispatch* maps an entity's domain → its tile/modal.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Charts, Swift Testing (`import Testing`), the existing `HAWebSocketClient`/`HomeConnection`/`NWWebSocketConnection` transport.

## Global Constraints

- **Platform floor:** iOS 26.0. Swift 6 language mode, complete strict concurrency. All shared types `Sendable`; SwiftUI views `@MainActor`.
- **No third-party runtime dependencies.** Networking via the existing transport only.
- **Pure logic goes in `HavenCore`** (unit-tested with `swift test`); **SwiftUI views go in `App/`** (verified by `xcodebuild`). Anything that can be a pure function/value type MUST live in HavenCore behind a testable surface.
- **Verify commands:**
  - Package tests: `cd Packages/HavenCore && swift test`
  - App build: `cd /Users/timmead/Developer/HavenApp && xcodegen generate && xcodebuild -project HavenApp.xcodeproj -scheme HavenApp -sdk iphoneos26.5 -configuration Debug build CODE_SIGNING_ALLOWED=NO` → must print `BUILD SUCCEEDED`.
  - **New Swift files under `App/` require `xcodegen generate` before they compile** (XcodeGen globs `App/`).
- **Renderer scope:** Light, Switch/Outlet, Cover, Lock, Climate, Scene/Script/Button, Sensor, Binary Sensor, Generic fallback. **Media Player and Camera are OUT** (deferred to D.2).
- **State by icon + color, never redundant text** ("On"/"Off"/"Locked"/"Scene" are never shown). Secondary text = meaningful values only. Brightness/position show as a vertical level bar.
- **Control modal:** header (icon · name · state subtitle · **primary on/off toggle** · close) + a stack of facet **cards**. Primary on/off ALWAYS in the header. Discrete choices ALWAYS use the segmented control. History ONLY on sensor facets, with a Day/Week/Month/3M/Year range selector; curves smoothed.
- **Domain colors:** light=amber `#E0A013`, cover=blue `#2F6FD6`, lock=green `#1F9D57` (unlocked amber/red), climate=warm-red `#C2410C`, scene=purple `#8A5CD0`, sensor=neutral/blue, alert=red.
- **Commit trailer:** every commit body ends with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Tests use Swift Testing** (`import Testing`, `@Test`, `#expect`) and must assert concrete values.
- **Shared-file discipline:** `DeviceTileView.swift` (Task 13) and `DeviceModalView.swift` (Task 17) are written complete once and **never edited again** — all nine tiles/modals are created as stubs in those tasks and later tasks only replace stub *bodies*. `HomeStore.swift` is the one genuinely shared file: each task states exactly which methods it adds, and must NOT redefine methods an earlier task added.
- **Runtime checkpoints (not just builds):** almost every defect class here compiles cleanly (wrong service called, binding written backwards, sheet missing its environment, long-press never firing). Run the real app against the live HA **after Task 13** (first tile through dispatch — verify tap toggles a light and long-press sets `presented`) and **after Task 17** (first modal — verify the sheet presents and the header toggle writes back). Do not defer all runtime validation to Task 23.

## File Structure

```
Packages/HavenCore/Sources/HavenCore/
  Domain/Domain.swift                     # entity domain enum + parsing + device_class access
  Domain/LightState.swift  SwitchState.swift  CoverState.swift  LockState.swift
  Domain/ClimateState.swift  SensorState.swift  BinarySensorState.swift
  Domain/IconMap.swift                     # (domain, device_class) -> SF Symbol name
  Commands/DeviceCommands.swift            # HomeConnection extension: per-domain call_service
  Model/DeviceRef.swift                    # .entity | .composite (composite = abstraction only)
  Model/HomeSection.swift                  # Section + RoomSection + SectionBuilder
  Model/RoomRollups.swift                  # lights/covers roll-up computation + bulk targets
  History/History.swift                    # HistoryRange, HistoryPoint, HistorySeries, parsing
  History/HistoryService.swift             # queries HA history/statistics via the client
  Protocol/WSMessages.swift  (modify)      # callService w/ service_data; history/statistics cmds
  Models/ResolvedHome.swift  (modify)      # ResolvedArea gains temperatureEntityId/humidityEntityId
  Registry/RegistryResolver.swift (modify) # populate the new ResolvedArea fields
  Session/HomeConnection.swift (modify)    # history fetch passthrough
App/
  DesignSystem/Theme.swift                 # domain colors, glass tokens
  DesignSystem/GlassTile.swift  LevelBar.swift  SegmentedControl.swift  Chip.swift
  DesignSystem/ControlModalScaffold.swift  # header + cards container + presentation
  Renderers/DeviceTileView.swift           # dispatch: entity -> tile
  Renderers/DeviceModalView.swift          # dispatch: entity -> modal
  Renderers/Tiles/{Light,Switch,Cover,Lock,Climate,Scene,Sensor,BinarySensor,Generic}Tile.swift
  Renderers/Modals/{Light,Switch,Cover,Lock,Climate,Scene,Sensor,BinarySensor,Generic}Modal.swift
  Views/RoomSectionView.swift  (rewrite)   # dispatch tiles + env chips + roll-ups
  Views/RoomDetailView.swift               # grouped-by-domain full room
  Views/DashboardView.swift  (modify)      # navigation to room detail
  HomeStore.swift  (modify)                # command methods, roll-up actions, optimistic updates
```

---

## PHASE 1 — HavenCore foundation (pure, unit-tested)

### Task 1: `Domain` enum + parsing

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Domain/Domain.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/DomainTests.swift`

**Interfaces:**
- Produces: `enum Domain: String, Sendable { case light, switchOutlet, cover, lock, climate, scene, script, button, sensor, binarySensor, unknown }` with `static func of(_ entityId: String) -> Domain` and `var isActuator: Bool`.
- Produces: `extension EntityState { var deviceClass: String? }` reading `attributes["device_class"]?.asString`.

- [ ] **Step 1: Write failing tests**
```swift
import Testing
@testable import HavenCore

@Test func parsesDomains() {
    #expect(Domain.of("light.kitchen") == .light)
    #expect(Domain.of("switch.plug") == .switchOutlet)
    #expect(Domain.of("cover.blinds") == .cover)
    #expect(Domain.of("lock.front") == .lock)
    #expect(Domain.of("climate.hall") == .climate)
    #expect(Domain.of("scene.movie") == .scene)
    #expect(Domain.of("binary_sensor.door") == .binarySensor)
    #expect(Domain.of("sensor.power") == .sensor)
    #expect(Domain.of("media_player.tv") == .unknown)   // out of scope -> unknown
    #expect(Domain.of("fan.attic") == .unknown)         // fan is NOT in the D catalog -> Generic
}
@Test func serviceDomainComesFromEntityIdPrefix() {
    // input_boolean.x must call input_boolean.turn_on, NOT switch.turn_on
    #expect(Domain.serviceDomain(of: "input_boolean.guest") == "input_boolean")
    #expect(Domain.serviceDomain(of: "switch.plug") == "switch")
    #expect(Domain.serviceDomain(of: "light.k") == "light")
}
@Test func actuatorFlag() {
    #expect(Domain.light.isActuator)
    #expect(!Domain.sensor.isActuator)
    #expect(!Domain.binarySensor.isActuator)
}
@Test func deviceClassAccessor() {
    let s = EntityState(entityId: "binary_sensor.d", state: "on",
                        attributes: ["device_class": .string("door")], lastUpdated: .init())
    #expect(s.deviceClass == "door")
}
```

- [ ] **Step 2: Run — verify fails** (`swift test --filter DomainTests`).

- [ ] **Step 3: Implement `Domain.swift`**
```swift
import Foundation

public enum Domain: String, Sendable, Equatable {
    case light, switchOutlet, cover, lock, climate, scene, script, button, sensor, binarySensor, unknown

    public static func of(_ entityId: String) -> Domain {
        switch String(entityId.prefix(while: { $0 != "." })) {
        case "light": return .light
        case "switch", "input_boolean": return .switchOutlet
        case "cover": return .cover
        case "lock": return .lock
        case "climate": return .climate
        case "scene": return .scene
        case "script": return .script
        case "button", "input_button": return .button
        case "binary_sensor": return .binarySensor
        case "sensor": return .sensor
        default: return .unknown
        }
    }
    public var isActuator: Bool {
        switch self {
        case .light, .switchOutlet, .cover, .lock, .climate, .scene, .script, .button: return true
        case .sensor, .binarySensor, .unknown: return false
        }
    }
    /// The HA *service* domain — always the entity-id prefix, so `input_boolean.x`
    /// calls `input_boolean.turn_on` rather than `switch.turn_on`.
    public static func serviceDomain(of entityId: String) -> String {
        String(entityId.prefix(while: { $0 != "." }))
    }
}

public extension EntityState {
    var deviceClass: String? { attributes["device_class"]?.asString }
}
```

- [ ] **Step 4: Run — verify pass.** **Step 5: Commit**
```bash
git add Packages/HavenCore && git commit -m "feat(core): entity Domain enum + device_class accessor

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Actuator typed state (Light, Switch, Cover, Lock, Climate)

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Domain/LightState.swift`, `SwitchState.swift`, `CoverState.swift`, `LockState.swift`, `ClimateState.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/ActuatorStateTests.swift`

**Interfaces:**
- Produces value types, each `init(_ e: EntityState)`:
  - `LightState { isOn: Bool; brightnessPercent: Int?; supportsBrightness: Bool; supportsColorTemp: Bool }`
  - `SwitchState { isOn: Bool }`
  - `CoverState { isOpen: Bool; positionPercent: Int?; supportsPosition: Bool }`
  - `LockState { isLocked: Bool; isJammed: Bool }`
  - `ClimateState { isOn: Bool; currentTemp: Double?; targetTemp: Double?; hvacMode: String; modes: [String]; fanMode: String?; fanModes: [String]; unit: String }`

- [ ] **Step 1: Write failing tests**
```swift
import Testing
@testable import HavenCore

private func e(_ id: String, _ st: String, _ a: [String: JSONValue] = [:]) -> EntityState {
    EntityState(entityId: id, state: st, attributes: a, lastUpdated: .init())
}

@Test func lightState() {
    let s = LightState(e("light.k", "on", ["brightness": .int(191), "supported_color_modes": .array([.string("color_temp")])]))
    #expect(s.isOn); #expect(s.brightnessPercent == 75)   // 191/255 ≈ 75
    #expect(s.supportsBrightness); #expect(s.supportsColorTemp)
    #expect(!LightState(e("light.k", "off")).isOn)
}
@Test func coverState() {
    let s = CoverState(e("cover.b", "open", ["current_position": .int(60)]))
    #expect(s.isOpen); #expect(s.positionPercent == 60); #expect(s.supportsPosition)
    #expect(!CoverState(e("cover.b", "closed")).isOpen)
}
@Test func lockState() {
    #expect(LockState(e("lock.f", "locked")).isLocked)
    #expect(LockState(e("lock.f", "jammed")).isJammed)
    #expect(!LockState(e("lock.f", "unlocked")).isLocked)
}
@Test func climateState() {
    let s = ClimateState(e("climate.h", "heat", [
        "current_temperature": .double(70), "temperature": .double(72),
        "hvac_modes": .array([.string("off"), .string("heat"), .string("cool")]),
        "fan_mode": .string("auto"), "fan_modes": .array([.string("auto"), .string("low")]),
    ]))
    #expect(s.isOn); #expect(s.currentTemp == 70); #expect(s.targetTemp == 72)
    #expect(s.hvacMode == "heat"); #expect(s.modes == ["off","heat","cool"]); #expect(s.fanMode == "auto")
    #expect(!ClimateState(e("climate.h", "off")).isOn)
}
```

- [ ] **Step 2: Run — verify fails.**

- [ ] **Step 3: Implement the five files**

`LightState.swift`:
```swift
import Foundation
public struct LightState: Sendable, Equatable {
    public let isOn: Bool
    public let brightnessPercent: Int?
    public let supportsBrightness: Bool
    public let supportsColorTemp: Bool
    public init(_ e: EntityState) {
        isOn = e.state == "on"
        if let b = e.attributes["brightness"]?.asInt { brightnessPercent = Int((Double(b) / 255.0 * 100).rounded()) }
        else { brightnessPercent = nil }
        let modes = (e.attributes["supported_color_modes"]?.asArray ?? []).compactMap { $0.asString }
        supportsBrightness = e.attributes["brightness"] != nil || modes.contains { $0 != "onoff" }
        supportsColorTemp = modes.contains("color_temp")
    }
}
```

`SwitchState.swift`:
```swift
public struct SwitchState: Sendable, Equatable {
    public let isOn: Bool
    public init(_ e: EntityState) { isOn = e.state == "on" }
}
```

`CoverState.swift`:
```swift
public struct CoverState: Sendable, Equatable {
    public let isOpen: Bool
    public let positionPercent: Int?
    public let supportsPosition: Bool
    public init(_ e: EntityState) {
        isOpen = e.state == "open" || e.state == "opening"
        positionPercent = e.attributes["current_position"]?.asInt
        supportsPosition = e.attributes["current_position"] != nil
    }
}
```

`LockState.swift`:
```swift
public struct LockState: Sendable, Equatable {
    public let isLocked: Bool
    public let isJammed: Bool
    public init(_ e: EntityState) { isLocked = e.state == "locked"; isJammed = e.state == "jammed" }
}
```

`ClimateState.swift`:
```swift
import Foundation
public struct ClimateState: Sendable, Equatable {
    public let isOn: Bool
    public let currentTemp: Double?
    public let targetTemp: Double?
    public let hvacMode: String
    public let modes: [String]
    public let fanMode: String?
    public let fanModes: [String]
    public let unit: String
    public init(_ e: EntityState) {
        hvacMode = e.state
        isOn = e.state != "off" && e.state != "unavailable" && e.state != "unknown"
        currentTemp = e.attributes["current_temperature"]?.asDouble
        targetTemp = e.attributes["temperature"]?.asDouble
        modes = (e.attributes["hvac_modes"]?.asArray ?? []).compactMap { $0.asString }
        fanMode = e.attributes["fan_mode"]?.asString
        fanModes = (e.attributes["fan_modes"]?.asArray ?? []).compactMap { $0.asString }
        unit = e.attributes["temperature_unit"]?.asString ?? "°"
    }
}
```

- [ ] **Step 4: Run — verify pass.** **Step 5: Commit** (`feat(core): typed actuator state (light/switch/cover/lock/climate)`).

---

### Task 3: Sensor typed state (Sensor, Binary Sensor)

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Domain/SensorState.swift`, `BinarySensorState.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/SensorStateTests.swift`

**Interfaces:**
- `SensorState { value: String; unit: String?; deviceClass: String?; isNumeric: Bool; numericValue: Double? }`
- `BinarySensorState { isActive: Bool; deviceClass: String? }` (isActive == state=="on").

- [ ] **Step 1: Failing tests**
```swift
import Testing
@testable import HavenCore
private func e(_ id: String,_ s: String,_ a: [String: JSONValue] = [:]) -> EntityState { .init(entityId:id,state:s,attributes:a,lastUpdated:.init()) }

@Test func sensorState() {
    let s = SensorState(e("sensor.p", "124", ["unit_of_measurement": .string("W"), "device_class": .string("power")]))
    #expect(s.value == "124"); #expect(s.unit == "W"); #expect(s.deviceClass == "power")
    #expect(s.isNumeric); #expect(s.numericValue == 124)
    #expect(!SensorState(e("sensor.x", "home")).isNumeric)
}
@Test func binarySensorState() {
    #expect(BinarySensorState(e("binary_sensor.d", "on", ["device_class": .string("door")])).isActive)
    #expect(!BinarySensorState(e("binary_sensor.d", "off")).isActive)
}
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement**

`SensorState.swift`:
```swift
import Foundation
public struct SensorState: Sendable, Equatable {
    public let value: String
    public let unit: String?
    public let deviceClass: String?
    public var numericValue: Double? { Double(value) }
    public var isNumeric: Bool { numericValue != nil }
    public init(_ e: EntityState) {
        value = e.state
        unit = e.attributes["unit_of_measurement"]?.asString
        deviceClass = e.deviceClass
    }
}
```

`BinarySensorState.swift`:
```swift
public struct BinarySensorState: Sendable, Equatable {
    public let isActive: Bool
    public let deviceClass: String?
    public init(_ e: EntityState) { isActive = e.state == "on"; deviceClass = e.deviceClass }
}
```

- [ ] **Step 4: Pass. Step 5: Commit** (`feat(core): typed sensor + binary-sensor state`).

---

### Task 4: `IconMap` (domain/device_class → SF Symbol)

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Domain/IconMap.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/IconMapTests.swift`

**Interfaces:**
- `enum IconMap { static func symbol(domain: Domain, deviceClass: String?) -> String }` returning an SF Symbol name.

- [ ] **Step 1: Failing tests**
```swift
import Testing
@testable import HavenCore
@Test func iconMap() {
    #expect(IconMap.symbol(domain: .light, deviceClass: nil) == "lightbulb.fill")
    #expect(IconMap.symbol(domain: .cover, deviceClass: nil) == "blinds.horizontal.closed")
    #expect(IconMap.symbol(domain: .lock, deviceClass: nil) == "lock.fill")
    #expect(IconMap.symbol(domain: .climate, deviceClass: nil) == "thermometer.medium")
    #expect(IconMap.symbol(domain: .scene, deviceClass: nil) == "sparkles")
    #expect(IconMap.symbol(domain: .sensor, deviceClass: "temperature") == "thermometer.medium")
    #expect(IconMap.symbol(domain: .sensor, deviceClass: "humidity") == "humidity.fill")
    #expect(IconMap.symbol(domain: .sensor, deviceClass: "power") == "bolt.fill")
    #expect(IconMap.symbol(domain: .binarySensor, deviceClass: "door") == "door.left.hand.open")
    #expect(IconMap.symbol(domain: .binarySensor, deviceClass: "motion") == "figure.walk.motion")
    #expect(IconMap.symbol(domain: .unknown, deviceClass: nil) == "square.dashed")
}
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement `IconMap.swift`** (temperature uses the bulb-thermometer `thermometer.medium`, per the design nit):
```swift
public enum IconMap {
    public static func symbol(domain: Domain, deviceClass: String?) -> String {
        switch domain {
        case .light: return "lightbulb.fill"
        case .switchOutlet: return "poweroutlet.type.b.fill"
        case .cover: return "blinds.horizontal.closed"
        case .lock: return "lock.fill"
        case .climate: return "thermometer.medium"
        case .scene: return "sparkles"
        case .script, .button: return "play.circle.fill"
        case .sensor: return sensorSymbol(deviceClass)
        case .binarySensor: return binarySymbol(deviceClass)
        case .unknown: return "square.dashed"
        }
    }
    private static func sensorSymbol(_ dc: String?) -> String {
        switch dc {
        case "temperature": return "thermometer.medium"
        case "humidity": return "humidity.fill"
        case "power", "energy": return "bolt.fill"
        case "battery": return "battery.50"
        case "co2", "carbon_dioxide": return "carbon.dioxide.cloud.fill"
        case "illuminance": return "sun.max.fill"
        case "pressure": return "gauge.medium"
        default: return "chart.line.uptrend.xyaxis"
        }
    }
    private static func binarySymbol(_ dc: String?) -> String {
        switch dc {
        case "door", "garage_door": return "door.left.hand.open"
        case "window", "opening": return "window.vertical.open"
        case "motion", "occupancy", "presence": return "figure.walk.motion"
        case "moisture": return "drop.fill"
        case "smoke": return "smoke.fill"
        case "gas", "carbon_monoxide": return "aqi.medium"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}
```

- [ ] **Step 4: Pass. Step 5: Commit** (`feat(core): SF Symbol icon map by domain/device_class`).

---

## PHASE 2 — Command layer

### Task 5: `WSCommand` service_data + history commands

**Files:**
- Modify: `Packages/HavenCore/Sources/HavenCore/Protocol/WSMessages.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/WSCommandServiceDataTests.swift`

**Interfaces:**
- Adds `WSCommand.callService(id:domain:service:entityId:serviceData:)` where `serviceData: [String: JSONValue]` merges into the `service_data` object.
- Adds `WSCommand.historyDuringPeriod(id:entityId:startISO:endISO:)` (type `history/history_during_period`) and `WSCommand.statisticsDuringPeriod(id:statisticId:startISO:endISO:period:)` (type `recorder/statistics_during_period`).

- [ ] **Step 1: Failing tests**
```swift
import Testing
import Foundation
@testable import HavenCore
private func obj(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }

@Test func callServiceWithData() {
    let o = obj(WSCommand.callService(id: 3, domain: "light", service: "turn_on", entityId: "light.k",
                                      serviceData: ["brightness_pct": .int(60)]))
    #expect(o["type"] as? String == "call_service")
    #expect(((o["target"] as? [String:Any])?["entity_id"]) as? String == "light.k")
    #expect(((o["service_data"] as? [String:Any])?["brightness_pct"]) as? Int == 60)
}
@Test func statisticsCommand() {
    let o = obj(WSCommand.statisticsDuringPeriod(id: 5, statisticId: "sensor.p", startISO: "2026-07-01T00:00:00Z", endISO: "2026-07-02T00:00:00Z", period: "hour"))
    #expect(o["type"] as? String == "recorder/statistics_during_period")
    #expect((o["statistic_ids"] as? [String])?.first == "sensor.p")
    #expect(o["period"] as? String == "hour")
}
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement** — add to `WSCommand` (convert `[String: JSONValue]` to plain JSON via the existing encoder path; use `JSONSerialization`-friendly values):
```swift
    private static func plain(_ v: JSONValue) -> Any {
        switch v {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let a): return a.map(plain)
        case .object(let o): return o.mapValues(plain)
        case .null: return NSNull()
        }
    }
    public static func callService(id: Int, domain: String, service: String, entityId: String,
                                   serviceData: [String: JSONValue]) -> Data {
        data(["id": id, "type": "call_service", "domain": domain, "service": service,
              "target": ["entity_id": entityId], "service_data": serviceData.mapValues(plain)])
    }
    public static func historyDuringPeriod(id: Int, entityId: String, startISO: String, endISO: String) -> Data {
        data(["id": id, "type": "history/history_during_period", "start_time": startISO, "end_time": endISO,
              "entity_ids": [entityId], "minimal_response": true, "no_attributes": true])
    }
    public static func statisticsDuringPeriod(id: Int, statisticId: String, startISO: String, endISO: String, period: String) -> Data {
        data(["id": id, "type": "recorder/statistics_during_period", "start_time": startISO, "end_time": endISO,
              "statistic_ids": [statisticId], "period": period, "types": ["mean", "min", "max"]])
    }
```

- [ ] **Step 4: Pass** (`swift test` full suite green). **Step 5: Commit** (`feat(core): call_service with service_data + history/statistics ws commands`).

---

### Task 6: `HomeConnection` per-domain commands

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Commands/DeviceCommands.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/DeviceCommandsTests.swift`

**Interfaces:** an `extension HomeConnection` adding: `setLight(_:on:)`, `setBrightness(_:percent:)`, `setColorTemp(_:mired:)`, `setSwitch(_:on:)`, `openCover(_:)`, `closeCover(_:)`, `stopCover(_:)`, `setCoverPosition(_:percent:)`, `setLock(_:locked:)`, `setClimateMode(_:mode:)`, `setClimateTemp(_:temp:)`, `setFanMode(_:mode:)`, `activate(sceneOrScript:)`, `callServiceRaw(domain:service:entityId:data:)`. Each awaits a `call_service` result.

- [ ] **Step 1: Failing tests** (drive the fake, assert the emitted JSON)
```swift
import Testing
import Foundation
@testable import HavenCore

private func authed() async throws -> (FakeWebSocketConnection, HomeConnection) {
    let conn = FakeWebSocketConnection(); let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#); await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { d in
        if let o = try? JSONSerialization.jsonObject(with: d) as? [String:Any], let id = o["id"] as? Int, o["type"] as? String == "call_service" {
            await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":null}"#)
        }
    }
    return (conn, HomeConnection(client: client))
}

@Test func setBrightnessEmitsTurnOnWithPct() async throws {
    let (conn, home) = try await authed()
    try await home.setBrightness("light.k", percent: 60)
    let sent = await conn.sentTexts()
    #expect(sent.contains { $0.contains("\"service\":\"turn_on\"") && $0.contains("brightness_pct") && $0.contains("60") })
}
@Test func closeCoverEmitsService() async throws {
    let (conn, home) = try await authed()
    try await home.closeCover("cover.b")
    #expect(await conn.sentTexts().contains { $0.contains("\"domain\":\"cover\"") && $0.contains("close_cover") })
}
@Test func lockEmitsService() async throws {
    let (conn, home) = try await authed()
    try await home.setLock("lock.f", locked: true)
    #expect(await conn.sentTexts().contains { $0.contains("\"domain\":\"lock\"") && $0.contains("\"service\":\"lock\"") })
}
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement `DeviceCommands.swift`**
```swift
import Foundation
public extension HomeConnection {
    private func call(_ domain: String, _ service: String, _ entityId: String, _ data: [String: JSONValue] = [:]) async throws {
        _ = try await client.request { WSCommand.callService(id: $0, domain: domain, service: service, entityId: entityId, serviceData: data) }
    }
    func callServiceRaw(domain: String, service: String, entityId: String, data: [String: JSONValue] = [:]) async throws { try await call(domain, service, entityId, data) }

    func setLight(_ id: String, on: Bool) async throws { try await call("light", on ? "turn_on" : "turn_off", id) }
    func setBrightness(_ id: String, percent: Int) async throws { try await call("light", "turn_on", id, ["brightness_pct": .int(max(0, min(100, percent)))]) }
    func setColorTemp(_ id: String, mired: Int) async throws { try await call("light", "turn_on", id, ["color_temp": .int(mired)]) }
    func setSwitch(_ id: String, on: Bool) async throws { try await call(Domain.serviceDomain(of: id), on ? "turn_on" : "turn_off", id) }
    func openCover(_ id: String) async throws { try await call("cover", "open_cover", id) }
    func closeCover(_ id: String) async throws { try await call("cover", "close_cover", id) }
    func stopCover(_ id: String) async throws { try await call("cover", "stop_cover", id) }
    func setCoverPosition(_ id: String, percent: Int) async throws { try await call("cover", "set_cover_position", id, ["position": .int(max(0, min(100, percent)))]) }
    func setLock(_ id: String, locked: Bool) async throws { try await call("lock", locked ? "lock" : "unlock", id) }
    func setClimateMode(_ id: String, mode: String) async throws { try await call("climate", "set_hvac_mode", id, ["hvac_mode": .string(mode)]) }
    func setClimateTemp(_ id: String, temp: Double) async throws { try await call("climate", "set_temperature", id, ["temperature": .double(temp)]) }
    func setFanMode(_ id: String, mode: String) async throws { try await call("climate", "set_fan_mode", id, ["fan_mode": .string(mode)]) }
    func activate(sceneOrScript id: String) async throws {
        let d = Domain.of(id)
        try await call(d == .script ? "script" : d == .button ? "button" : "scene", d == .button ? "press" : "turn_on", id)
    }
}
```
Note: `client` is currently `private` on `HomeConnection`. In this task, change it to `internal` (drop `private`) so the extension in the same module can use it. Also add a `toggleLight`-style but generic: keep existing `toggleLight`.

- [ ] **Step 4: Run — verify pass** (`swift test`). **Step 5: Commit** (`feat(core): per-domain call_service commands on HomeConnection`).

---

## PHASE 3 — Model, roll-ups, history

### Task 7: `ResolvedArea` uplifted sensor fields

**Files:**
- Modify: `Packages/HavenCore/Sources/HavenCore/Models/ResolvedHome.swift`, `Registry/RegistryResolver.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/RegistryResolverTests.swift` (add one test)

**Interfaces:** `ResolvedArea` gains `let temperatureEntityId: String?` and `let humidityEntityId: String?`, populated by the resolver from the matching `AreaRegistryEntry`.

- [ ] **Step 1: Add failing test**
```swift
@Test func areaCarriesClimateEntities() {
    let areas = [AreaRegistryEntry(areaId: "a", name: "Kitchen", floorId: nil, icon: nil,
                                   temperatureEntityId: "sensor.kt", humidityEntityId: "sensor.kh")]
    let home = RegistryResolver.resolve(floors: [], areas: areas, devices: [], entities: [])
    let area = home.floors.flatMap(\.areas).first { $0.id == "a" }
    #expect(area?.temperatureEntityId == "sensor.kt")
    #expect(area?.humidityEntityId == "sensor.kh")
}
```

- [ ] **Step 2: Run — fails** (extra args to `ResolvedArea.init`).

- [ ] **Step 3: Modify `ResolvedArea`** — add the two `let`s + init params (default `nil`), and update its memberwise usages. In `RegistryResolver.resolve`, when building `areaModels`, pass `temperatureEntityId: $0.temperatureEntityId, humidityEntityId: $0.humidityEntityId`; the synthetic "Unassigned" area passes `nil, nil`.
```swift
// ResolvedHome.swift
public struct ResolvedArea: Sendable, Equatable, Identifiable {
    public let id: String; public let name: String; public var entityIds: [String]
    public let temperatureEntityId: String?; public let humidityEntityId: String?
    public init(id: String, name: String, entityIds: [String],
                temperatureEntityId: String? = nil, humidityEntityId: String? = nil) {
        self.id = id; self.name = name; self.entityIds = entityIds
        self.temperatureEntityId = temperatureEntityId; self.humidityEntityId = humidityEntityId
    }
}
```
In `RegistryResolver.resolve`, change the `areaModels` map to:
```swift
var areaModels = areas.map {
    ResolvedArea(id: $0.areaId, name: $0.name, entityIds: (entitiesByArea[$0.areaId] ?? []).sorted(),
                 temperatureEntityId: $0.temperatureEntityId, humidityEntityId: $0.humidityEntityId)
}
```

- [ ] **Step 4: Run — verify pass** (`swift test` full suite — existing resolver tests still green). **Step 5: Commit** (`feat(core): carry area temperature/humidity entities through the resolver`).

---

### Task 8: Section / RoomSection / DeviceRef model + builder

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Model/DeviceRef.swift`, `Model/HomeSection.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/HomeSectionTests.swift`

**Interfaces:**
- `enum DeviceRef: Sendable, Equatable, Identifiable { case entity(String); case composite(type: String, inputs: [String:String]); var id: String }`.
- `enum SectionKind: Sendable, Equatable { case room }`.
- `struct UpliftedSensor { enum Role { case temperature, humidity }; let role: Role; let entityId: String }`.
- `struct RoomSection: Sendable, Equatable, Identifiable { id, name, kind == .room, areaId, headerSensors: [UpliftedSensor], deviceRefs: [DeviceRef] }`.
- `enum SectionBuilder { static func rooms(from home: ResolvedHome) -> [RoomSection] }` — one RoomSection per area (in floor order), headerSensors from the area's temp/humidity entity ids, deviceRefs = `.entity(id)` for each entity NOT used as a header sensor (temp/humidity uplift removes them from the grid).

- [ ] **Step 1: Failing tests**
```swift
import Testing
@testable import HavenCore
@Test func buildsRoomsWithUpliftAndDevices() {
    let areas = [AreaRegistryEntry(areaId: "a", name: "Living", floorId: nil, icon: nil,
                                   temperatureEntityId: "sensor.t", humidityEntityId: "sensor.h")]
    let entities = [EntityRegistryEntry(entityId: "light.l", areaId: "a", deviceId: nil, name: nil),
                    EntityRegistryEntry(entityId: "sensor.t", areaId: "a", deviceId: nil, name: nil),
                    EntityRegistryEntry(entityId: "sensor.h", areaId: "a", deviceId: nil, name: nil),
                    EntityRegistryEntry(entityId: "sensor.power", areaId: "a", deviceId: nil, name: nil)]
    let home = RegistryResolver.resolve(floors: [], areas: areas, devices: [], entities: entities)
    let rooms = SectionBuilder.rooms(from: home)
    let living = rooms.first { $0.name == "Living" }!
    #expect(living.headerSensors.map(\.entityId).sorted() == ["sensor.h","sensor.t"])
    // uplifted temp/humidity are NOT tiles; other entities are
    let deviceIds = living.deviceRefs.map(\.id).sorted()
    #expect(deviceIds == ["light.l","sensor.power"])
}
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement**

`DeviceRef.swift`:
```swift
public enum DeviceRef: Sendable, Equatable, Identifiable {
    case entity(String)
    case composite(type: String, inputs: [String: String])   // abstraction only in D
    public var id: String {
        switch self {
        case .entity(let e): return e
        case .composite(let t, let inputs): return "composite:\(t):" + inputs.keys.sorted().map { "\($0)=\(inputs[$0]!)" }.joined(separator: ",")
        }
    }
}
```

`HomeSection.swift`:
```swift
public enum SectionKind: Sendable, Equatable { case room }

public struct UpliftedSensor: Sendable, Equatable {
    public enum Role: Sendable, Equatable { case temperature, humidity }
    public let role: Role; public let entityId: String
}

public struct RoomSection: Sendable, Equatable, Identifiable {
    public let id: String; public let name: String; public let kind: SectionKind = .room
    public let areaId: String
    public let headerSensors: [UpliftedSensor]
    public let deviceRefs: [DeviceRef]
}

public enum SectionBuilder {
    public static func rooms(from home: ResolvedHome) -> [RoomSection] {
        home.floors.flatMap(\.areas).map { area in
            var header: [UpliftedSensor] = []
            if let t = area.temperatureEntityId { header.append(.init(role: .temperature, entityId: t)) }
            if let h = area.humidityEntityId { header.append(.init(role: .humidity, entityId: h)) }
            let uplifted = Set(header.map(\.entityId))
            let devices = area.entityIds.filter { !uplifted.contains($0) }.map { DeviceRef.entity($0) }
            return RoomSection(id: area.id, name: area.name, areaId: area.id, headerSensors: header, deviceRefs: devices)
        }
    }
}
```

- [ ] **Step 4: Pass. Step 5: Commit** (`feat(core): Section/RoomSection/DeviceRef model + registry-first builder`).

---

### Task 9: Room roll-ups

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Model/RoomRollups.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/RoomRollupsTests.swift`

**Interfaces:**
- `struct Rollup: Sendable, Equatable { enum Kind { case lights, covers }; let kind: Kind; let activeCount: Int; let total: Int; let targetEntityIds: [String] }` (targetEntityIds = those to act on for the bulk action).
- `enum RoomRollups { static func compute(entityIds: [String], states: [String: EntityState]) -> [Rollup] }` — Lights (on count; bulk target = all lights) and Covers (open count; bulk target = all covers). Omit a rollup whose `total == 0`.

- [ ] **Step 1: Failing tests**
```swift
import Testing
@testable import HavenCore
private func e(_ id:String,_ s:String) -> EntityState { .init(entityId:id,state:s,attributes:[:],lastUpdated:.init()) }
@Test func rollups() {
    let ids = ["light.a","light.b","cover.c","sensor.x"]
    let states = ["light.a": e("light.a","on"), "light.b": e("light.b","off"),
                  "cover.c": e("cover.c","open"), "sensor.x": e("sensor.x","1")]
    let r = RoomRollups.compute(entityIds: ids, states: states)
    let lights = r.first { $0.kind == .lights }!
    #expect(lights.activeCount == 1); #expect(lights.total == 2); #expect(lights.targetEntityIds.sorted() == ["light.a","light.b"])
    let covers = r.first { $0.kind == .covers }!
    #expect(covers.activeCount == 1); #expect(covers.total == 1)
    #expect(RoomRollups.compute(entityIds: ["sensor.x"], states: states).isEmpty)   // no lights/covers -> none
}
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement**
```swift
public struct Rollup: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case lights, covers }
    public let kind: Kind; public let activeCount: Int; public let total: Int; public let targetEntityIds: [String]
}
public enum RoomRollups {
    public static func compute(entityIds: [String], states: [String: EntityState]) -> [Rollup] {
        var out: [Rollup] = []
        let lights = entityIds.filter { Domain.of($0) == .light }
        if !lights.isEmpty {
            let on = lights.filter { states[$0]?.state == "on" }
            out.append(Rollup(kind: .lights, activeCount: on.count, total: lights.count, targetEntityIds: lights))
        }
        let covers = entityIds.filter { Domain.of($0) == .cover }
        if !covers.isEmpty {
            let open = covers.filter { let s = states[$0]?.state; return s == "open" || s == "opening" }
            out.append(Rollup(kind: .covers, activeCount: open.count, total: covers.count, targetEntityIds: covers))
        }
        return out
    }
}
```

- [ ] **Step 4: Pass. Step 5: Commit** (`feat(core): room lights/covers roll-up computation`).

---

### Task 10: History models + parsing

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/History/History.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/HistoryTests.swift`

**Interfaces:**
- `enum HistoryRange: Sendable, CaseIterable { case day, week, month, threeMonths, year; var label: String; var period: String; var seconds: TimeInterval }` — period maps day→"hour" (…actually day→raw history), etc. (see impl). `var usesStatistics: Bool`.
- `struct HistoryPoint: Sendable, Equatable { let time: Date; let value: Double }`.
- `struct HistorySeries: Sendable, Equatable { let points: [HistoryPoint]; var min: Double?; var max: Double?; var avg: Double? }`.
- `enum HistoryParsing { static func fromStatistics(_ result: JSONValue, statisticId: String) -> HistorySeries; static func fromHistory(_ result: JSONValue, entityId: String) -> HistorySeries }`.

- [ ] **Step 1: Failing tests**
```swift
import Testing
import Foundation
@testable import HavenCore
@Test func rangeMapping() {
    #expect(HistoryRange.day.usesStatistics == false)
    #expect(HistoryRange.month.usesStatistics)
    #expect(HistoryRange.threeMonths.label == "3M")
    #expect(HistoryRange.allCases.count == 5)
}
@Test func parseStatistics() {
    let json = #"{"sensor.p":[{"start":1751328000000,"mean":100.0,"min":10.0,"max":300.0},{"start":1751331600000,"mean":120.0}]}"#
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(json.utf8))
    let s = HistoryParsing.fromStatistics(v, statisticId: "sensor.p")
    #expect(s.points.count == 2); #expect(s.points.first?.value == 100.0); #expect(s.max == 300.0)
}
@Test func parseRawHistory() {
    let json = #"{"sensor.p":[{"s":"124","lu":1751328000.0},{"s":"nan","lu":1751328600.0},{"s":"130","lu":1751329200.0}]}"#
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(json.utf8))
    let s = HistoryParsing.fromHistory(v, entityId: "sensor.p")
    #expect(s.points.count == 2)   // non-numeric "nan" dropped
    #expect(s.points.first?.value == 124)
}
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement `History.swift`**
```swift
import Foundation
public enum HistoryRange: Sendable, CaseIterable {
    case day, week, month, threeMonths, year
    public var label: String { switch self { case .day: "Day"; case .week: "Week"; case .month: "Month"; case .threeMonths: "3M"; case .year: "Year" } }
    public var seconds: TimeInterval { switch self { case .day: 86_400; case .week: 604_800; case .month: 2_592_000; case .threeMonths: 7_776_000; case .year: 31_536_000 } }
    public var usesStatistics: Bool { self != .day }   // Day = raw history; longer = long-term statistics
    public var period: String { switch self { case .day: "hour"; case .week: "hour"; case .month: "day"; case .threeMonths: "day"; case .year: "month" } }
}
public struct HistoryPoint: Sendable, Equatable { public let time: Date; public let value: Double
    public init(time: Date, value: Double) { self.time = time; self.value = value } }
public struct HistorySeries: Sendable, Equatable {
    public let points: [HistoryPoint]
    public init(points: [HistoryPoint]) { self.points = points }
    public var min: Double? { points.map(\.value).min() }
    public var max: Double? { points.map(\.value).max() }
    public var avg: Double? { points.isEmpty ? nil : points.map(\.value).reduce(0, +) / Double(points.count) }
}
public enum HistoryParsing {
    public static func fromStatistics(_ result: JSONValue, statisticId: String) -> HistorySeries {
        let arr = result.asObject?[statisticId]?.asArray ?? []
        let pts = arr.compactMap { row -> HistoryPoint? in
            guard let o = row.asObject, let start = o["start"]?.asDouble,
                  let mean = (o["mean"]?.asDouble ?? o["state"]?.asDouble) else { return nil }
            return HistoryPoint(time: Date(timeIntervalSince1970: start / 1000.0), value: mean)
        }
        return HistorySeries(points: pts)
    }
    public static func fromHistory(_ result: JSONValue, entityId: String) -> HistorySeries {
        let arr = result.asObject?[entityId]?.asArray ?? []
        let pts = arr.compactMap { row -> HistoryPoint? in
            guard let o = row.asObject, let lu = o["lu"]?.asDouble,
                  let val = Double(o["s"]?.asString ?? "") else { return nil }
            return HistoryPoint(time: Date(timeIntervalSince1970: lu), value: val)
        }
        return HistorySeries(points: pts)
    }
}
```

- [ ] **Step 4: Pass. Step 5: Commit** (`feat(core): history range model + statistics/history parsing`).

---

### Task 11: `HistoryService`

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/History/HistoryService.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/HistoryServiceTests.swift`

**Interfaces:** `extension HomeConnection { func history(entityId: String, range: HistoryRange, now: Date) async throws -> HistorySeries }` — picks statistics vs raw history by `range.usesStatistics`, computes ISO start/end from `now`, sends the command, parses. `now` is a parameter (testable, avoids `Date()`).

- [ ] **Step 1: Failing test**
```swift
import Testing
import Foundation
@testable import HavenCore
@Test func historyServiceDay() async throws {
    let conn = FakeWebSocketConnection(); let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#); await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { d in
        if let o = try? JSONSerialization.jsonObject(with: d) as? [String:Any], let id = o["id"] as? Int,
           (o["type"] as? String) == "history/history_during_period" {
            await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":{"sensor.p":[{"s":"124","lu":1751328000.0}]}}"#)
        }
    }
    let home = HomeConnection(client: client)
    let s = try await home.history(entityId: "sensor.p", range: .day, now: Date(timeIntervalSince1970: 1751414400))
    #expect(s.points.count == 1); #expect(s.points.first?.value == 124)
}
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement `HistoryService.swift`**
```swift
import Foundation
public extension HomeConnection {
    func history(entityId: String, range: HistoryRange, now: Date) async throws -> HistorySeries {
        let start = now.addingTimeInterval(-range.seconds)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let startISO = f.string(from: start), endISO = f.string(from: now)
        if range.usesStatistics {
            let v = try await client.request { WSCommand.statisticsDuringPeriod(id: $0, statisticId: entityId, startISO: startISO, endISO: endISO, period: range.period) }
            return HistoryParsing.fromStatistics(v, statisticId: entityId)
        } else {
            let v = try await client.request { WSCommand.historyDuringPeriod(id: $0, entityId: entityId, startISO: startISO, endISO: endISO) }
            return HistoryParsing.fromHistory(v, entityId: entityId)
        }
    }
}
```

- [ ] **Step 4: Run — verify pass** (`swift test` full suite green). **Step 5: Commit** (`feat(core): HistoryService querying HA history/statistics`).

---

## PHASE 4 — Design system (SwiftUI, build-verified)

### Task 12: Design-system primitives

**Files:**
- Create: `App/DesignSystem/Theme.swift`, `GlassTile.swift`, `LevelBar.swift`, `SegmentedControl.swift`, `Chip.swift`
- Verify: build only.

**Interfaces:**
- `enum HavenColor { static func domain(_:Domain) -> Color; static let glassFill, glassStroke: Color }`.
- `struct GlassTile<Content: View>: View` — the frosted rounded container; params `active: Bool`, `accent: Color`, content builder.
- `struct LevelBar: View { let percent: Int; let color: Color }` — vertical bar.
- `struct HavenSegmented<T: Hashable>: View { options: [T]; selection: Binding<T>; label: (T)->String; accent: Color }`.
- `struct HavenChip: View { systemImage: String?; text: String; accent: Color? }`.

- [ ] **Step 1: Implement `Theme.swift`**
```swift
import SwiftUI
import HavenCore
enum HavenColor {
    static func domain(_ d: Domain) -> Color {
        switch d {
        case .light: return Color(red: 0.88, green: 0.63, blue: 0.07)
        case .cover: return Color(red: 0.18, green: 0.44, blue: 0.84)
        case .lock: return Color(red: 0.12, green: 0.62, blue: 0.34)
        case .climate: return Color(red: 0.76, green: 0.25, blue: 0.05)
        case .scene, .script, .button: return Color(red: 0.54, green: 0.36, blue: 0.82)
        case .sensor, .binarySensor, .unknown, .switchOutlet: return Color(red: 0.18, green: 0.44, blue: 0.84)
        }
    }
    static let glassFill = Color.white.opacity(0.55)
    static let glassStroke = Color.white.opacity(0.85)
}
```

- [ ] **Step 2: Implement `GlassTile.swift`**
```swift
import SwiftUI
struct GlassTile<Content: View>: View {
    var active: Bool = false
    var accent: Color = .gray
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 9, trailing: 14))
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(active ? AnyShapeStyle(accent.opacity(0.30)) : AnyShapeStyle(.regularMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(active ? accent.opacity(0.6) : Color.white.opacity(0.35), lineWidth: 1))
                    .shadow(color: active ? accent.opacity(0.28) : .black.opacity(0.06), radius: active ? 10 : 3, y: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
```

- [ ] **Step 3: Implement `LevelBar.swift`**
```swift
import SwiftUI
struct LevelBar: View {
    let percent: Int
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.black.opacity(0.09))
                Capsule().fill(color).frame(height: geo.size.height * CGFloat(max(0, min(100, percent))) / 100)
            }
        }
        .frame(width: 4)
    }
}
```

- [ ] **Step 4: Implement `SegmentedControl.swift`**
```swift
import SwiftUI
struct HavenSegmented<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String
    var accent: Color = .accentColor
    var body: some View {
        HStack(spacing: 5) {
            ForEach(options, id: \.self) { opt in
                let sel = opt == selection
                Text(label(opt)).font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background { if sel { RoundedRectangle(cornerRadius: 10).fill(.background).shadow(radius: 1, y: 1) } }
                    .foregroundStyle(sel ? accent : .secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { selection = opt }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.5)))
    }
}
```

- [ ] **Step 5: Implement `Chip.swift`**
```swift
import SwiftUI
struct HavenChip: View {
    var systemImage: String? = nil
    let text: String
    var accent: Color? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .bold)).foregroundStyle(accent ?? .secondary) }
            Text(text).font(.system(size: 12.5, weight: .bold))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.6)))
    }
}
```

- [ ] **Step 6: Build** — `xcodegen generate && xcodebuild … build` → BUILD SUCCEEDED. **Step 7: Commit** (`feat(app): Light-Glass design-system primitives`).

---

## PHASE 5 — Tiles + dispatch

### Task 13: Tile dispatch + Light + Switch tiles

**Files:**
- Create: `App/Renderers/DeviceTileView.swift`, `App/Renderers/TileName.swift`
- Create ALL NINE tile files now: `App/Renderers/Tiles/{Light,Switch,Cover,Lock,Climate,Scene,Sensor,BinarySensor,Generic}Tile.swift` — `LightTile` and `SwitchTile` fully implemented in this task; the other seven as **minimal stubs** (see Step 6). Tasks 14–16 fill the stub bodies in place.
- **DO NOT delete `App/Views/LightTileView.swift`** — `RoomSectionView` still references it until Task 22. Task 22 deletes it.

> **Why stubs:** `DeviceTileView`'s switch is written complete and correct in this task and is **never edited again**. Every task therefore builds green, and later tasks only fill in a stub body — no shared-file churn across subagents.

**Interfaces:**
- `struct DeviceTileView: View { let entityId: String; @Environment(HomeStore.self) store }` — reads `store.state(entityId)`, computes `Domain`, switches to the concrete tile; unknown/sensor/etc handled in later tasks (Task 15/16), Generic fallback for the rest.
- Each tile: `init(entityId:)`, reads its typed state from the store, `GlassTile` with icon + name + optional `LevelBar`, `onTapGesture` → store command, `onLongPressGesture` → present modal (modal presentation wired in Task 17 via a shared `@State selectedEntity`).

> **Store additions used here** (add in this task to `HomeStore`): `func state(_ id: String) -> EntityState?` returning `states[id]`; and the command methods forwarding to `HomeConnection` with optimistic updates (added incrementally per domain — for this task add `toggleActuator(_:)` covering light/switch, plus a generic `run(_:)`). Present the modal by binding a `@Published var presented: String?` (entityId) — the actual sheet is added in Task 17; for now `longPress` sets `store.presented = entityId`.

- [ ] **Step 1: Add store hooks** (`App/HomeStore.swift`). Add EXACTLY these — later tasks depend on these names and must not redefine them:
```swift
    var presented: String?                                   // entityId whose modal is open
    func state(_ id: String) -> EntityState? { states[id] }

    // Optimistic on/off primitives. `toggle` DELEGATES to these — do not duplicate this logic later.
    func setLight(_ id: String, on: Bool) { optimistic(id, on: on) { c in try await c.setLight(id, on: on) } }
    func setSwitch(_ id: String, on: Bool) { optimistic(id, on: on) { c in try await c.setSwitch(id, on: on) } }
    func toggle(_ id: String) {
        let on = !(states[id]?.state == "on")
        Domain.of(id) == .light ? setLight(id, on: on) : setSwitch(id, on: on)
    }

    /// Flip local state immediately, run the command, roll back on failure.
    private func optimistic(_ id: String, on: Bool, _ work: @escaping @Sendable (HomeConnection) async throws -> Void) {
        guard let connection, var s = states[id] else { return }
        let previous = s
        s.state = on ? "on" : "off"
        states[id] = s
        Task { do { try await work(connection) } catch { self.states[id] = previous } }
    }
```
Build.

- [ ] **Step 2: Implement `DeviceTileView.swift`**
```swift
import SwiftUI
import HavenCore
struct DeviceTileView: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        switch Domain.of(entityId) {
        case .light: LightTile(entityId: entityId)
        case .switchOutlet: SwitchTile(entityId: entityId)
        case .cover: CoverTile(entityId: entityId)
        case .lock: LockTile(entityId: entityId)
        case .climate: ClimateTile(entityId: entityId)
        case .scene, .script, .button: SceneTile(entityId: entityId)
        case .sensor: SensorTile(entityId: entityId)
        case .binarySensor: BinarySensorTile(entityId: entityId)
        case .unknown: GenericTile(entityId: entityId)
        }
    }
}
```

- [ ] **Step 3: Implement `LightTile.swift`**
```swift
import SwiftUI
import HavenCore
struct LightTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId)
        let s = e.map(LightState.init)
        let on = s?.isOn ?? false
        let accent = HavenColor.domain(.light)
        GlassTile(active: on, accent: accent) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Image(systemName: IconMap.symbol(domain: .light, deviceClass: nil))
                        .font(.system(size: 20)).foregroundStyle(on ? accent : .secondary).symbolRenderingMode(.hierarchical)
                    Spacer(minLength: 2)
                    Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(on ? .primary : .secondary)
                }
                if on, let pct = s?.brightnessPercent { Spacer(minLength: 6); LevelBar(percent: pct, color: accent).padding(.vertical, 2) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.toggle(entityId) }
        .onLongPressGesture(minimumDuration: 0.35) { store.presented = entityId }
    }
}
```

- [ ] **Step 4: Implement `SwitchTile.swift`** (same shape, no level bar)
```swift
import SwiftUI
import HavenCore
struct SwitchTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId)
        let on = (e?.state == "on")
        let accent = HavenColor.domain(.switchOutlet)
        GlassTile(active: on, accent: accent) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: IconMap.symbol(domain: .switchOutlet, deviceClass: nil)).font(.system(size: 20)).foregroundStyle(on ? accent : .secondary).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2)
                Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).foregroundStyle(on ? .primary : .secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.toggle(entityId) }
        .onLongPressGesture(minimumDuration: 0.35) { store.presented = entityId }
    }
}
```

- [ ] **Step 5: Add `TileName` helper** (`App/Renderers/TileName.swift`)
```swift
import HavenCore
enum TileName {
    static func of(_ entityId: String, _ e: EntityState?) -> String {
        if let n = e?.attributes["friendly_name"]?.asString, !n.isEmpty { return n }
        let obj = String(entityId.drop(while: { $0 != "." }).dropFirst())
        return obj.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
```

- [ ] **Step 6: Create the seven stub tiles.** Each is a real, compiling view showing icon + name (no interaction yet). Create `CoverTile.swift`, `LockTile.swift`, `ClimateTile.swift`, `SceneTile.swift`, `SensorTile.swift`, `BinarySensorTile.swift`, `GenericTile.swift`, each with this body (substituting the type name and the `Domain` case):

```swift
import SwiftUI
import HavenCore
struct CoverTile: View {            // <- rename per file: LockTile, ClimateTile, SceneTile, SensorTile, BinarySensorTile, GenericTile
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId)
        GlassTile(active: false, accent: .gray) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: IconMap.symbol(domain: Domain.of(entityId), deviceClass: e?.deviceClass))
                    .font(.system(size: 20)).foregroundStyle(.secondary).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2)
                Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
        }
    }
}
```

- [ ] **Step 7: Build** — `xcodegen generate && xcodebuild -project HavenApp.xcodeproj -scheme HavenApp -sdk iphoneos26.5 -configuration Debug build CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED. **Step 8: Commit** (`feat(app): tile dispatch + light/switch tiles + stubs`).

---

### Task 14: Cover + Lock tiles

**Files:** **Replace the stub bodies** of `App/Renderers/Tiles/CoverTile.swift` and `LockTile.swift` (both created in Task 13). **Do NOT edit `DeviceTileView.swift`** — its routing is already complete.

**Interfaces:** Consumes `CoverState`, `LockState`, `LevelBar`, `GlassTile`, `TileName`; adds `store.openCloseCover(_:)` and `store.toggleLock(_:)`. These call `HomeConnection.openCover/closeCover/setLock` **directly** — Task 18 adds the *modal-level* wrappers and must not re-add these two.

- [ ] **Step 1: Add `HomeStore.openCloseCover(_:)`** (if open→close else open, optimistic) and `toggleLock(_:)` (locked→unlock else lock).
- [ ] **Step 2: Implement `CoverTile.swift`**
```swift
import SwiftUI
import HavenCore
struct CoverTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let s = e.map(CoverState.init)
        let open = s?.isOpen ?? false; let accent = HavenColor.domain(.cover)
        GlassTile(active: open, accent: accent) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Image(systemName: IconMap.symbol(domain: .cover, deviceClass: e?.deviceClass)).font(.system(size: 20)).foregroundStyle(open ? accent : .secondary).symbolRenderingMode(.hierarchical)
                    Spacer(minLength: 2); Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).foregroundStyle(open ? .primary : .secondary)
                }
                if let pos = s?.positionPercent { Spacer(minLength: 6); LevelBar(percent: pos, color: accent).padding(.vertical, 2) }
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.openCloseCover(entityId) }.onLongPressGesture(minimumDuration: 0.35) { store.presented = entityId }
    }
}
```
- [ ] **Step 3: Implement `LockTile.swift`** (green when locked; amber when unlocked)
```swift
import SwiftUI
import HavenCore
struct LockTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let s = e.map(LockState.init)
        let locked = s?.isLocked ?? false
        let accent = locked ? HavenColor.domain(.lock) : Color(red: 0.85, green: 0.45, blue: 0.1)
        GlassTile(active: false, accent: accent) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: locked ? "lock.fill" : "lock.open.fill").font(.system(size: 20)).foregroundStyle(accent).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2); Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.toggleLock(entityId) }.onLongPressGesture(minimumDuration: 0.35) { store.presented = entityId }
    }
}
```
- [ ] **Step 4: Route + Build + Commit** (`feat(app): cover + lock tiles`).

---

### Task 15: Climate + Scene tiles

**Files:** **Replace the stub bodies** of `App/Renderers/Tiles/ClimateTile.swift` and `SceneTile.swift` (created in Task 13). **Do NOT edit `DeviceTileView.swift`.**

**Interfaces:** Consumes `ClimateState`; `store.run(_:)` (scene/script/button activation — add to store here). Climate tile is tap→present modal (no direct toggle).

- [ ] **Step 1: Implement `ClimateTile.swift`** (defaults to a `2×2` feel; the wide/tall sizing is applied by the grid in Task 21 via `.gridCellColumns`; here just render richly)
```swift
import SwiftUI
import HavenCore
struct ClimateTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let s = e.map(ClimateState.init)
        let on = s?.isOn ?? false; let accent = HavenColor.domain(.climate)
        GlassTile(active: on, accent: accent) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "thermometer.medium").font(.system(size: 20)).foregroundStyle(accent).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(s?.targetTemp.map { "\(Int($0))°" } ?? "—").font(.system(size: 24, weight: .bold)).foregroundStyle(accent)
                    Text(s.map { "\($0.hvacMode.capitalized)\($0.fanMode.map { " · fan \($0)" } ?? "")" } ?? "").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.presented = entityId }.onLongPressGesture(minimumDuration: 0.35) { store.presented = entityId }
    }
}
```
- [ ] **Step 2: Implement `SceneTile.swift`** (tap runs it)
```swift
import SwiftUI
import HavenCore
struct SceneTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let accent = HavenColor.domain(.scene)
        GlassTile(active: false, accent: accent) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: IconMap.symbol(domain: Domain.of(entityId), deviceClass: nil)).font(.system(size: 20)).foregroundStyle(accent).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2); Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.run(entityId) }
    }
}
```
- [ ] **Step 3: Add `HomeStore.run(_:)`** (calls `activate(sceneOrScript:)`; no optimistic state). Route + Build + Commit (`feat(app): climate + scene tiles`).

---

### Task 16: Sensor + Binary Sensor + Generic tiles

**Files:** **Replace the stub bodies** of `App/Renderers/Tiles/SensorTile.swift`, `BinarySensorTile.swift`, `GenericTile.swift` (created in Task 13). **Do NOT edit `DeviceTileView.swift`.**

- [ ] **Step 1: `SensorTile.swift`** (value + unit; tap→modal)
```swift
import SwiftUI
import HavenCore
struct SensorTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let s = e.map(SensorState.init)
        GlassTile(active: false, accent: .gray) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: IconMap.symbol(domain: .sensor, deviceClass: e?.deviceClass)).font(.system(size: 20)).foregroundStyle(.secondary).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2)
                Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                Text([s?.value, s?.unit].compactMap { $0 }.joined(separator: " ")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.presented = entityId }
    }
}
```
- [ ] **Step 2: `BinarySensorTile.swift`** (active = device_class color glow)
```swift
import SwiftUI
import HavenCore
struct BinarySensorTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let s = e.map(BinarySensorState.init)
        let active = s?.isActive ?? false
        let accent = Color(red: 0.85, green: 0.35, blue: 0.1)
        GlassTile(active: active, accent: accent) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: IconMap.symbol(domain: .binarySensor, deviceClass: e?.deviceClass)).font(.system(size: 20)).foregroundStyle(active ? accent : .secondary).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2); Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.presented = entityId }
    }
}
```
- [ ] **Step 3: `GenericTile.swift`** (state string; tap→more-info modal)
```swift
import SwiftUI
import HavenCore
struct GenericTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId)
        GlassTile(active: false, accent: .gray) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: "square.dashed").font(.system(size: 20)).foregroundStyle(.secondary)
                Spacer(minLength: 2); Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                Text(e?.state ?? "—").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.presented = entityId }
    }
}
```
- [ ] **Step 4: Route all remaining domains + Build + Commit** (`feat(app): sensor, binary-sensor, generic tiles`).

---

## PHASE 6 — Control modals

### Task 17: Modal scaffold + presentation + Light + Switch modals

**Files:** Create `App/DesignSystem/ControlModalScaffold.swift`, `App/Renderers/DeviceModalView.swift`, and **ALL NINE modal files** `App/Renderers/Modals/{Light,Switch,Cover,Lock,Climate,Scene,Sensor,BinarySensor,Generic}Modal.swift` — `LightModal`/`SwitchModal` fully implemented here, the other seven as **minimal stubs** (Step 4b). Modify `App/Views/DashboardView.swift` to present `DeviceModalView(entityId:)` as a sheet bound to `store.presented`.

> Same stub-first rule as Task 13: `DeviceModalView`'s switch is written complete here and **never edited again**; Tasks 18–20 fill stub bodies in place.

**Interfaces:**
- `struct ControlModalScaffold<Header: View, Body: View>: View` — renders the glass header row + a scroll of `body` cards.
- `struct ModalHeader: View { icon, title, subtitle, accent; toggle: Binding<Bool>? (nil = no toggle); onClose }`.
- `struct DeviceModalView: View { let entityId: String }` — dispatches by domain to the concrete modal.

- [ ] **Step 1: Implement `ControlModalScaffold.swift`** (header + cards; `.presentationDetents([.medium, .large])`)
```swift
import SwiftUI
struct ModalHeader: View {
    let systemImage: String; let title: String; let subtitle: String; let accent: Color
    var toggle: Binding<Bool>? = nil
    var onClose: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 20)).foregroundStyle(accent).frame(width: 38, height: 38).background(accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 1) { Text(title).font(.system(size: 16, weight: .bold)); Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer()
            if let toggle { Toggle("", isOn: toggle).labelsHidden().tint(accent) }
            Button { onClose() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary).frame(width: 28, height: 28).background(.gray.opacity(0.15), in: Circle()) }
        }
    }
}
struct FacetCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title { Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary) }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }
}
```

- [ ] **Step 2: Implement `DeviceModalView.swift`**
```swift
import SwiftUI
import HavenCore
struct DeviceModalView: View {
    let entityId: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            switch Domain.of(entityId) {
            case .light: LightModal(entityId: entityId)
            case .switchOutlet: SwitchModal(entityId: entityId)
            case .cover: CoverModal(entityId: entityId)
            case .lock: LockModal(entityId: entityId)
            case .climate: ClimateModal(entityId: entityId)
            case .scene, .script, .button: SceneModal(entityId: entityId)
            case .sensor: SensorModal(entityId: entityId)
            case .binarySensor: BinarySensorModal(entityId: entityId)
            case .unknown: GenericModal(entityId: entityId)
            }
        }
        .padding(16).presentationDetents([.medium, .large]).presentationBackground(.regularMaterial)
    }
}
```
- [ ] **Step 2b: Create the seven stub modals.** `CoverModal.swift`, `LockModal.swift`, `ClimateModal.swift`, `SceneModal.swift`, `SensorModal.swift`, `BinarySensorModal.swift`, `GenericModal.swift`, each compiling with header-only (substitute the type name per file):

```swift
import SwiftUI
import HavenCore
struct CoverModal: View {          // <- rename per file
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let e = store.state(entityId)
        VStack {
            ModalHeader(systemImage: IconMap.symbol(domain: Domain.of(entityId), deviceClass: e?.deviceClass),
                        title: TileName.of(entityId, e), subtitle: e?.state ?? "—", accent: .gray) { dismiss() }
            Spacer()
        }
    }
}
```

- [ ] **Step 3: `LightModal.swift`** (header toggle; brightness slider; color-temp slider if supported)
```swift
import SwiftUI
import HavenCore
struct LightModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let e = store.state(entityId); let s = e.map(LightState.init)
        let accent = HavenColor.domain(.light)
        VStack(spacing: 12) {
            ModalHeader(systemImage: "lightbulb.fill", title: TileName.of(entityId, e),
                        subtitle: (s?.isOn ?? false) ? "On" : "Off", accent: accent,
                        toggle: Binding(get: { s?.isOn ?? false }, set: { store.setLight(entityId, on: $0) })) { dismiss() }
            if s?.supportsBrightness ?? false {
                FacetCard(title: "Brightness") {
                    Slider(value: Binding(get: { Double(s?.brightnessPercent ?? 0) }, set: { store.setBrightness(entityId, percent: Int($0)) }), in: 0...100).tint(accent)
                }
            }
            Spacer()
        }
    }
}
```

- [ ] **Step 4: `SwitchModal.swift`** (header toggle only)
```swift
import SwiftUI
import HavenCore
struct SwitchModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let e = store.state(entityId); let on = e?.state == "on"
        VStack {
            ModalHeader(systemImage: "poweroutlet.type.b.fill", title: TileName.of(entityId, e), subtitle: on ? "On" : "Off", accent: HavenColor.domain(.switchOutlet),
                        toggle: Binding(get: { on }, set: { store.setSwitch(entityId, on: $0) })) { dismiss() }
            Spacer()
        }
    }
}
```

- [ ] **Step 5: Present the sheet.** In `DashboardView` (Task 22 will finalize), add:
```swift
.sheet(isPresented: Binding(get: { store.presented != nil }, set: { if !$0 { store.presented = nil } })) {
    if let id = store.presented { DeviceModalView(entityId: id) }
}
```
**Store additions in this task: ONLY `setBrightness(_:percent:)`.** `setLight` and `setSwitch` already exist from Task 13 — reuse them, do not redefine.
```swift
    func setBrightness(_ id: String, percent: Int) {
        guard let connection else { return }
        Task { try? await connection.setBrightness(id, percent: percent) }
    }
```
Build (`xcodegen generate && xcodebuild … CODE_SIGNING_ALLOWED=NO`) + Commit (`feat(app): control-modal scaffold + light/switch modals`).

---

### Task 18: Climate + Cover modals

**Files:** **Replace the stub bodies** of `App/Renderers/Modals/ClimateModal.swift` and `CoverModal.swift` (created in Task 17). **Do NOT edit `DeviceModalView.swift`.**

- [ ] **Step 1: `ClimateModal.swift`** (header on/off; temp stepper; Mode + Fan segmented)
```swift
import SwiftUI
import HavenCore
struct ClimateModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let e = store.state(entityId); let s = e.map(ClimateState.init)
        let accent = HavenColor.domain(.climate)
        VStack(spacing: 12) {
            ModalHeader(systemImage: "thermometer.medium", title: TileName.of(entityId, e),
                        subtitle: s.map { $0.isOn ? "\($0.hvacMode.capitalized)" : "Off" } ?? "", accent: accent,
                        toggle: Binding(get: { s?.isOn ?? false }, set: { store.setClimateMode(entityId, mode: $0 ? (s?.modes.first { $0 != "off" } ?? "heat") : "off") })) { dismiss() }
            FacetCard {
                HStack {
                    Button { if let t = s?.targetTemp { store.setClimateTemp(entityId, temp: t - 1) } } label: { Image(systemName: "minus.circle.fill").font(.title) }
                    Spacer()
                    VStack { Text(s?.targetTemp.map { "\(Int($0))°" } ?? "—").font(.system(size: 40, weight: .bold))
                        Text(s?.currentTemp.map { "Now \(Int($0))°" } ?? "").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button { if let t = s?.targetTemp { store.setClimateTemp(entityId, temp: t + 1) } } label: { Image(systemName: "plus.circle.fill").font(.title) }
                }.tint(accent)
            }
            if let modes = s?.modes.filter({ $0 != "off" }), modes.count > 1 {
                FacetCard(title: "Mode") { HavenSegmented(options: modes, selection: Binding(get: { s?.hvacMode ?? modes[0] }, set: { store.setClimateMode(entityId, mode: $0) }), label: { $0.capitalized }, accent: accent) }
            }
            if let fans = s?.fanModes, fans.count > 1 {
                FacetCard(title: "Fan") { HavenSegmented(options: fans, selection: Binding(get: { s?.fanMode ?? fans[0] }, set: { store.setFanMode(entityId, mode: $0) }), label: { $0.capitalized }, accent: accent) }
            }
            Spacer()
        }
    }
}
```

- [ ] **Step 2: `CoverModal.swift`** (position slider + open/stop/close)
```swift
import SwiftUI
import HavenCore
struct CoverModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let e = store.state(entityId); let s = e.map(CoverState.init)
        let accent = HavenColor.domain(.cover)
        VStack(spacing: 12) {
            ModalHeader(systemImage: "blinds.horizontal.closed", title: TileName.of(entityId, e), subtitle: (s?.isOpen ?? false) ? "Open" : "Closed", accent: accent) { dismiss() }
            if s?.supportsPosition ?? false {
                FacetCard(title: "Position") { Slider(value: Binding(get: { Double(s?.positionPercent ?? 0) }, set: { store.setCoverPosition(entityId, percent: Int($0)) }), in: 0...100).tint(accent) }
            }
            FacetCard { HStack(spacing: 10) {
                Button("Open") { store.openCover(entityId) }.frame(maxWidth: .infinity)
                Button("Stop") { store.stopCover(entityId) }.frame(maxWidth: .infinity)
                Button("Close") { store.closeCover(entityId) }.frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).tint(accent) }
            Spacer()
        }
    }
}
```

- [ ] **Step 3: Add store methods** — `setClimateMode`, `setClimateTemp`, `setFanMode`, `openCover`, `stopCover`, `closeCover`, `setCoverPosition` (thin `Task { try? await connection.… }` forwards). **`openCloseCover` and `toggleLock` already exist from Task 14 — do not redefine them.** Build + Commit (`feat(app): climate + cover modals`).

---

### Task 19: Lock + Scene + Generic modals

**Files:** **Replace the stub bodies** of `App/Renderers/Modals/LockModal.swift`, `SceneModal.swift`, `GenericModal.swift` (created in Task 17). **Do NOT edit `DeviceModalView.swift`.**

- [ ] **Step 1: `LockModal.swift`** (header lock/unlock toggle)
```swift
import SwiftUI
import HavenCore
struct LockModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let e = store.state(entityId); let s = e.map(LockState.init); let locked = s?.isLocked ?? false
        VStack {
            ModalHeader(systemImage: locked ? "lock.fill" : "lock.open.fill", title: TileName.of(entityId, e), subtitle: locked ? "Locked" : "Unlocked", accent: HavenColor.domain(.lock),
                        toggle: Binding(get: { locked }, set: { store.setLock(entityId, locked: $0) })) { dismiss() }
            Spacer()
        }
    }
}
```
- [ ] **Step 2: `SceneModal.swift`** (run button + name)
```swift
import SwiftUI
import HavenCore
struct SceneModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let e = store.state(entityId)
        VStack(spacing: 14) {
            ModalHeader(systemImage: IconMap.symbol(domain: Domain.of(entityId), deviceClass: nil), title: TileName.of(entityId, e), subtitle: "", accent: HavenColor.domain(.scene)) { dismiss() }
            Button { store.run(entityId); dismiss() } label: { Text("Run").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(HavenColor.domain(.scene))
            Spacer()
        }
    }
}
```
- [ ] **Step 3: `GenericModal.swift`** (state + attributes list)
```swift
import SwiftUI
import HavenCore
struct GenericModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let e = store.state(entityId)
        VStack(spacing: 12) {
            ModalHeader(systemImage: "square.dashed", title: TileName.of(entityId, e), subtitle: e?.state ?? "—", accent: .gray) { dismiss() }
            FacetCard(title: "Attributes") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach((e?.attributes.keys.sorted() ?? []), id: \.self) { k in
                        HStack { Text(k).font(.caption).foregroundStyle(.secondary); Spacer(); Text(String(describing: e?.attributes[k] ?? .null)).font(.caption).lineLimit(1) }
                    }
                }
            }
            Spacer()
        }
    }
}
```
- [ ] **Step 4: Route + Build + Commit** (`feat(app): lock, scene, generic modals`).

---

### Task 20: Sensor history modal (Swift Charts) + Binary Sensor modal

**Files:** **Replace the stub bodies** of `App/Renderers/Modals/SensorModal.swift` and `BinarySensorModal.swift` (created in Task 17). **Do NOT edit `DeviceModalView.swift`.**

**Interfaces:** `SensorModal` loads `store.loadHistory(entityId:range:)` (add to store — calls `HomeConnection.history`, publishes a `HistorySeries`), renders a smoothed Swift `Chart` (`.interpolationMethod(.catmullRom)`) + a `HavenSegmented` range selector + min/avg/max.

- [ ] **Step 1: Add store history hook** (`App/HomeStore.swift`): `var historyByKey: [String: HistorySeries]` and `func loadHistory(_ entityId: String, range: HistoryRange) async` that calls `connection?.history(entityId:range:now: Date())` and stores it under `"\(entityId)#\(range)"`.

- [ ] **Step 2: `SensorModal.swift`**
```swift
import SwiftUI
import Charts
import HavenCore
struct SensorModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var range: HistoryRange = .day
    var body: some View {
        let e = store.state(entityId); let s = e.map(SensorState.init)
        let series = store.history(entityId, range)
        VStack(spacing: 12) {
            ModalHeader(systemImage: IconMap.symbol(domain: .sensor, deviceClass: e?.deviceClass), title: TileName.of(entityId, e), subtitle: "", accent: .blue) { dismiss() }
            FacetCard {
                HStack(alignment: .firstTextBaseline, spacing: 6) { Text(s?.value ?? "—").font(.system(size: 30, weight: .bold)); Text(s?.unit ?? "").foregroundStyle(.secondary) }
                Chart(series?.points ?? [], id: \.time) { p in
                    AreaMark(x: .value("t", p.time), y: .value("v", p.value)).interpolationMethod(.catmullRom).foregroundStyle(.blue.opacity(0.2))
                    LineMark(x: .value("t", p.time), y: .value("v", p.value)).interpolationMethod(.catmullRom).foregroundStyle(.blue)
                }
                .frame(height: 150).chartXAxis(.hidden)
                HavenSegmented(options: HistoryRange.allCases, selection: $range, label: { $0.label }, accent: .blue)
                if let series { HStack(spacing: 16) {
                    stat("Avg", series.avg); stat("Min", series.min); stat("Max", series.max)
                } }
            }
            Spacer()
        }
        .task(id: range) { await store.loadHistory(entityId, range: range) }
    }
    @ViewBuilder private func stat(_ l: String, _ v: Double?) -> some View {
        VStack(alignment: .leading) { Text(l).font(.caption2).foregroundStyle(.secondary); Text(v.map { String(format: "%.0f", $0) } ?? "—").font(.system(size: 14, weight: .semibold)) }
    }
}
```
(Add `HomeStore.history(_:_:) -> HistorySeries?` reading `historyByKey["\(entityId)#\(range)"]`.)

- [ ] **Step 3: `BinarySensorModal.swift`** (state + last-changed; deep timeline deferred)
```swift
import SwiftUI
import HavenCore
struct BinarySensorModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let e = store.state(entityId); let s = e.map(BinarySensorState.init)
        VStack {
            ModalHeader(systemImage: IconMap.symbol(domain: .binarySensor, deviceClass: e?.deviceClass), title: TileName.of(entityId, e),
                        subtitle: (s?.isActive ?? false) ? "Active" : "Clear", accent: (s?.isActive ?? false) ? .orange : .gray) { dismiss() }
            Spacer()
        }
    }
}
```

- [ ] **Step 4: Build + Commit** (`feat(app): sensor history modal (Swift Charts) + binary-sensor modal`).

---

## PHASE 7 — Room section, room detail, wire-in

### Task 21: `HomeStore` roll-up/bulk actions + section access

**Files:** Modify `App/HomeStore.swift`.

**Interfaces:** add `func rooms() -> [RoomSection]` (calls `SectionBuilder.rooms(from: home)`), `func rollups(_ room: RoomSection) -> [Rollup]` (calls `RoomRollups.compute` with the room's device entity ids + `states`), `func allOff(_ rollup: Rollup)` / `func closeAll(_ rollup: Rollup)` (iterate `targetEntityIds`, call the right command, optimistic).

- [ ] **Step 1:** Implement the methods (pure calls into HavenCore + command fan-out). Since these are thin wrappers over already-tested HavenCore functions, no new unit test is required; verify by building. Build.
- [ ] **Step 2: Commit** (`feat(app): store roll-up + bulk room actions`).

---

### Task 22: Rewrite `RoomSectionView` (dispatch + env chips + roll-ups) and wire into floors

**Files:** Modify `App/Views/RoomSectionView.swift`, `App/Views/DashboardView.swift`. **Delete `App/Views/LightTileView.swift` in THIS task** (it is referenced by the old `RoomSectionView` until now; deleting earlier breaks the build). Run `xcodegen generate` after deleting.

**Interfaces:** `RoomSectionView` takes a `RoomSection`; renders heading (name + env chips from `headerSensors` using `store.state`), a roll-up line, and a 4-col grid of `DeviceTileView` for each `deviceRef` (entity only in D). `DashboardView` builds floors → for each floor, the rooms in that floor (filter `store.rooms()` by floor), each as a `RoomSectionView`; add the modal `.sheet` (Task 17 Step 5) and navigation to room detail (Task 23).

- [ ] **Step 1: Implement `RoomSectionView.swift`**
```swift
import SwiftUI
import HavenCore
struct RoomSectionView: View {
    let room: RoomSection
    @Environment(HomeStore.self) private var store
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 9), count: 4)
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(room.name).font(.system(size: 17, weight: .bold))
                Spacer()
                ForEach(room.headerSensors, id: \.entityId) { hs in
                    let v = store.state(hs.entityId)?.state ?? "—"
                    let unit = hs.role == .temperature ? "°" : "%"
                    HavenChip(systemImage: hs.role == .temperature ? "thermometer.medium" : "humidity.fill", text: v + unit,
                              accent: hs.role == .temperature ? HavenColor.domain(.climate) : HavenColor.domain(.cover))
                }
            }
            LazyVGrid(columns: columns, spacing: 9) {
                ForEach(room.deviceRefs) { ref in
                    if case .entity(let id) = ref {
                        DeviceTileView(entityId: id).gridCellColumns(Domain.of(id) == .climate ? 2 : 1)
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Update `DashboardView.swift`** — replace the per-floor `area` loop with `RoomSectionView(room:)` for the floor's rooms, add the modal sheet, and make the room heading tappable to push `RoomDetailView` (Task 23). Concretely, group `store.rooms()` by floor using `store.home.floors` (a room belongs to the floor whose `areas` contains its `areaId`).
```swift
// inside the per-floor NavigationStack ScrollView VStack:
ForEach(floor.areas) { area in
    if let room = store.rooms().first(where: { $0.areaId == area.id }) {
        NavigationLink(value: room.id) { RoomSectionView(room: room).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
}
// on the NavigationStack:
.navigationDestination(for: String.self) { roomId in
    if let room = store.rooms().first(where: { $0.id == roomId }) { RoomDetailView(room: room) }
}
// and add the modal sheet on the TabView (once):
```
- [ ] **Step 3: Build + Commit** (`feat(app): registry-first room sections with dispatch, env chips, roll-ups`).

---

### Task 23: `RoomDetailView` (grouped by domain, per-group roll-up actions)

**Files:** Create `App/Views/RoomDetailView.swift`.

**Interfaces:** groups a room's `deviceRefs` by `Domain` into ordered sections (Climate, Lights, Covers/Shades, Scenes/Locks/Other, Sensors); each group = plain heading (+ roll-up action for Lights/Covers via `store.rollups`) + a 4-col grid; env chips in the nav header.

- [ ] **Step 1: Implement `RoomDetailView.swift`**
```swift
import SwiftUI
import HavenCore
struct RoomDetailView: View {
    let room: RoomSection
    @Environment(HomeStore.self) private var store
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 9), count: 4)
    private func ids(_ ds: Set<Domain>) -> [String] {
        room.deviceRefs.compactMap { if case .entity(let id) = $0, ds.contains(Domain.of(id)) { return id } else { return nil } }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                group("Climate", ids([.climate, .sensor]).filter { Domain.of($0) == .climate } + ids([.sensor]))
                group("Lights", ids([.light]), rollup: .lights)
                group("Shades", ids([.cover]), rollup: .covers)
                group("Scenes & more", ids([.scene, .script, .button, .lock, .switchOutlet, .unknown]))
            }.padding()
        }
        .navigationTitle(room.name).navigationBarTitleDisplayMode(.large)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { HStack(spacing: 7) {
            ForEach(room.headerSensors, id: \.entityId) { hs in
                HavenChip(systemImage: hs.role == .temperature ? "thermometer.medium" : "humidity.fill",
                          text: (store.state(hs.entityId)?.state ?? "—") + (hs.role == .temperature ? "°" : "%"))
            }
        } } }
    }
    @ViewBuilder private func group(_ title: String, _ ids: [String], rollup: Rollup.Kind? = nil) -> some View {
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.system(size: 14, weight: .bold))
                    if let rollup, let r = store.rollups(room).first(where: { $0.kind == rollup }) {
                        Text("\(r.activeCount) \(rollup == .lights ? "on" : "open")").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button(rollup == .lights ? "All off" : "Close all") { rollup == .lights ? store.allOff(r) : store.closeAll(r) }
                            .font(.system(size: 12.5, weight: .semibold)).tint(rollup == .lights ? HavenColor.domain(.light) : HavenColor.domain(.cover))
                    } else { Spacer() }
                }
                LazyVGrid(columns: columns, spacing: 9) {
                    ForEach(ids, id: \.self) { DeviceTileView(entityId: $0).gridCellColumns(Domain.of($0) == .climate ? 2 : 1) }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build + manual smoke** — run the app (Xcode/simulator per prior session): connect, verify tiles render per domain, tap toggles work, long-press opens the right modal with working controls, a sensor modal shows a chart with range switching, and room detail groups + roll-up "All off" works.

- [ ] **Step 3: Commit** (`feat(app): room detail grouped by domain with roll-up actions`).

---

## Self-Review

**Spec coverage:**
- Registry-first structure → Tasks 7, 8, 22 (rooms from registry; no import). ✓
- Section/Room specialization + composite abstraction → Task 8 (`SectionKind`, `RoomSection`, `DeviceRef.entity|.composite`; only `.entity` rendered). ✓
- Uplifted temp/humidity in heading → Tasks 8, 22, 23 (from `area.temperature/humidityEntityId`, icon+value chips). ✓
- Lights/Covers roll-ups (extensible) → Tasks 9, 21, 23. ✓
- Renderer catalog (9 renderers, defer Media/Camera) → Tasks 13–16 (tiles), 17–20 (modals); Media/Camera absent. ✓
- Visual language (glass, active glow, level bars, SF-Symbol icons incl. bulb-thermometer, state-by-color no redundant text) → Tasks 4, 12, 13–16. ✓
- Tap action + long-press modal; header on/off always; segmented for discrete; history only on sensors → Tasks 13–20 (`ModalHeader` toggle, `HavenSegmented` for mode/fan/range, `SensorModal` history). ✓
- Sensor history (value + smoothed chart + Day/Week/Month/3M/Year + stats) → Tasks 10, 11, 20. ✓
- Room detail grouped, no container chrome, per-group roll-up actions → Task 23. ✓
- Command layer per domain → Tasks 5, 6, 17–20 store forwards. ✓
- Architecture (dispatch, typed state, icon map, history service, design system) → Tasks 1–4, 10–12, 13/17. ✓

**Placeholder scan:** No "TBD/TODO"; every code step has complete code. The one "route only-implemented tiles/modals, send rest to Generic" instruction is an explicit incremental-build technique, not a placeholder — `GenericTile`/`GenericModal` are fully implemented (Tasks 16, 19), and the executor updates routing as each renderer lands.

**Type consistency:** `store.state(_:)`, `store.presented`, `store.toggle(_:)`, `store.setLight/setBrightness/setSwitch/openCover/closeCover/stopCover/setCoverPosition/setLock/setClimateMode/setClimateTemp/setFanMode/run/allOff/closeAll/rooms/rollups/history/loadHistory` are used consistently across Tasks 13–23 and each is defined in the task that first needs it (13, 14, 15, 17, 18, 20, 21). `HomeConnection.client` is made `internal` in Task 6 (used by Tasks 6, 11). `ResolvedArea` new fields (Task 7) consumed in Task 8. `HistorySeries`/`HistoryRange` (Task 10) consumed in Tasks 11, 20.

**Known checks for the executor (not defects):** confirm exact SF Symbol names exist on iOS 26 (fallbacks are harmless if a glyph is missing); confirm `Slider`/`Chart`/`.gridCellColumns` API spellings against the live SDK; the HA `history/statistics` WS result shapes should be validated against the real server during the Task 23 smoke test (parsing is defensive).
