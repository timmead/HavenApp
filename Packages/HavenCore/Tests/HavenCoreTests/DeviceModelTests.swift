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
    let ref = DeviceRef.composite(id: "haven:1", type: "shade_group",
                                  inputs: [.primary: ["cover.a"], .follower: ["cover.b", "cover.c"]])
    #expect(ref.primaryEntityId == "cover.a")
    #expect(Set(ref.entityIds) == ["cover.a", "cover.b", "cover.c"])
    // And its id is its own, not derived from those inputs — adding a follower must not orphan the
    // group's name and size.
    #expect(ref.id == "haven:1")
}

// MARK: - Storage

private func doc(_ device: DashboardDocument.StoredDevice) -> DashboardDocument {
    DashboardDocument().settingDevice(device, id: device.id)
}

@Test func aCompositeRoundTripsThroughTheDocument() {
    let stored = DashboardDocument.StoredDevice(
        id: "haven:1", type: "shade_group", areaId: "living",
        inputs: [.primary: ["cover.a"], .follower: ["cover.b"]])
    let back = doc(stored).devices["haven:1"]
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
    let stored = DashboardDocument.StoredDevice(id: "haven:1", type: "shade_group", areaId: "living",
                                                inputs: [.primary: ["cover.a"]])
    let after = doc(stored).settingDevice(nil, id: "haven:1")
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
        id: "haven:1", type: "shade_group", areaId: "living",
        inputs: [.primary: ["cover.a"], .follower: ["cover.b", "cover.c"]])
    let rooms = SectionBuilder.rooms(from: home(["cover.a", "cover.b", "cover.c", "light.x"]),
                                     environment: [:], devices: ["haven:1": group],
                                     overrides: [:], orders: [:])
    let living = rooms.first { $0.areaId == "living" }!
    let ids = living.refs(for: .overview).map(\.id)
    #expect(ids.contains("haven:1"))
    #expect(!ids.contains("cover.a"))
    #expect(!ids.contains("cover.b"))
    #expect(ids.contains("light.x"))
}

/// Scoped to the room the composite is in. A shade moved to another area in Home Assistant still
/// gets a tile there — HA's configuration outranking Haven's grouping, as everywhere else.
@Test func aMemberInAnotherRoomStillGetsItsOwnTile() {
    let group = DashboardDocument.StoredDevice(
        id: "haven:1", type: "shade_group", areaId: "living",
        inputs: [.primary: ["cover.a"], .follower: ["cover.hall"]])
    let rooms = SectionBuilder.rooms(from: home(["cover.a"]), environment: [:],
                                     devices: ["haven:1": group], overrides: [:], orders: [:])
    let hall = rooms.first { $0.areaId == "hall" }!
    #expect(hall.refs(for: .overview).map(\.id) == ["cover.hall"])
}

/// A composite is ordered like anything else — it has an id, so it drags.
@Test func aCompositeTakesItsPlaceInTheRoomsOrder() {
    let group = DashboardDocument.StoredDevice(id: "haven:1", type: "shade_group", areaId: "living",
                                               inputs: [.primary: ["cover.a"]])
    let rooms = SectionBuilder.rooms(from: home(["cover.a", "light.x"]), environment: [:],
                                     devices: ["haven:1": group], overrides: [:],
                                     orders: ["living": ["light.x", "haven:1"]])
    let living = rooms.first { $0.areaId == "living" }!
    #expect(living.refs(for: .overview).map(\.id) == ["light.x", "haven:1"])
}

/// A composite has no curation tier — curation ranks Home Assistant's entities and a composite is
/// Haven's — so it shows unless the household removed it.
@Test func aCompositeIsShownUnlessItWasRemoved() {
    let group = DashboardDocument.StoredDevice(id: "haven:1", type: "shade_group", areaId: "living",
                                               inputs: [.primary: ["cover.a"]])
    let rooms = SectionBuilder.rooms(from: home(["cover.a"]), environment: [:],
                                     devices: ["haven:1": group],
                                     overrides: ["haven:1": [.overview: .hidden]], orders: [:])
    let living = rooms.first { $0.areaId == "living" }!
    #expect(living.refs(for: .overview).isEmpty)
    #expect(living.refs(for: .roomDetail).map(\.id) == ["haven:1"])
}
