import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// **A removed composite must remain findable.**
///
/// The `+` list walked only `.entity` refs, from when nothing constructed composites — so a garage
/// door the household removed vanished completely: hidden by its membership override, and absent
/// from the one list that could bring it back. Off the dashboard with no way to it.
@Suite @MainActor struct AddableDeviceTests {
    private func roomWithHiddenGarage() -> (HomeStore, RoomSection) {
        let store = HomeStore()
        store.states["switch.opener"] = EntityState(
            entityId: "switch.opener", state: "off", attributes: [:],
            lastUpdated: Date(timeIntervalSince1970: 0))
        store.home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "F", level: 0, areas: [
            ResolvedArea(id: "garage", name: "Garage", entityIds: ["switch.opener"],
                         tiers: ["switch.opener": .primary])])])
        store.config.seedForTesting(
            DashboardDocument()
                .settingDevice(DashboardDocument.StoredDevice(
                    id: "switch.opener", type: "garage_door", areaId: "garage",
                    inputs: [.primary: ["switch.opener"]]), id: "switch.opener")
                .settingMembership(.hidden, for: "switch.opener", on: .overview))
        return (store, store.rooms().first { $0.areaId == "garage" }!)
    }

    @Test func aHiddenCompositeIsOfferedBackByThePlusButton() {
        let (store, room) = roomWithHiddenGarage()
        // Gone from the dashboard, as removing it should do.
        #expect(room.refs(for: .overview).isEmpty)
        // And offerable again, which is what was missing.
        #expect(store.addableEntityIds(in: room, on: .overview) == ["switch.opener"])
    }

    /// A composite that is showing is not also offered — it is already there.
    @Test func aShowingCompositeIsNotOffered() {
        let store = HomeStore()
        store.home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "F", level: 0, areas: [
            ResolvedArea(id: "garage", name: "Garage", entityIds: ["switch.opener"],
                         tiers: ["switch.opener": .primary])])])
        store.config.seedForTesting(DashboardDocument().settingDevice(
            DashboardDocument.StoredDevice(id: "switch.opener", type: "garage_door",
                                           areaId: "garage",
                                           inputs: [.primary: ["switch.opener"]]),
            id: "switch.opener"))
        let room = store.rooms().first { $0.areaId == "garage" }!
        #expect(room.refs(for: .overview).map(\.id) == ["switch.opener"])
        #expect(store.addableEntityIds(in: room, on: .overview).isEmpty)
    }
}
