import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// A bound limit sensor, read back through the store the way the configuration sheet reads it.
///
/// **The read, not the write.** `HavenConfig.update` needs a connection, so a store-level test of
/// the write would only prove the harness has no socket — which is what the first version of this
/// file proved, loudly and uselessly. The bug was in the read: a device stored under an old
/// generated id sat alongside the real record, won the tiebreak, and took the binding with it.
@Suite @MainActor struct RoleBindingPersistenceTests {

    private func store(_ document: DashboardDocument) -> HomeStore {
        let store = HomeStore()
        store.states["switch.opener"] = EntityState(
            entityId: "switch.opener", state: "off", attributes: [:],
            lastUpdated: Date(timeIntervalSince1970: 0))
        store.states["binary_sensor.g_closed"] = EntityState(
            entityId: "binary_sensor.g_closed", state: "on",
            attributes: ["device_class": .string("door")],
            lastUpdated: Date(timeIntervalSince1970: 0))
        store.home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "F", level: 0, areas: [
            ResolvedArea(id: "garage", name: "Garage",
                         entityIds: ["switch.opener", "binary_sensor.g_closed"],
                         tiers: ["switch.opener": .primary,
                                 "binary_sensor.g_closed": .secondary])])])
        store.config.seedForTesting(document)
        return store
    }

    private var bound: DashboardDocument {
        DashboardDocument().settingDevice(
            DashboardDocument.StoredDevice(
                id: "switch.opener", type: "garage_door", areaId: "garage",
                inputs: [.primary: ["switch.opener"],
                         .closedLimit: ["binary_sensor.g_closed"]]),
            id: "switch.opener")
    }

    @Test func aBoundRoleIsReadBack() {
        let store = store(bound)
        #expect(store.bindings(of: "switch.opener")[.closedLimit] == "binary_sensor.g_closed")
    }

    /// And it changes what the tile says, which is the reason to bind anything.
    @Test func aBoundRoleChangesWhatTheTileSays() {
        #expect(store(bound).deviceState(of: "switch.opener").face?.word == "Closed")
    }

    /// **The bug, at the level the household experienced it.** A device created before ids were
    /// fixed leaves a `haven:…` record behind. With that ghost present, binding a sensor appeared to
    /// do nothing: the write landed on the real record and the read handed back the ghost.
    @Test func aGhostRecordDoesNotSwallowANewBinding() {
        let ghost = DashboardDocument(raw: .object([
            "schema": .int(DashboardDocument.schema),
            "devices": .object([
                "haven:garage_door:abc": .object([
                    "type": .string("garage_door"), "area": .string("garage"),
                    "inputs": .object(["primary": .array([.string("switch.opener")])])]),
                "switch.opener": .object([
                    "type": .string("garage_door"), "area": .string("garage"),
                    "inputs": .object(["primary": .array([.string("switch.opener")]),
                                       "closed_limit": .array([.string("binary_sensor.g_closed")])])]),
            ])]))
        let store = store(ghost)
        #expect(store.bindings(of: "switch.opener")[.closedLimit] == "binary_sensor.g_closed")
        #expect(store.deviceState(of: "switch.opener").face?.word == "Closed")
    }
}
