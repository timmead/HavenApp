import Foundation
import Testing
@testable import HavenCore

// Resolving "what is this device" from what the household stored plus what Home Assistant said.
//
// These five answers used to live on `App/HomeStore`, where nothing could test them directly: every
// one is a pure function of a `DashboardDocument` and a `ResolvedHome`, so they belong here beside
// the types they read. The app-layer tests that covered them went through a live store and a fake
// connection to reach a dictionary lookup.

// MARK: - What the document says a device is

/// **The fallback is the whole model.** A light's device is implied by the light existing, so an id
/// nobody has configured still resolves — which is why no stored record had to move when devices
/// arrived, and why every caller can ask without first checking whether one exists.
@Test func anIdWithNoStoredRecordIsItsOwnDevice() {
    let document = DashboardDocument()
    #expect(document.deviceRef(for: "light.kitchen") == .entity("light.kitchen"))
    #expect(document.deviceType(for: "light.kitchen").id == "light")
    #expect(document.roleBindings(for: "light.kitchen").isEmpty)
}

@Test func aStoredRecordResolvesToItsCompositeTypeAndInputs() {
    let stored = DashboardDocument.StoredDevice(
        id: "cover.garage", type: "garage_door", areaId: "hall",
        inputs: [.primary: ["cover.garage"], .openLimit: ["binary_sensor.open"]])
    let document = DashboardDocument().settingDevice(stored, id: "cover.garage")

    #expect(document.deviceRef(for: "cover.garage") == .composite(
        id: "cover.garage", type: "garage_door",
        inputs: [.primary: ["cover.garage"], .openLimit: ["binary_sensor.open"]]))
    #expect(document.deviceType(for: "cover.garage").id == "garage_door")
}

/// A type string this build does not recognise must not strand the tile with no way to render.
/// Falling back to the one-entity type for its domain means a document written by a newer build
/// still shows something — the same "never write what you don't understand, but always render what
/// you can" stance `DashboardDocument.isWritable` takes.
@Test func anUnrecognisedStoredTypeFallsBackToTheDomainDefault() {
    let stored = DashboardDocument.StoredDevice(
        id: "cover.garage", type: "teleporter", areaId: "hall",
        inputs: [.primary: ["cover.garage"]])
    let document = DashboardDocument().settingDevice(stored, id: "cover.garage")

    #expect(document.deviceType(for: "cover.garage").id == "cover")
}

/// **One entity per role**, taken from the front of each stored list. The storage holds arrays
/// because a shade group's followers are many; every role a picker binds is single-valued, and this
/// is the read those pickers make.
@Test func roleBindingsTakeTheFirstEntityBoundToEachRole() {
    let stored = DashboardDocument.StoredDevice(
        id: "cover.garage", type: "garage_door", areaId: "hall",
        inputs: [.primary: ["cover.garage"],
                 .openLimit: ["binary_sensor.open", "binary_sensor.spare"]])
    let document = DashboardDocument().settingDevice(stored, id: "cover.garage")

    let bindings = document.roleBindings(for: "cover.garage")
    #expect(bindings[.primary] == "cover.garage")
    #expect(bindings[.openLimit] == "binary_sensor.open")
}

/// A role stored with an empty list is a role nobody bound. It must read as absent rather than as
/// present-but-blank, or a picker would show a binding to nothing.
@Test func aRoleStoredWithNoEntitiesReadsAsUnbound() {
    let stored = DashboardDocument.StoredDevice(
        id: "cover.garage", type: "garage_door", areaId: "hall",
        inputs: [.primary: ["cover.garage"], .closedLimit: []])
    let document = DashboardDocument().settingDevice(stored, id: "cover.garage")

    #expect(document.roleBindings(for: "cover.garage")[.closedLimit] == nil)
}

// MARK: - What the home says lives near an entity

private func home() -> ResolvedHome {
    ResolvedHome(
        floors: [ResolvedFloor(id: "ground", name: "Ground", level: 0, areas: [
            ResolvedArea(id: "hall", name: "Hall",
                         entityIds: ["cover.garage", "binary_sensor.open", "light.hall"]),
            ResolvedArea(id: "kitchen", name: "Kitchen", entityIds: ["light.kitchen"]),
        ])],
        registryInfo: [
            "cover.garage": EntityRegistryInfo(platform: "mqtt", uniqueId: "a", deviceId: "dev1"),
            "binary_sensor.open": EntityRegistryInfo(platform: "mqtt", uniqueId: "b", deviceId: "dev1"),
            "light.hall": EntityRegistryInfo(platform: "hue", uniqueId: "c", deviceId: "dev2"),
            // **Two** device-less entities, deliberately. With only one, dropping the
            // `!deviceId.isEmpty` guard still returns nothing — there is no second empty-id entity
            // to match — and the test below passes while proving nothing. Verified by mutation:
            // with both present, removing that guard turns it red.
            "light.kitchen": EntityRegistryInfo(platform: "hue", uniqueId: "d", deviceId: ""),
            "switch.pump": EntityRegistryInfo(platform: "mqtt", uniqueId: "e", deviceId: ""),
        ])
}

/// The pool a shade group's followers come from — grouping shades Home Assistant considers
/// unrelated is the entire point, so this is the room's entities and not the device's.
@Test func theRoomsEntitiesAreTheOnesSharingItsArea() {
    #expect(home().areaEntityIds(containing: "cover.garage")
            == ["binary_sensor.open", "cover.garage", "light.hall"])
}

/// Sorted, so a picker does not reshuffle between openings — the rule `addableEntityIds` follows.
@Test func roomEntitiesComeBackSorted() {
    let ids = home().areaEntityIds(containing: "light.hall")
    #expect(ids == ids.sorted())
}

@Test func anEntityInNoAreaHasNoRoomEntities() {
    #expect(home().areaEntityIds(containing: "light.nowhere").isEmpty)
}

/// The companions a role could be bound to: entities on the *same physical device*, which is how a
/// garage opener finds its own limit sensors without matching on names.
@Test func siblingsAreTheOtherEntitiesOnTheSameDevice() {
    #expect(home().siblingEntityIds(of: "cover.garage") == ["binary_sensor.open"])
}

@Test func anEntityIsNeverItsOwnSibling() {
    #expect(!home().siblingEntityIds(of: "cover.garage").contains("cover.garage"))
}

/// **An empty `device_id` is not a device.** Home Assistant reports one for the many integrations
/// that create entities without a device, and treating it as an id would make every such entity a
/// sibling of every other — a picker offering the whole home.
@Test func anEntityWithNoDeviceHasNoSiblings() {
    #expect(home().siblingEntityIds(of: "light.kitchen").isEmpty)
    #expect(home().siblingEntityIds(of: "light.unknown").isEmpty)
}
