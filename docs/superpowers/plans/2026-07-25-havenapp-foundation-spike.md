# HavenApp Foundation Spike — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove HavenApp's architecture end-to-end with a native iOS 26 SwiftUI app that logs into Home Assistant via OAuth, opens the HA WebSocket, resolves the floor/area/device/entity registry into a floors→rooms structure, subscribes to live state, and renders a Light tile that reflects live state and toggles optimistically.

**Architecture:** All non-UI logic lives in a Swift package `HavenCore` with protocol-abstracted I/O (WebSocket, web-auth, HTTP, Keychain) so it is unit-testable with fakes via `swift test`. A thin SwiftUI app target (`HavenApp`, generated with XcodeGen) consumes `HavenCore`, provides the `ASWebAuthenticationSession` presentation anchor and the SwiftUI views. A `HAWebSocketClient` **actor** owns the socket, message-id correlation, heartbeat, and request/response; a `@MainActor @Observable HomeStore` owns UI state, reconnect/backoff, and optimistic writes.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Concurrency (actors, async/await, AsyncStream), Swift Testing (`import Testing`), `URLSessionWebSocketTask`, `AuthenticationServices` (`ASWebAuthenticationSession`), `Security` (Keychain), XcodeGen for the app project.

## Global Constraints

- **Platform floor:** iOS 26.0. SwiftPM platform `.iOS("26.0")`. Swift tools version `6.0`.
- **Language mode:** Swift 6, strict concurrency (`swiftLanguageModes: [.v6]`). All shared types `Sendable`; all UI types `@MainActor`.
- **No third-party dependencies** except XcodeGen (a build tool, not linked). Networking uses `URLSession` only.
- **Auth:** OAuth2 (HA IndieAuth). `client_id = https://timmead.github.io/HavenApp/oauth/` ; `redirect_uri = havenapp://oauth/callback`. Tokens stored in Keychain, never in UserDefaults.
- **Bundle id:** `app.haven.HavenApp`. URL scheme: `havenapp`.
- **HA endpoints (stock, no custom integration in this slice):** WebSocket `ws(s)://<host>/api/websocket`; REST `POST <base>/auth/token`; OAuth `GET <base>/auth/authorize`.
- **Naming:** package `HavenCore`, app target `HavenApp`, test target `HavenCoreTests`.
- **Commits:** one per task minimum; conventional-commit messages; end every commit body with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **JSON decoding:** a single shared `JSONDecoder` with `.keyDecodingStrategy = .convertFromSnakeCase` and `.dateDecodingStrategy` handled per-type (HA sends ISO8601 with fractional seconds for `last_updated`).

---

## File Structure

```
HavenApp/                              # repo root (already a git repo)
├─ project.yml                         # XcodeGen spec for the app
├─ Packages/
│  └─ HavenCore/
│     ├─ Package.swift
│     ├─ Sources/HavenCore/
│     │  ├─ Support/JSONValue.swift            # arbitrary-JSON value type
│     │  ├─ Support/Coding.swift               # shared encoder/decoder
│     │  ├─ Models/EntityState.swift           # live entity state
│     │  ├─ Models/Registry.swift              # floor/area/device/entity registry entries
│     │  ├─ Models/ResolvedHome.swift          # floors→areas→entities projection
│     │  ├─ Registry/RegistryResolver.swift    # pure entity→area→floor resolution
│     │  ├─ Protocol/WSMessages.swift          # Codable wire messages
│     │  ├─ Networking/WebSocketConnection.swift  # protocol + URLSession impl
│     │  ├─ Networking/HAWebSocketClient.swift    # the actor
│     │  ├─ Networking/ReconnectPolicy.swift      # pure backoff
│     │  ├─ Auth/TokenStore.swift              # protocol + KeychainTokenStore
│     │  ├─ Auth/WebAuthSession.swift          # protocol abstracting ASWebAuthenticationSession
│     │  ├─ Auth/OAuthClient.swift             # authorize URL, token exchange, refresh
│     │  └─ Session/HomeConnection.swift       # ties auth+socket+registry (orchestration façade)
│     └─ Tests/HavenCoreTests/
│        ├─ RegistryResolverTests.swift
│        ├─ WSMessagesTests.swift
│        ├─ HAWebSocketClientTests.swift
│        ├─ ReconnectPolicyTests.swift
│        ├─ OAuthClientTests.swift
│        └─ Fakes.swift                        # FakeWebSocketConnection, FakeWebAuthSession, FakeHTTP
├─ App/
│  ├─ HavenAppApp.swift                 # @main App + URL scheme handling
│  ├─ AppModel.swift                    # @MainActor @Observable root + reconnect/backoff
│  ├─ HomeStore.swift                   # @MainActor @Observable live entity + structure store
│  ├─ WebAuthPresenter.swift            # ASWebAuthenticationSession + presentation anchor
│  ├─ Views/RootView.swift              # login gate ↔ dashboard
│  ├─ Views/LoginView.swift             # URL entry + Sign in
│  ├─ Views/DashboardView.swift         # floors-as-tabs → room sections
│  ├─ Views/RoomSectionView.swift       # 4-col grid of tiles
│  └─ Views/LightTileView.swift         # the live, optimistic light tile
├─ App/Resources/Info.plist             # URL types, ATS
└─ docs/oauth/index.html                # hosted client_id page (GitHub Pages)
```

---

### Task 1: Scaffold package + app project

**Files:**
- Create: `Packages/HavenCore/Package.swift`
- Create: `Packages/HavenCore/Sources/HavenCore/Support/Coding.swift`
- Create: `Packages/HavenCore/Tests/HavenCoreTests/SmokeTests.swift`
- Create: `project.yml`
- Create: `App/HavenAppApp.swift`, `App/Resources/Info.plist`

**Interfaces:**
- Produces: `enum HavenCoreVersion { static let current = "0.1.0" }`; shared `HACoding.decoder`/`HACoding.encoder`.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HavenCore",
    platforms: [.iOS("26.0")],
    products: [.library(name: "HavenCore", targets: ["HavenCore"])],
    targets: [
        .target(name: "HavenCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "HavenCoreTests", dependencies: ["HavenCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
```

- [ ] **Step 2: Write shared coding + version (`Support/Coding.swift`)**

```swift
import Foundation

public enum HavenCoreVersion { public static let current = "0.1.0" }

public enum HACoding {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
}
```

- [ ] **Step 3: Write the smoke test (`SmokeTests.swift`)**

```swift
import Testing
@testable import HavenCore

@Test func versionIsSet() {
    #expect(HavenCoreVersion.current == "0.1.0")
}
```

- [ ] **Step 4: Run tests — verify pass**

Run: `cd Packages/HavenCore && swift test`
Expected: 1 test passes.

- [ ] **Step 5: Write `project.yml` (XcodeGen)**

```yaml
name: HavenApp
options:
  bundleIdPrefix: app.haven
  deploymentTarget:
    iOS: "26.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
packages:
  HavenCore:
    path: Packages/HavenCore
targets:
  HavenApp:
    type: application
    platform: iOS
    sources: [App]
    dependencies:
      - package: HavenCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.haven.HavenApp
        INFOPLIST_FILE: App/Resources/Info.plist
        TARGETED_DEVICE_FAMILY: "1,2"
        GENERATE_INFOPLIST_FILE: NO
```

- [ ] **Step 6: Write `App/Resources/Info.plist`** (URL scheme + allow cleartext for local HTTP HA)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDisplayName</key><string>Haven</string>
  <key>UILaunchScreen</key><dict/>
  <key>NSAppTransportSecurity</key><dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>app.haven.HavenApp</string>
    <key>CFBundleURLSchemes</key><array><string>havenapp</string></array>
  </dict></array>
</dict></plist>
```

- [ ] **Step 7: Write minimal `App/HavenAppApp.swift`** (replaced in Task 11; placeholder that builds)

```swift
import SwiftUI

@main
struct HavenAppApp: App {
    var body: some Scene {
        WindowGroup { Text("Haven") }
    }
}
```

- [ ] **Step 8: Generate project and build**

Run: `brew install xcodegen && xcodegen generate`
Run: `xcodebuild -project HavenApp.xcodeproj -scheme HavenApp -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 9: Ignore generated project, commit**

```bash
printf '\n# XcodeGen output\nHavenApp.xcodeproj/\n' >> .gitignore
git add .gitignore project.yml App Packages
git commit -m "chore: scaffold HavenCore package and HavenApp app target

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `JSONValue` + `EntityState`

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Support/JSONValue.swift`
- Create: `Packages/HavenCore/Sources/HavenCore/Models/EntityState.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/EntityStateTests.swift`

**Interfaces:**
- Produces: `enum JSONValue: Codable, Sendable, Equatable` with `.double`, `.string`, `.bool`, `.int`, `.array`, `.object`, `.null`, and accessors `asDouble`, `asString`, `asInt`.
- Produces: `struct EntityState: Sendable, Equatable { var entityId: String; var state: String; var attributes: [String: JSONValue]; var lastUpdated: Date }` with `var domain: String`.

- [ ] **Step 1: Write failing tests (`EntityStateTests.swift`)**

```swift
import Testing
import Foundation
@testable import HavenCore

@Test func domainIsPrefixBeforeDot() {
    let s = EntityState(entityId: "light.kitchen", state: "on", attributes: [:], lastUpdated: .init())
    #expect(s.domain == "light")
}

@Test func jsonValueDecodesMixedAttributes() throws {
    let json = #"{"brightness": 254, "friendly_name": "Kitchen", "on": true, "nested": {"x": 1.5}}"#.data(using: .utf8)!
    let v = try HACoding.decoder.decode([String: JSONValue].self, from: json)
    #expect(v["brightness"]?.asInt == 254)
    #expect(v["friendly_name"]?.asString == "Kitchen")
    #expect(v["on"] == .bool(true))
    #expect(v["nested"]?.asObject?["x"]?.asDouble == 1.5)
}
```

- [ ] **Step 2: Run — verify fails** (`swift test --filter EntityStateTests`) → FAIL (types undefined).

- [ ] **Step 3: Implement `JSONValue.swift`**

```swift
import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), int(Int), double(Double), bool(Bool)
    case array([JSONValue]), object([String: JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }
    public var asString: String? { if case .string(let s) = self { return s }; return nil }
    public var asInt: Int? {
        switch self { case .int(let i): return i; case .double(let d): return Int(d); default: return nil }
    }
    public var asDouble: Double? {
        switch self { case .double(let d): return d; case .int(let i): return Double(i); default: return nil }
    }
    public var asObject: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
}
```

- [ ] **Step 4: Implement `EntityState.swift`**

```swift
import Foundation

public struct EntityState: Sendable, Equatable, Identifiable {
    public var entityId: String
    public var state: String
    public var attributes: [String: JSONValue]
    public var lastUpdated: Date
    public var id: String { entityId }
    public var domain: String { String(entityId.prefix(while: { $0 != "." })) }

    public init(entityId: String, state: String, attributes: [String: JSONValue], lastUpdated: Date) {
        self.entityId = entityId; self.state = state
        self.attributes = attributes; self.lastUpdated = lastUpdated
    }
}
```

- [ ] **Step 5: Run — verify pass** (`swift test --filter EntityStateTests`) → PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/HavenCore
git commit -m "feat(core): add JSONValue and EntityState models

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Registry models + `RegistryResolver` (pure)

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Models/Registry.swift`
- Create: `Packages/HavenCore/Sources/HavenCore/Models/ResolvedHome.swift`
- Create: `Packages/HavenCore/Sources/HavenCore/Registry/RegistryResolver.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/RegistryResolverTests.swift`

**Interfaces:**
- Produces: `struct FloorRegistryEntry/AreaRegistryEntry/DeviceRegistryEntry/EntityRegistryEntry: Codable, Sendable` (snake_case decoded).
- Produces: `struct ResolvedHome`, `ResolvedFloor { id, name, level, areas }`, `ResolvedArea { id, name, entityIds }`.
- Produces: `enum RegistryResolver { static func resolve(floors:areas:devices:entities:) -> ResolvedHome }` — applies `entity.areaId ?? device.areaId`, groups entities by area, areas by floor (nil floor → synthetic "No Floor"), unassigned entities → synthetic "Unassigned" area; floors sorted by `level` asc (nil level → 0), areas sorted by name.

- [ ] **Step 1: Write failing tests (`RegistryResolverTests.swift`)**

```swift
import Testing
@testable import HavenCore

private func ent(_ id: String, area: String? = nil, device: String? = nil) -> EntityRegistryEntry {
    .init(entityId: id, areaId: area, deviceId: device, name: nil)
}

@Test func entityInheritsAreaFromDevice() {
    let floors = [FloorRegistryEntry(floorId: "f1", name: "Ground", level: 0, icon: nil)]
    let areas = [AreaRegistryEntry(areaId: "a1", name: "Kitchen", floorId: "f1", icon: nil,
                                   temperatureEntityId: nil, humidityEntityId: nil)]
    let devices = [DeviceRegistryEntry(id: "d1", areaId: "a1", name: "Hue", nameByUser: nil)]
    let entities = [ent("light.kitchen", area: nil, device: "d1")]   // inherits a1 from device
    let home = RegistryResolver.resolve(floors: floors, areas: areas, devices: devices, entities: entities)
    #expect(home.floors.first?.areas.first?.entityIds == ["light.kitchen"])
}

@Test func directEntityAreaOverridesDevice() {
    let areas = [AreaRegistryEntry(areaId: "a1", name: "Kitchen", floorId: nil, icon: nil, temperatureEntityId: nil, humidityEntityId: nil),
                 AreaRegistryEntry(areaId: "a2", name: "Den", floorId: nil, icon: nil, temperatureEntityId: nil, humidityEntityId: nil)]
    let devices = [DeviceRegistryEntry(id: "d1", areaId: "a1", name: nil, nameByUser: nil)]
    let entities = [ent("light.x", area: "a2", device: "d1")]        // direct a2 wins
    let home = RegistryResolver.resolve(floors: [], areas: areas, devices: devices, entities: entities)
    let den = home.floors.flatMap(\.areas).first { $0.name == "Den" }
    #expect(den?.entityIds == ["light.x"])
}

@Test func floorsSortedByLevel() {
    let floors = [FloorRegistryEntry(floorId: "up", name: "Upstairs", level: 1, icon: nil),
                  FloorRegistryEntry(floorId: "base", name: "Basement", level: -1, icon: nil)]
    let areas = [AreaRegistryEntry(areaId: "a", name: "A", floorId: "up", icon: nil, temperatureEntityId: nil, humidityEntityId: nil),
                 AreaRegistryEntry(areaId: "b", name: "B", floorId: "base", icon: nil, temperatureEntityId: nil, humidityEntityId: nil)]
    let home = RegistryResolver.resolve(floors: floors, areas: areas, devices: [], entities: [])
    #expect(home.floors.map(\.name) == ["Basement", "Upstairs"])
}

@Test func unassignedEntitiesBucketed() {
    let entities = [ent("sensor.orphan")]
    let home = RegistryResolver.resolve(floors: [], areas: [], devices: [], entities: entities)
    #expect(home.floors.flatMap(\.areas).flatMap(\.entityIds) == ["sensor.orphan"])
}
```

- [ ] **Step 2: Run — verify fails** (`swift test --filter RegistryResolverTests`).

- [ ] **Step 3: Implement `Registry.swift`**

```swift
import Foundation

public struct FloorRegistryEntry: Codable, Sendable {
    public let floorId: String; public let name: String; public let level: Int?; public let icon: String?
    public init(floorId: String, name: String, level: Int?, icon: String?) {
        self.floorId = floorId; self.name = name; self.level = level; self.icon = icon
    }
}
public struct AreaRegistryEntry: Codable, Sendable {
    public let areaId: String; public let name: String; public let floorId: String?; public let icon: String?
    public let temperatureEntityId: String?; public let humidityEntityId: String?
    public init(areaId: String, name: String, floorId: String?, icon: String?,
                temperatureEntityId: String?, humidityEntityId: String?) {
        self.areaId = areaId; self.name = name; self.floorId = floorId; self.icon = icon
        self.temperatureEntityId = temperatureEntityId; self.humidityEntityId = humidityEntityId
    }
}
public struct DeviceRegistryEntry: Codable, Sendable {
    public let id: String; public let areaId: String?; public let name: String?; public let nameByUser: String?
    public init(id: String, areaId: String?, name: String?, nameByUser: String?) {
        self.id = id; self.areaId = areaId; self.name = name; self.nameByUser = nameByUser
    }
}
public struct EntityRegistryEntry: Codable, Sendable {
    public let entityId: String; public let areaId: String?; public let deviceId: String?; public let name: String?
    public init(entityId: String, areaId: String?, deviceId: String?, name: String?) {
        self.entityId = entityId; self.areaId = areaId; self.deviceId = deviceId; self.name = name
    }
}
```

- [ ] **Step 4: Implement `ResolvedHome.swift`**

```swift
public struct ResolvedHome: Sendable, Equatable {
    public var floors: [ResolvedFloor]
    public init(floors: [ResolvedFloor]) { self.floors = floors }
}
public struct ResolvedFloor: Sendable, Equatable, Identifiable {
    public let id: String; public let name: String; public let level: Int; public var areas: [ResolvedArea]
    public init(id: String, name: String, level: Int, areas: [ResolvedArea]) {
        self.id = id; self.name = name; self.level = level; self.areas = areas
    }
}
public struct ResolvedArea: Sendable, Equatable, Identifiable {
    public let id: String; public let name: String; public var entityIds: [String]
    public init(id: String, name: String, entityIds: [String]) {
        self.id = id; self.name = name; self.entityIds = entityIds
    }
}
```

- [ ] **Step 5: Implement `RegistryResolver.swift`**

```swift
import Foundation

public enum RegistryResolver {
    static let noFloorId = "__no_floor__"
    static let unassignedAreaId = "__unassigned__"

    public static func resolve(floors: [FloorRegistryEntry], areas: [AreaRegistryEntry],
                               devices: [DeviceRegistryEntry], entities: [EntityRegistryEntry]) -> ResolvedHome {
        let deviceArea = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.areaId) })

        // area_id -> [entity_id], applying entity.areaId ?? device.areaId
        var entitiesByArea: [String: [String]] = [:]
        for e in entities {
            let resolvedArea = e.areaId ?? e.deviceId.flatMap { deviceArea[$0] ?? nil } ?? unassignedAreaId
            entitiesByArea[resolvedArea, default: []].append(e.entityId)
        }

        var areaModels = areas.map {
            ResolvedArea(id: $0.areaId, name: $0.name, entityIds: (entitiesByArea[$0.areaId] ?? []).sorted())
        }
        if let orphans = entitiesByArea[unassignedAreaId], !orphans.isEmpty {
            areaModels.append(ResolvedArea(id: unassignedAreaId, name: "Unassigned", entityIds: orphans.sorted()))
        }

        // area_id -> floor_id, plus synthetic floor for nil
        let areaFloor = Dictionary(uniqueKeysWithValues: areas.map { ($0.areaId, $0.floorId) })
        var areasByFloor: [String: [ResolvedArea]] = [:]
        for a in areaModels {
            let fid = (a.id == unassignedAreaId ? nil : areaFloor[a.id] ?? nil) ?? noFloorId
            areasByFloor[fid, default: []].append(a)
        }

        var floorModels: [ResolvedFloor] = floors.compactMap { f in
            guard let list = areasByFloor[f.floorId], !list.isEmpty else { return nil }
            return ResolvedFloor(id: f.floorId, name: f.name, level: f.level ?? 0,
                                 areas: list.sorted { $0.name < $1.name })
        }
        if let noFloorAreas = areasByFloor[noFloorId], !noFloorAreas.isEmpty {
            floorModels.append(ResolvedFloor(id: noFloorId, name: "Home", level: Int.max,
                                             areas: noFloorAreas.sorted { $0.name < $1.name }))
        }
        return ResolvedHome(floors: floorModels.sorted { $0.level < $1.level })
    }
}
```

- [ ] **Step 6: Run — verify pass** (`swift test --filter RegistryResolverTests`) → 4 pass.

- [ ] **Step 7: Commit**

```bash
git add Packages/HavenCore
git commit -m "feat(core): registry models and pure entity→area→floor resolver

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: WebSocket wire messages

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Protocol/WSMessages.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/WSMessagesTests.swift`

**Interfaces:**
- Produces: `enum ServerFrame` decoded from HA JSON: `.authRequired`, `.authOK`, `.authInvalid(String)`, `.result(id: Int, success: Bool, result: JSONValue?, error: WSError?)`, `.event(id: Int, event: JSONValue)`, `.pong(id: Int)`.
- Produces: `struct WSError: Sendable, Equatable { let code: String; let message: String }`.
- Produces: `struct StateChangedEvent` decoded from an event payload's `event.data`, exposing `newState: EntityState?`.
- Produces: encoders `WSCommand.auth(token:)`, `.getStates(id:)`, `.subscribeEvents(id:,eventType:)`, `.callService(id:,domain:,service:,entityId:)`, `.registryList(id:,type:)`, `.ping(id:)` each producing `Data` (JSON).

- [ ] **Step 1: Write failing tests (`WSMessagesTests.swift`)**

```swift
import Testing
import Foundation
@testable import HavenCore

@Test func decodesAuthRequired() throws {
    let f = try ServerFrame.decode(#"{"type":"auth_required","ha_version":"2026.7"}"#)
    #expect(f == .authRequired)
}
@Test func decodesResultSuccess() throws {
    let f = try ServerFrame.decode(#"{"id":5,"type":"result","success":true,"result":[]}"#)
    guard case let .result(id, success, _, error) = f else { Issue.record("wrong frame"); return }
    #expect(id == 5 && success && error == nil)
}
@Test func decodesResultError() throws {
    let f = try ServerFrame.decode(#"{"id":6,"type":"result","success":false,"error":{"code":"x","message":"nope"}}"#)
    guard case let .result(_, success, _, error) = f else { Issue.record("wrong"); return }
    #expect(!success && error == WSError(code: "x", message: "nope"))
}
@Test func decodesStateChangedEvent() throws {
    let json = #"""
    {"id":9,"type":"event","event":{"event_type":"state_changed","data":{"entity_id":"light.k",
    "new_state":{"entity_id":"light.k","state":"on","attributes":{"brightness":200},"last_updated":"2026-07-25T10:00:00.000000+00:00"}}}}
    """#
    guard case let .event(_, payload) = try ServerFrame.decode(json) else { Issue.record("not event"); return }
    let sc = try StateChangedEvent(eventPayload: payload)
    #expect(sc.newState?.entityId == "light.k")
    #expect(sc.newState?.attributes["brightness"]?.asInt == 200)
}
@Test func encodesAuth() throws {
    let data = WSCommand.auth(token: "abc")
    let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(obj["type"] as? String == "auth")
    #expect(obj["access_token"] as? String == "abc")
}
@Test func encodesCallService() throws {
    let data = WSCommand.callService(id: 3, domain: "light", service: "toggle", entityId: "light.k")
    let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(obj["type"] as? String == "call_service")
    #expect(obj["domain"] as? String == "light")
    let target = obj["target"] as? [String: Any]
    #expect(target?["entity_id"] as? String == "light.k")
}
```

- [ ] **Step 2: Run — verify fails.**

- [ ] **Step 3: Implement `WSMessages.swift`**

```swift
import Foundation

public struct WSError: Sendable, Equatable, Error { public let code: String; public let message: String }

public enum ServerFrame: Sendable, Equatable {
    case authRequired, authOK
    case authInvalid(String)
    case result(id: Int, success: Bool, result: JSONValue?, error: WSError?)
    case event(id: Int, event: JSONValue)
    case pong(id: Int)

    public static func decode(_ text: String) throws -> ServerFrame {
        try decode(Data(text.utf8))
    }
    public static func decode(_ data: Data) throws -> ServerFrame {
        struct Raw: Decodable {
            let id: Int?; let type: String; let success: Bool?
            let result: JSONValue?; let event: JSONValue?
            struct E: Decodable { let code: String; let message: String }
            let error: E?
        }
        // NB: use a plain decoder (no snake_case) so nested attribute keys survive verbatim.
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        switch raw.type {
        case "auth_required": return .authRequired
        case "auth_ok": return .authOK
        case "auth_invalid": return .authInvalid(raw.error?.message ?? "invalid")
        case "pong": return .pong(id: raw.id ?? 0)
        case "event": return .event(id: raw.id ?? 0, event: raw.event ?? .null)
        case "result":
            return .result(id: raw.id ?? 0, success: raw.success ?? false, result: raw.result,
                           error: raw.error.map { WSError(code: $0.code, message: $0.message) })
        default: return .result(id: raw.id ?? 0, success: raw.success ?? false, result: raw.result, error: nil)
        }
    }
}

public struct StateChangedEvent: Sendable {
    public let entityId: String
    public let newState: EntityState?
    public init(eventPayload: JSONValue) throws {
        guard let data = eventPayload.asObject?["data"]?.asObject else {
            throw WSError(code: "bad_event", message: "missing data")
        }
        self.entityId = data["entity_id"]?.asString ?? ""
        self.newState = Self.parseState(data["new_state"])
    }
    static func parseState(_ v: JSONValue?) -> EntityState? {
        guard let o = v?.asObject, let eid = o["entity_id"]?.asString, let st = o["state"]?.asString
        else { return nil }
        let attrs = o["attributes"]?.asObject ?? [:]
        let date = o["last_updated"]?.asString.flatMap(ISO8601.date(from:)) ?? Date()
        return EntityState(entityId: eid, state: st, attributes: attrs, lastUpdated: date)
    }
}

enum ISO8601 {
    static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func date(from s: String) -> Date? { fmt.date(from: s) }
}

public enum WSCommand {
    private static func data(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }
    public static func auth(token: String) -> Data { data(["type": "auth", "access_token": token]) }
    public static func ping(id: Int) -> Data { data(["id": id, "type": "ping"]) }
    public static func getStates(id: Int) -> Data { data(["id": id, "type": "get_states"]) }
    public static func registryList(id: Int, type: String) -> Data { data(["id": id, "type": type]) }
    public static func subscribeEvents(id: Int, eventType: String) -> Data {
        data(["id": id, "type": "subscribe_events", "event_type": eventType])
    }
    public static func callService(id: Int, domain: String, service: String, entityId: String) -> Data {
        data(["id": id, "type": "call_service", "domain": domain, "service": service,
              "target": ["entity_id": entityId]])
    }
}
```

- [ ] **Step 4: Run — verify pass** (`swift test --filter WSMessagesTests`).

- [ ] **Step 5: Commit**

```bash
git add Packages/HavenCore
git commit -m "feat(core): HA websocket wire message encode/decode

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `WebSocketConnection` protocol + URLSession impl + fake

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Networking/WebSocketConnection.swift`
- Create: `Packages/HavenCore/Tests/HavenCoreTests/Fakes.swift`

**Interfaces:**
- Produces: `protocol WebSocketConnection: Sendable { func connect() async throws; func send(_ data: Data) async throws; func receive() async throws -> Data; func close() }`.
- Produces: `final class URLSessionWebSocketConnection: WebSocketConnection` (init with `URL`).
- Produces (test): `actor FakeWebSocketConnection: WebSocketConnection` with `func enqueueIncoming(_ text: String)` and `var sent: [Data]`.

- [ ] **Step 1: Implement `WebSocketConnection.swift`**

```swift
import Foundation

public protocol WebSocketConnection: Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

public final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let url: URL
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    public init(url: URL, session: URLSession = .shared) {
        self.url = url; self.session = session
        self.task = session.webSocketTask(with: url)
    }
    public func connect() async throws { task.resume() }
    public func send(_ data: Data) async throws { try await task.send(.data(data)) }
    public func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let d): return d
        case .string(let s): return Data(s.utf8)
        @unknown default: return Data()
        }
    }
    public func close() { task.cancel(with: .goingAway, reason: nil) }
}
```

- [ ] **Step 2: Implement `Fakes.swift` (test target) — FakeWebSocketConnection**

```swift
import Foundation
@testable import HavenCore

actor FakeWebSocketConnection: WebSocketConnection {
    private var incoming: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private(set) var sent: [Data] = []
    var onSend: (@Sendable (Data) async -> Void)?

    func connect() async throws {}
    func close() {}
    func send(_ data: Data) async throws {
        sent.append(data)
        await onSend?(data)
    }
    func receive() async throws -> Data {
        if !incoming.isEmpty { return incoming.removeFirst() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func enqueueIncoming(_ text: String) {
        let data = Data(text.utf8)
        if !waiters.isEmpty { waiters.removeFirst().resume(returning: data) }
        else { incoming.append(data) }
    }
    func sentTexts() -> [String] { sent.map { String(decoding: $0, as: UTF8.self) } }
}
```

- [ ] **Step 3: Build tests to ensure it compiles**

Run: `swift build --build-tests`
Expected: builds.

- [ ] **Step 4: Commit**

```bash
git add Packages/HavenCore
git commit -m "feat(core): WebSocketConnection protocol, URLSession impl, fake

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: `HAWebSocketClient` actor — handshake + request/response

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Networking/HAWebSocketClient.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/HAWebSocketClientTests.swift`

**Interfaces:**
- Produces: `actor HAWebSocketClient` with `init(connection: WebSocketConnection)`, `func authenticate(token: String) async throws`, `func request(_ make: (Int) -> Data) async throws -> JSONValue` (assigns next id, sends, awaits matching `result`, throws `WSError` on failure), and `var events: AsyncStream<ServerFrame>` for event/pong frames. Starts a private receive loop on first `authenticate`.

- [ ] **Step 1: Write failing tests (`HAWebSocketClientTests.swift`)**

```swift
import Testing
import Foundation
@testable import HavenCore

@Test func authHandshakeSendsTokenAfterAuthRequired() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "tok")
    let texts = await conn.sentTexts()
    #expect(texts.contains { $0.contains("\"type\":\"auth\"") && $0.contains("tok") })
}

@Test func authInvalidThrows() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_invalid","error":{"code":"x","message":"bad"}}"#)
    await #expect(throws: (any Error).self) { try await client.authenticate(token: "tok") }
}

@Test func requestCorrelatesResultById() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    // When the client sends a command, reply with a success result for its id.
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let id = obj?["id"] as? Int, obj?["type"] as? String == "get_states" {
            await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":[1,2,3]}"#)
        }
    }
    let result = try await client.request { WSCommand.getStates(id: $0) }
    #expect(result.asArray?.count == 3)
}
```

Add helper accessors used above to `Fakes.swift`:

```swift
extension FakeWebSocketConnection {
    func setOnSend(_ f: @escaping @Sendable (Data) async -> Void) { self.onSend = f }
}
extension JSONValue { var asArray: [JSONValue]? { if case .array(let a) = self { return a }; return nil } }
```

- [ ] **Step 2: Run — verify fails.**

- [ ] **Step 3: Implement `HAWebSocketClient.swift`**

```swift
import Foundation

public actor HAWebSocketClient {
    private let connection: WebSocketConnection
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var receiveLoop: Task<Void, Never>?
    private var eventContinuation: AsyncStream<ServerFrame>.Continuation?
    public let events: AsyncStream<ServerFrame>

    public init(connection: WebSocketConnection) {
        self.connection = connection
        var cont: AsyncStream<ServerFrame>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventContinuation = cont
    }

    public func authenticate(token: String) async throws {
        try await connection.connect()
        let first = try ServerFrame.decode(try await connection.receive())
        guard first == .authRequired else { throw WSError(code: "proto", message: "expected auth_required") }
        try await connection.send(WSCommand.auth(token: token))
        let second = try ServerFrame.decode(try await connection.receive())
        switch second {
        case .authOK: startReceiveLoop()
        case .authInvalid(let m): throw WSError(code: "auth_invalid", message: m)
        default: throw WSError(code: "proto", message: "expected auth_ok")
        }
    }

    public func request(_ make: (Int) -> Data) async throws -> JSONValue {
        let id = nextId; nextId += 1
        let data = make(id)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task {
                do { try await connection.send(data) }
                catch { pending[id] = nil; cont.resume(throwing: error) }
            }
        }
    }

    private func startReceiveLoop() {
        guard receiveLoop == nil else { return }
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let data = try await self.connection.receive()
                    await self.handle(try ServerFrame.decode(data))
                } catch {
                    await self.failAll(with: error); return
                }
            }
        }
    }

    private func handle(_ frame: ServerFrame) {
        switch frame {
        case .result(let id, let success, let result, let error):
            guard let cont = pending.removeValue(forKey: id) else { return }
            if success { cont.resume(returning: result ?? .null) }
            else { cont.resume(throwing: error ?? WSError(code: "unknown", message: "failed")) }
        case .event, .pong:
            eventContinuation?.yield(frame)
        case .authRequired, .authOK, .authInvalid:
            break
        }
    }

    private func failAll(with error: Error) {
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
        eventContinuation?.finish()
    }

    public func disconnect() {
        receiveLoop?.cancel(); receiveLoop = nil
        connection.close()
        failAll(with: WSError(code: "closed", message: "disconnected"))
    }
}
```

- [ ] **Step 4: Run — verify pass** (`swift test --filter HAWebSocketClientTests`).

- [ ] **Step 5: Commit**

```bash
git add Packages/HavenCore
git commit -m "feat(core): HAWebSocketClient actor with auth handshake and id correlation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: `ReconnectPolicy` (pure backoff) + heartbeat hook

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Networking/ReconnectPolicy.swift`
- Modify: `Packages/HavenCore/Sources/HavenCore/Networking/HAWebSocketClient.swift` (add heartbeat)
- Test: `Packages/HavenCore/Tests/HavenCoreTests/ReconnectPolicyTests.swift`

**Interfaces:**
- Produces: `struct ReconnectPolicy: Sendable { let base: Duration; let max: Duration; func delay(forAttempt n: Int) -> Duration }` — linear `min(n*base, max)`.
- Produces: `HAWebSocketClient.startHeartbeat(interval:)` sending `ping` and treating a matching `pong` as liveness; exposed as an actor method (not unit-tested for timing, wired in Task 9's store).

- [ ] **Step 1: Write failing tests (`ReconnectPolicyTests.swift`)**

```swift
import Testing
@testable import HavenCore

@Test func linearBackoffCaps() {
    let p = ReconnectPolicy(base: .seconds(3), max: .seconds(30))
    #expect(p.delay(forAttempt: 0) == .seconds(0))
    #expect(p.delay(forAttempt: 1) == .seconds(3))
    #expect(p.delay(forAttempt: 5) == .seconds(15))
    #expect(p.delay(forAttempt: 100) == .seconds(30))
}
```

- [ ] **Step 2: Run — verify fails.**

- [ ] **Step 3: Implement `ReconnectPolicy.swift`**

```swift
import Foundation

public struct ReconnectPolicy: Sendable {
    public let base: Duration
    public let max: Duration
    public init(base: Duration = .seconds(3), max: Duration = .seconds(30)) {
        self.base = base; self.max = max
    }
    public func delay(forAttempt n: Int) -> Duration {
        let scaled = base * n
        return scaled < max ? scaled : max
    }
}
```

- [ ] **Step 4: Add heartbeat to `HAWebSocketClient` (append inside the actor)**

```swift
    private var heartbeat: Task<Void, Never>?

    public func startHeartbeat(interval: Duration = .seconds(10)) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                _ = try? await self.request { WSCommand.ping(id: $0) }  // a pong returns as a result-less frame; ignore failures
            }
        }
    }
```

Note: HA replies to `ping` with a `pong` frame carrying the same `id`. Update `handle(_:)`'s `.pong` case to also resolve a pending continuation if present:

```swift
        case .pong(let id):
            if let cont = pending.removeValue(forKey: id) { cont.resume(returning: .null) }
            eventContinuation?.yield(frame)
```

And cancel it in `disconnect()`: add `heartbeat?.cancel(); heartbeat = nil`.

- [ ] **Step 5: Run all tests** (`swift test`) → all pass.

- [ ] **Step 6: Commit**

```bash
git add Packages/HavenCore
git commit -m "feat(core): reconnect backoff policy and websocket heartbeat

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: High-level fetches — registries, states, subscribe, call_service

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Session/HomeConnection.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/HomeConnectionTests.swift`

**Interfaces:**
- Produces: `struct HAConfig: Sendable { let baseURL: URL; var webSocketURL: URL }` (derives `ws(s)://host/api/websocket`).
- Produces: `actor HomeConnection` wrapping `HAWebSocketClient`: `func loadStructure() async throws -> ResolvedHome`, `func loadStates() async throws -> [EntityState]`, `func subscribeStateChanges() async throws -> AsyncStream<EntityState>`, `func toggleLight(entityId:) async throws`.

- [ ] **Step 1: Write failing tests (`HomeConnectionTests.swift`)**

```swift
import Testing
import Foundation
@testable import HavenCore

@Test func webSocketURLDerivation() {
    let cfg = HAConfig(baseURL: URL(string: "https://ha.example:8123")!)
    #expect(cfg.webSocketURL.absoluteString == "wss://ha.example:8123/api/websocket")
    let local = HAConfig(baseURL: URL(string: "http://homeassistant.local:8123")!)
    #expect(local.webSocketURL.absoluteString == "ws://homeassistant.local:8123/api/websocket")
}

@Test func loadStructureParsesRegistries() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["id"] as? Int, let type = obj?["type"] as? String else { return }
        let payloads: [String: String] = [
            "config/floor_registry/list": #"[{"floor_id":"f1","name":"Ground","level":0}]"#,
            "config/area_registry/list": #"[{"area_id":"a1","name":"Kitchen","floor_id":"f1"}]"#,
            "config/device_registry/list": #"[{"id":"d1","area_id":"a1"}]"#,
            "config/entity_registry/list": #"[{"entity_id":"light.k","device_id":"d1"}]"#,
        ]
        if let body = payloads[type] {
            await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":\#(body)}"#)
        }
    }
    let home = HomeConnection(client: client)
    let structure = try await home.loadStructure()
    #expect(structure.floors.first?.areas.first?.entityIds == ["light.k"])
}
```

- [ ] **Step 2: Run — verify fails.**

- [ ] **Step 3: Implement `HomeConnection.swift`**

```swift
import Foundation

public struct HAConfig: Sendable {
    public let baseURL: URL
    public init(baseURL: URL) { self.baseURL = baseURL }
    public var webSocketURL: URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.scheme = (baseURL.scheme == "https") ? "wss" : "ws"
        c.path = "/api/websocket"
        return c.url!
    }
}

public actor HomeConnection {
    private let client: HAWebSocketClient
    public init(client: HAWebSocketClient) { self.client = client }

    private func decodeList<T: Decodable>(_ v: JSONValue, as: T.Type) throws -> [T] {
        let data = try JSONEncoder().encode(v)
        return try HACoding.decoder.decode([T].self, from: data)
    }

    public func loadStructure() async throws -> ResolvedHome {
        async let floorsV = client.request { WSCommand.registryList(id: $0, type: "config/floor_registry/list") }
        async let areasV  = client.request { WSCommand.registryList(id: $0, type: "config/area_registry/list") }
        async let devsV   = client.request { WSCommand.registryList(id: $0, type: "config/device_registry/list") }
        async let entsV   = client.request { WSCommand.registryList(id: $0, type: "config/entity_registry/list") }
        let floors = try await decodeList(floorsV, as: FloorRegistryEntry.self)
        let areas  = try await decodeList(areasV, as: AreaRegistryEntry.self)
        let devices = try await decodeList(devsV, as: DeviceRegistryEntry.self)
        let entities = try await decodeList(entsV, as: EntityRegistryEntry.self)
        return RegistryResolver.resolve(floors: floors, areas: areas, devices: devices, entities: entities)
    }

    public func loadStates() async throws -> [EntityState] {
        let v = try await client.request { WSCommand.getStates(id: $0) }
        return (v.asArray ?? []).compactMap { StateChangedEvent.parseState($0) }
    }

    public func subscribeStateChanges() async throws -> AsyncStream<EntityState> {
        _ = try await client.request { WSCommand.subscribeEvents(id: $0, eventType: "state_changed") }
        let events = await client.events
        return AsyncStream { cont in
            let task = Task {
                for await frame in events {
                    if case let .event(_, payload) = frame,
                       let sc = try? StateChangedEvent(eventPayload: payload),
                       let st = sc.newState {
                        cont.yield(st)
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    public func toggleLight(entityId: String) async throws {
        _ = try await client.request { WSCommand.callService(id: $0, domain: "light", service: "toggle", entityId: entityId) }
    }
}

extension JSONValue { public var asArray: [JSONValue]? { if case .array(let a) = self { return a }; return nil } }
```

Remove the duplicate `asArray` added to `Fakes.swift` in Task 6 (now public here) — delete that extension line from `Fakes.swift` to avoid a redeclaration.

- [ ] **Step 4: Run — verify pass** (`swift test`) → all pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/HavenCore
git commit -m "feat(core): HomeConnection façade for registries, states, subscription, toggle

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: Keychain token store + OAuth client

**Files:**
- Create: `Packages/HavenCore/Sources/HavenCore/Auth/TokenStore.swift`
- Create: `Packages/HavenCore/Sources/HavenCore/Auth/WebAuthSession.swift`
- Create: `Packages/HavenCore/Sources/HavenCore/Auth/OAuthClient.swift`
- Test: `Packages/HavenCore/Tests/HavenCoreTests/OAuthClientTests.swift`

**Interfaces:**
- Produces: `struct HATokens: Codable, Sendable { let accessToken: String; let refreshToken: String?; let expiresAt: Date }`.
- Produces: `protocol TokenStore: Sendable { func save(_:) throws; func load() -> HATokens?; func clear() }` + `KeychainTokenStore`.
- Produces: `protocol WebAuthSession: Sendable { func authenticate(url: URL, callbackScheme: String) async throws -> URL }`.
- Produces: `protocol HTTPPoster: Sendable { func post(_ url: URL, form: [String:String]) async throws -> Data }` + `URLSessionHTTP`.
- Produces: `struct OAuthClient` with `authorizeURL(baseURL:) -> URL`, `func login(baseURL:web:http:) async throws -> HATokens`, `func refresh(baseURL:refreshToken:http:) async throws -> HATokens`.
- Constants: `OAuthClient.clientId = "https://timmead.github.io/HavenApp/oauth/"`, `.redirectURI = "havenapp://oauth/callback"`.

- [ ] **Step 1: Write failing tests (`OAuthClientTests.swift`)**

```swift
import Testing
import Foundation
@testable import HavenCore

@Test func authorizeURLContainsClientAndRedirect() {
    let url = OAuthClient().authorizeURL(baseURL: URL(string: "http://ha.local:8123")!, state: "s1")
    let s = url.absoluteString
    #expect(s.hasPrefix("http://ha.local:8123/auth/authorize?"))
    #expect(s.contains("client_id=https%3A%2F%2Ftimmead.github.io%2FHavenApp%2Foauth%2F"))
    #expect(s.contains("redirect_uri=havenapp%3A%2F%2Foauth%2Fcallback"))
    #expect(s.contains("state=s1"))
}

@Test func loginExchangesCodeForTokens() async throws {
    let web = FakeWebAuth(returnURL: URL(string: "havenapp://oauth/callback?code=AUTHCODE&state=s1")!)
    let http = FakeHTTP(response: #"{"access_token":"AT","refresh_token":"RT","expires_in":1800}"#)
    let tokens = try await OAuthClient().login(baseURL: URL(string: "http://ha.local:8123")!,
                                               state: "s1", web: web, http: http)
    #expect(tokens.accessToken == "AT")
    #expect(tokens.refreshToken == "RT")
    #expect(http.lastForm?["code"] == "AUTHCODE")
    #expect(http.lastForm?["grant_type"] == "authorization_code")
}

@Test func mismatchedStateThrows() async throws {
    let web = FakeWebAuth(returnURL: URL(string: "havenapp://oauth/callback?code=X&state=WRONG")!)
    let http = FakeHTTP(response: "{}")
    await #expect(throws: (any Error).self) {
        _ = try await OAuthClient().login(baseURL: URL(string: "http://ha.local:8123")!,
                                          state: "s1", web: web, http: http)
    }
}
```

Add fakes to `Fakes.swift`:

```swift
struct FakeWebAuth: WebAuthSession {
    let returnURL: URL
    func authenticate(url: URL, callbackScheme: String) async throws -> URL { returnURL }
}
final class FakeHTTP: HTTPPoster, @unchecked Sendable {
    let response: String
    private(set) var lastForm: [String: String]?
    init(response: String) { self.response = response }
    func post(_ url: URL, form: [String: String]) async throws -> Data {
        lastForm = form; return Data(response.utf8)
    }
}
```

- [ ] **Step 2: Run — verify fails.**

- [ ] **Step 3: Implement `TokenStore.swift`**

```swift
import Foundation
import Security

public struct HATokens: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
    }
}

public protocol TokenStore: Sendable {
    func save(_ tokens: HATokens) throws
    func load() -> HATokens?
    func clear()
}

public struct KeychainTokenStore: TokenStore {
    private let account = "primary-home"
    private let service = "app.haven.tokens"
    public init() {}
    public func save(_ tokens: HATokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw WSError(code: "keychain", message: "save \(status)") }
    }
    public func load() -> HATokens? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(HATokens.self, from: data)
    }
    public func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}
```

- [ ] **Step 4: Implement `WebAuthSession.swift`**

```swift
import Foundation

public protocol WebAuthSession: Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

public protocol HTTPPoster: Sendable {
    func post(_ url: URL, form: [String: String]) async throws -> Data
}

public struct URLSessionHTTP: HTTPPoster {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func post(_ url: URL, form: [String: String]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed)!)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WSError(code: "http", message: "token endpoint failed")
        }
        return data
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var cs = CharacterSet.urlQueryAllowed; cs.remove(charactersIn: "&=+"); return cs
    }()
}
```

- [ ] **Step 5: Implement `OAuthClient.swift`**

```swift
import Foundation

public struct OAuthClient: Sendable {
    public static let clientId = "https://timmead.github.io/HavenApp/oauth/"
    public static let redirectURI = "havenapp://oauth/callback"
    public static let callbackScheme = "havenapp"
    public init() {}

    public func authorizeURL(baseURL: URL, state: String) -> URL {
        var c = URLComponents(url: baseURL.appendingPathComponent("auth/authorize"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: Self.clientId),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "state", value: state),
            .init(name: "response_type", value: "code"),
        ]
        // Ensure client_id/redirect encode as %2F etc.
        c.percentEncodedQuery = c.queryItems!.map {
            "\($0.name)=\($0.value!.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed)!)"
        }.joined(separator: "&")
        return c.url!
    }

    public func login(baseURL: URL, state: String = UUID().uuidString,
                      web: WebAuthSession, http: HTTPPoster) async throws -> HATokens {
        let callback = try await web.authenticate(url: authorizeURL(baseURL: baseURL, state: state),
                                                   callbackScheme: Self.callbackScheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw WSError(code: "oauth", message: "state mismatch")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw WSError(code: "oauth", message: "no code")
        }
        let data = try await http.post(baseURL.appendingPathComponent("auth/token"), form: [
            "grant_type": "authorization_code", "code": code, "client_id": Self.clientId,
        ])
        return try Self.parseTokens(data)
    }

    public func refresh(baseURL: URL, refreshToken: String, http: HTTPPoster) async throws -> HATokens {
        let data = try await http.post(baseURL.appendingPathComponent("auth/token"), form: [
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": Self.clientId,
        ])
        return try Self.parseTokens(data, fallbackRefresh: refreshToken)
    }

    static func parseTokens(_ data: Data, fallbackRefresh: String? = nil) throws -> HATokens {
        struct R: Decodable { let accessToken: String; let refreshToken: String?; let expiresIn: Double }
        let r = try HACoding.decoder.decode(R.self, from: data)
        return HATokens(accessToken: r.accessToken, refreshToken: r.refreshToken ?? fallbackRefresh,
                        expiresAt: Date().addingTimeInterval(r.expiresIn))
    }
}
```

- [ ] **Step 6: Run — verify pass** (`swift test`) → all pass.

- [ ] **Step 7: Commit**

```bash
git add Packages/HavenCore
git commit -m "feat(core): Keychain token store and HA OAuth client

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 10: Hosted `client_id` page (GitHub Pages)

**Files:**
- Create: `docs/oauth/index.html`

**Interfaces:** none (static asset). HA fetches `https://timmead.github.io/HavenApp/oauth/` and must find a `<link rel="redirect_uri">` whitelisting the app scheme. (Requires enabling GitHub Pages: Settings → Pages → deploy from `main`/`docs`.)

- [ ] **Step 1: Write `docs/oauth/index.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Haven</title>
  <link rel="redirect_uri" href="havenapp://oauth/callback">
</head>
<body>
  <h1>Haven</h1>
  <p>Haven is a native iOS client for Home Assistant. This page identifies the app to your Home Assistant server during sign-in.</p>
  <a href="havenapp://oauth/callback">Return to Haven</a>
</body>
</html>
```

- [ ] **Step 2: Verify locally**

Run: `python3 -c "import pathlib,re;h=pathlib.open if False else open; s=open('docs/oauth/index.html').read(); assert 'rel=\"redirect_uri\"' in s and 'havenapp://oauth/callback' in s; print('client_id page OK')"`
Expected: `client_id page OK`.

- [ ] **Step 3: Commit**

```bash
git add docs/oauth/index.html
git commit -m "chore: hosted OAuth client_id page for HA IndieAuth

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

> After merge, enable GitHub Pages (root `/docs`) so `https://timmead.github.io/HavenApp/oauth/` serves this file. This is a one-time repo setting, not a code step.

---

### Task 11: App layer — models, auth glue, dashboard, live light tile

**Files:**
- Create: `App/AppModel.swift`, `App/HomeStore.swift`, `App/WebAuthPresenter.swift`
- Create: `App/Views/RootView.swift`, `App/Views/LoginView.swift`, `App/Views/DashboardView.swift`, `App/Views/RoomSectionView.swift`, `App/Views/LightTileView.swift`
- Modify: `App/HavenAppApp.swift`

**Interfaces:**
- Consumes: everything public from `HavenCore`.
- Produces: `@MainActor @Observable final class AppModel` (auth state machine + reconnect loop) and `@MainActor @Observable final class HomeStore` (structure + `[String: EntityState]` + optimistic toggle).

- [ ] **Step 1: Implement `App/WebAuthPresenter.swift`** (concrete `WebAuthSession` using ASWebAuthenticationSession)

```swift
import AuthenticationServices
import HavenCore

@MainActor
final class WebAuthPresenter: NSObject, WebAuthSession, ASWebAuthenticationPresentationContextProviding {
    nonisolated func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            Task { @MainActor in
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { cb, err in
                    if let cb { cont.resume(returning: cb) }
                    else { cont.resume(throwing: err ?? WSError(code: "oauth", message: "cancelled")) }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                session.start()
            }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}
```

- [ ] **Step 2: Implement `App/HomeStore.swift`**

```swift
import SwiftUI
import HavenCore

@MainActor @Observable
final class HomeStore {
    var home = ResolvedHome(floors: [])
    var states: [String: EntityState] = [:]
    private var connection: HomeConnection?

    func attach(_ connection: HomeConnection) { self.connection = connection }

    func bootstrap() async throws {
        guard let connection else { return }
        home = try await connection.loadStructure()
        for s in try await connection.loadStates() { states[s.entityId] = s }
        let stream = try await connection.subscribeStateChanges()
        Task { for await s in stream { self.states[s.entityId] = s } }
    }

    func isOn(_ entityId: String) -> Bool { states[entityId]?.state == "on" }

    func toggleLightOptimistic(_ entityId: String) {
        guard let connection, var s = states[entityId] else { return }
        let previous = s
        s.state = (s.state == "on") ? "off" : "on"      // optimistic flip
        states[entityId] = s
        Task {
            do { try await connection.toggleLight(entityId: entityId) }
            catch { self.states[entityId] = previous }    // rollback
        }
    }
}
```

- [ ] **Step 3: Implement `App/AppModel.swift`**

```swift
import SwiftUI
import HavenCore

@MainActor @Observable
final class AppModel {
    enum Phase { case loggedOut, connecting, ready, error(String) }
    var phase: Phase = .loggedOut
    var serverURLText = ""
    let store = HomeStore()

    private let tokens: TokenStore = KeychainTokenStore()
    private let oauth = OAuthClient()
    private let http = URLSessionHTTP()
    private let web = WebAuthPresenter()
    private let policy = ReconnectPolicy()
    private var baseURL: URL?

    func restoreIfPossible() async {
        guard let saved = tokens.load(), let url = savedBaseURL() else { return }
        baseURL = url
        await connect(token: saved.accessToken)
    }

    func signIn() async {
        guard let url = URL(string: serverURLText), url.scheme != nil else {
            phase = .error("Enter a valid URL like http://homeassistant.local:8123"); return
        }
        baseURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: "baseURL")
        phase = .connecting
        do {
            let t = try await oauth.login(baseURL: url, web: web, http: http)
            try tokens.save(t)
            await connect(token: t.accessToken)
        } catch { phase = .error("Sign-in failed: \(error)") }
    }

    private func connect(token: String) async {
        guard let base = baseURL else { return }
        phase = .connecting
        var attempt = 0
        while true {
            do {
                let conn = URLSessionWebSocketConnection(url: HAConfig(baseURL: base).webSocketURL)
                let client = HAWebSocketClient(connection: conn)
                try await client.authenticate(token: token)
                await client.startHeartbeat()
                let home = HomeConnection(client: client)
                store.attach(home)
                try await store.bootstrap()
                phase = .ready
                return
            } catch {
                attempt += 1
                phase = .error("Connection lost — retrying…")
                try? await Task.sleep(for: policy.delay(forAttempt: attempt))
            }
        }
    }

    private func savedBaseURL() -> URL? {
        UserDefaults.standard.string(forKey: "baseURL").flatMap(URL.init(string:))
    }
}
```

- [ ] **Step 4: Implement the views**

`App/Views/LightTileView.swift`:

```swift
import SwiftUI
import HavenCore

struct LightTileView: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let on = store.isOn(entityId)
        Button { store.toggleLightOptimistic(entityId) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: on ? "lightbulb.fill" : "lightbulb")
                    .font(.title2).symbolRenderingMode(.hierarchical)
                Text(entityId.replacingOccurrences(of: "light.", with: "").replacingOccurrences(of: "_", with: " "))
                    .font(.caption).lineLimit(1)
                Text(on ? "On" : "Off").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .buttonStyle(.plain)
        .background(on ? Color.yellow.opacity(0.25) : Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
```

`App/Views/RoomSectionView.swift`:

```swift
import SwiftUI
import HavenCore

struct RoomSectionView: View {
    let area: ResolvedArea
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(area.name).font(.headline)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(area.entityIds.filter { $0.hasPrefix("light.") }, id: \.self) { id in
                    LightTileView(entityId: id).gridCellColumns(1)
                }
            }
        }
    }
}
```

`App/Views/DashboardView.swift`:

```swift
import SwiftUI
import HavenCore

struct DashboardView: View {
    @Environment(HomeStore.self) private var store
    var body: some View {
        TabView {
            ForEach(store.home.floors) { floor in
                Tab(floor.name, systemImage: "square.stack.3d.up") {
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                ForEach(floor.areas) { area in RoomSectionView(area: area) }
                            }.padding()
                        }.navigationTitle(floor.name)
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
```

`App/Views/LoginView.swift`:

```swift
import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 16) {
            Text("Connect to Home Assistant").font(.title2.bold())
            TextField("http://homeassistant.local:8123", text: $model.serverURLText)
                .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never)
                .autocorrectionDisabled().keyboardType(.URL)
            Button("Sign in") { Task { await model.signIn() } }
                .buttonStyle(.borderedProminent)
            if case let .error(msg) = model.phase { Text(msg).font(.footnote).foregroundStyle(.red) }
        }.padding()
    }
}
```

`App/Views/RootView.swift`:

```swift
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        switch model.phase {
        case .loggedOut, .error: LoginView()
        case .connecting: ProgressView("Connecting…")
        case .ready: DashboardView().environment(model.store)
        }
    }
}
```

- [ ] **Step 5: Rewrite `App/HavenAppApp.swift`**

```swift
import SwiftUI

@main
struct HavenAppApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.restoreIfPossible() }
        }
    }
}
```

- [ ] **Step 6: Generate + build the app**

Run: `xcodegen generate`
Run: `xcodebuild -project HavenApp.xcodeproj -scheme HavenApp -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Manual smoke test (documented, requires a real HA + Pages live)**

1. Enable GitHub Pages so `https://timmead.github.io/HavenApp/oauth/` is live (Task 10 note).
2. Run the app in the simulator, enter your HA URL, tap **Sign in**, complete HA login in the sheet.
3. Verify: floor tabs appear; a room shows light tiles; toggling a light in HA updates the tile within ~1s; tapping a tile toggles the light in HA and reflects immediately (optimistic), reverting only if the call fails.

- [ ] **Step 8: Commit**

```bash
git add App project.yml
git commit -m "feat(app): OAuth login, live dashboard, optimistic light tile

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage (slice scope):**
- OAuth via ASWebAuthenticationSession → Tasks 9, 11 (+ hosted page Task 10). ✓
- WebSocket actor + auth_required→auth→auth_ok → Task 6. ✓
- Reconnect + heartbeat → Task 7 (+ reconnect loop in AppModel Task 11). ✓
- Registry query + entity→area→floor resolution → Tasks 3, 8. ✓
- Live state subscription → Task 8 (`subscribeStateChanges`), applied in HomeStore Task 11. ✓
- Floors-as-tabs / rooms-as-sections + Light tile live + optimistic toggle → Task 11. ✓
- Tokens in Keychain → Task 9. ✓
- Deferred items (renderer catalog, Attention, config mode, migration, haven-hacs) correctly excluded. ✓

**2. Placeholder scan:** No "TBD/TODO"; every code step shows complete code; commands have expected output. ✓

**3. Type consistency:** `HAWebSocketClient.request`, `HomeConnection` method names, `HomeStore.toggleLightOptimistic`, `OAuthClient.login(baseURL:state:web:http:)`, `WebAuthSession.authenticate(url:callbackScheme:)`, `HATokens` fields, and `ResolvedHome/Floor/Area` are referenced consistently across tasks. `asArray` defined once (public, Task 8; duplicate removed from Fakes). `events` is `let` on the actor and consumed via `await client.events`. ✓

**Known real-world checks to confirm during execution (not plan defects):**
- `Tab`/`.sidebarAdaptable`/`Slider` API spellings against the live iOS 26 SDK (research noted a couple of signatures to confirm in Xcode).
- HA `ping`→`pong` id echo behavior; if a given HA version doesn't echo id, the heartbeat still self-heals via the receive loop.
- ASWebAuthenticationSession requires the client_id page to be reachable over HTTPS before device testing.
