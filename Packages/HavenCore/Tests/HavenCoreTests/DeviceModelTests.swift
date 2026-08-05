import Foundation
import Testing
@testable import HavenCore

// MARK: - The registry

/// A light has one way to be rendered, so the `+` flow has no question to ask. A cover has three —
/// a plain shade, a garage door, a shade group — which is the whole reason the step exists.
@Test func onlySomeEntitiesHaveAChoiceOfType() {
    #expect(DeviceTypes.candidates(for: "light.kitchen").map(\.id) == ["light"])
    let cover = DeviceTypes.candidates(for: "cover.garage").map(\.id)
    #expect(cover.first == "cover")
    #expect(Set(cover) == ["cover", "garage_door", "shade_group"])
}

/// **The default comes first**, so a chooser can present it as the obvious answer and a caller that
/// ignores the rest still gets exactly today's behaviour.
@Test func theDefaultTypeIsTheOneEntityOneForItsDomain() {
    #expect(DeviceTypes.default(for: "lock.front").id == "lock")
    #expect(DeviceTypes.default(for: "binary_sensor.x").id == "binary_sensor")
}

/// A role only accepts what could fill it: a garage door's limits are binary sensors, and offering
/// a media player for one would be a picker full of things that cannot work.
@Test func aRoleOnlyAcceptsEntitiesThatCouldFillIt() {
    let garage = DeviceTypes.type(id: "garage_door")!
    let limit = garage.roles.first { $0.role == .openLimit }!
    #expect(limit.accepts("binary_sensor.a"))
    #expect(!limit.accepts("media_player.a"))
    #expect(!limit.isRequired)
    #expect(garage.primaryRole?.isRequired == true)
}

/// A shade group's followers are many; everything else is one.
@Test func onlyFollowersAreMany() {
    let group = DeviceTypes.type(id: "shade_group")!
    #expect(group.roles.first { $0.role == .follower }?.cardinality == .many)
    #expect(group.primaryRole?.cardinality == .one)
}

// MARK: - The ref

/// A simple device's id is its entity id — the decision that means no stored name, size, membership
/// or order has to move.
@Test func aSimpleDevicesIdIsItsEntityId() {
    #expect(DeviceRef.entity("light.kitchen").id == "light.kitchen")
    #expect(DeviceRef.entity("light.kitchen").primaryEntityId == "light.kitchen")
}

/// A composite's state is read from its primary — a shade group's master.
@Test func aCompositeReadsItsStateFromItsPrimary() {
    let ref = DeviceRef.composite(id: "cover.a", type: "shade_group",
                                  inputs: [.primary: ["cover.a"], .follower: ["cover.b", "cover.c"]])
    #expect(ref.primaryEntityId == "cover.a")
    #expect(Set(ref.entityIds) == ["cover.a", "cover.b", "cover.c"])
    // Its id is the master's, so adding or removing a *follower* never moves it — the group keeps
    // its name, size and place in the room.
    #expect(ref.id == "cover.a")
}

// MARK: - Storage

private func doc(_ device: DashboardDocument.StoredDevice) -> DashboardDocument {
    DashboardDocument().settingDevice(device, id: device.id)
}

@Test func aCompositeRoundTripsThroughTheDocument() {
    let stored = DashboardDocument.StoredDevice(
        id: "cover.a", type: "shade_group", areaId: "living",
        inputs: [.primary: ["cover.a"], .follower: ["cover.b"]])
    let back = doc(stored).devices["cover.a"]
    #expect(back?.type == "shade_group")
    #expect(back?.areaId == "living")
    #expect(back?.inputs[.primary] == ["cover.a"])
    #expect(back?.inputs[.follower] == ["cover.b"])
}

/// **A record with no primary is dropped rather than half-built.** A device with nothing to read its
/// state from would render a tile that cannot say anything.
@Test func aDeviceWithNoPrimaryIsNotADevice() {
    let raw = DashboardDocument(raw: .object([
        "schema": .int(DashboardDocument.schema),
        "devices": .object(["haven:1": .object([
            "type": .string("shade_group"), "area": .string("living"),
            "inputs": .object(["follower": .array([.string("cover.b")])])])])]))
    #expect(raw.devices.isEmpty)
}

@Test func removingACompositeLeavesNoResidue() {
    let stored = DashboardDocument.StoredDevice(id: "cover.a", type: "shade_group", areaId: "living",
                                                inputs: [.primary: ["cover.a"]])
    let after = doc(stored).settingDevice(nil, id: "cover.a")
    #expect(after.devices.isEmpty)
    #expect(after.raw.asObject?["devices"] == nil)
}

// MARK: - A room made of devices

private func home(_ entityIds: [String]) -> ResolvedHome {
    ResolvedHome(floors: [ResolvedFloor(id: "f", name: "F", level: 0, areas: [
        ResolvedArea(id: "living", name: "Living", entityIds: entityIds,
                     tiers: Dictionary(uniqueKeysWithValues: entityIds.map { ($0, .primary) })),
        ResolvedArea(id: "hall", name: "Hall", entityIds: ["cover.hall"],
                     tiers: ["cover.hall": .primary]),
    ])])
}

/// **A shade group and its members are one tile, not four.**
@Test func aCompositeConsumesItsMembersTiles() {
    let group = DashboardDocument.StoredDevice(
        id: "cover.a", type: "shade_group", areaId: "living",
        inputs: [.primary: ["cover.a"], .follower: ["cover.b", "cover.c"]])
    let rooms = SectionBuilder.rooms(from: home(["cover.a", "cover.b", "cover.c", "light.x"]),
                                     environment: [:], devices: ["cover.a": group],
                                     overrides: [:], orders: [:])
    let living = rooms.first { $0.areaId == "living" }!
    let ids = living.refs(for: .overview).map(\.id)
    // The group *is* cover.a — one id space, so its followers vanish and it keeps the master's id.
    #expect(ids.contains("cover.a"))
    #expect(!ids.contains("cover.b"))
    #expect(!ids.contains("cover.c"))
    #expect(ids.contains("light.x"))
    #expect(ids.count == 2)
}

/// Scoped to the room the composite is in. A shade moved to another area in Home Assistant still
/// gets a tile there — HA's configuration outranking Haven's grouping, as everywhere else.
@Test func aMemberInAnotherRoomStillGetsItsOwnTile() {
    let group = DashboardDocument.StoredDevice(
        id: "cover.a", type: "shade_group", areaId: "living",
        inputs: [.primary: ["cover.a"], .follower: ["cover.hall"]])
    let rooms = SectionBuilder.rooms(from: home(["cover.a"]), environment: [:],
                                     devices: ["cover.a": group], overrides: [:], orders: [:])
    let hall = rooms.first { $0.areaId == "hall" }!
    #expect(hall.refs(for: .overview).map(\.id) == ["cover.hall"])
}

/// A composite is ordered like anything else — it has an id, so it drags.
@Test func aCompositeTakesItsPlaceInTheRoomsOrder() {
    let group = DashboardDocument.StoredDevice(id: "cover.a", type: "shade_group", areaId: "living",
                                               inputs: [.primary: ["cover.a"]])
    let rooms = SectionBuilder.rooms(from: home(["cover.a", "light.x"]), environment: [:],
                                     devices: ["cover.a": group], overrides: [:],
                                     orders: ["living": ["light.x", "cover.a"]])
    let living = rooms.first { $0.areaId == "living" }!
    #expect(living.refs(for: .overview).map(\.id) == ["light.x", "cover.a"])
}

/// A composite has no curation tier — curation ranks Home Assistant's entities and a composite is
/// Haven's — so it shows unless the household removed it.
@Test func aCompositeIsShownUnlessItWasRemoved() {
    let group = DashboardDocument.StoredDevice(id: "cover.a", type: "shade_group", areaId: "living",
                                               inputs: [.primary: ["cover.a"]])
    let rooms = SectionBuilder.rooms(from: home(["cover.a"]), environment: [:],
                                     devices: ["cover.a": group],
                                     overrides: ["cover.a": [.overview: .hidden]], orders: [:])
    let living = rooms.first { $0.areaId == "living" }!
    // **Removing it works**, which it did not when the device and the tile disagreed about its id.
    #expect(living.refs(for: .overview).isEmpty)
    #expect(living.refs(for: .roomDetail).map(\.id) == ["cover.a"])
}

// MARK: - One id space

/// **A composite's id is its primary's entity id.** The room renders a ref by its primary, so a
/// device stored under any other key is looked up and never found — which is exactly what happened:
/// a garage door came back as a switch on the next launch, and removing it wrote membership against
/// an id the device was not stored under.
@Test func aDeviceStoredUnderAGeneratedIdIsStillFoundByItsPrimary() {
    let raw = DashboardDocument(raw: .object([
        "schema": .int(DashboardDocument.schema),
        "devices": .object(["haven:garage_door:abc123": .object([
            "type": .string("garage_door"), "area": .string("garage"),
            "inputs": .object(["primary": .array([.string("switch.opener")])])])])]))
    #expect(raw.devices["switch.opener"]?.type == "garage_door")
    #expect(raw.devices["switch.opener"]?.id == "switch.opener")
    #expect(raw.devices["haven:garage_door:abc123"] == nil)
}

/// **Two records claiming one primary: the correctly keyed one wins, whatever the sort order.**
///
/// This is what made a bound sensor appear not to persist. A household that created a device before
/// ids were fixed has a `haven:…` straggler beside the real record; the tiebreak compared the id
/// just constructed — always the primary — so it was true for whichever sorted first, and
/// `haven:…` sorts before `switch.…`. The ghost won every read and the freshly written binding was
/// thrown away.
@Test func aCorrectlyKeyedDeviceBeatsAStragglerThatSortsFirst() {
    let raw = DashboardDocument(raw: .object([
        "schema": .int(DashboardDocument.schema),
        "devices": .object([
            // Sorts first, and is the ghost.
            "haven:garage_door:abc": .object([
                "type": .string("garage_door"), "area": .string("garage"),
                "inputs": .object(["primary": .array([.string("switch.opener")])])]),
            // Sorts second, and is the one with the household's binding on it.
            "switch.opener": .object([
                "type": .string("garage_door"), "area": .string("garage"),
                "inputs": .object(["primary": .array([.string("switch.opener")]),
                                   "closed_limit": .array([.string("binary_sensor.g_closed")])])]),
        ])]))
    #expect(raw.devices["switch.opener"]?.inputs[.closedLimit] == ["binary_sensor.g_closed"])
    #expect(raw.devices.count == 1)
}

@Test func aCorrectlyKeyedDeviceBeatsAStraggler() {
    let raw = DashboardDocument(raw: .object([
        "schema": .int(DashboardDocument.schema),
        "devices": .object([
            "haven:old:1": .object([
                "type": .string("shade_group"), "area": .string("a"),
                "inputs": .object(["primary": .array([.string("cover.x")])])]),
            "cover.x": .object([
                "type": .string("garage_door"), "area": .string("b"),
                "inputs": .object(["primary": .array([.string("cover.x")])])]),
        ])]))
    #expect(raw.devices["cover.x"]?.type == "garage_door")
    #expect(raw.devices.count == 1)
}

/// The exact sequence the configuration sheet performs on Done, as a document mutation — so a
/// binding that fails to persist is pinned to either this logic or the write around it.
@Test func theSheetsCommitSequenceKeepsABinding() {
    let device = DashboardDocument.StoredDevice(
        id: "switch.opener", type: "garage_door", areaId: "garage",
        inputs: [.primary: ["switch.opener"]])
    var next = DashboardDocument().settingDevice(device, id: "switch.opener")
    // Done writes the name first — nil here, because nothing was typed.
    next = next.settingDisplayName(nil, for: "switch.opener")
    // Then the roles, read back out of the document and put in again.
    var stored = next.devices["switch.opener"]
    #expect(stored != nil, "the device vanished before its roles were written")
    var inputs = stored?.inputs ?? [:]
    inputs[.closedLimit] = ["binary_sensor.g_closed"]
    stored = DashboardDocument.StoredDevice(id: "switch.opener", type: "garage_door",
                                            areaId: "garage", inputs: inputs)
    next = next.settingDevice(stored, id: "switch.opener")

    #expect(next.devices["switch.opener"]?.inputs[.closedLimit] == ["binary_sensor.g_closed"])
    #expect(next.devices["switch.opener"]?.inputs[.primary] == ["switch.opener"])
}
