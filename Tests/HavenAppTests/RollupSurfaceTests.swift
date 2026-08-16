import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// The household's rule for a roll-up: it counts and acts on exactly what its own surface shows,
/// never the other surface's set. A `.secondary`-tier light is off the dashboard by curation
/// default and present in room detail, so the Lights heading — and its "All Off" — must differ
/// between the two surfaces reading the same room.
@Suite @MainActor struct RollupSurfaceTests {
    private func roomWithASecondaryLight() -> (HomeStore, RoomSection) {
        let store = HomeStore()
        for id in ["light.primary", "light.secondary"] {
            store.states[id] = EntityState(entityId: id, state: "on", attributes: [:],
                                           lastUpdated: Date(timeIntervalSince1970: 0))
        }
        store.home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "F", level: 0, areas: [
            ResolvedArea(id: "living", name: "Living",
                         entityIds: ["light.primary", "light.secondary"],
                         tiers: ["light.primary": .primary, "light.secondary": .secondary])])])
        return (store, store.rooms().first { $0.areaId == "living" }!)
    }

    /// (a) The floor's roll-up neither counts nor acts on a light room detail alone shows.
    @Test func aSecondaryTierLightDoesNotCountOrActOnTheFloor() {
        let (store, room) = roomWithASecondaryLight()
        let rollup = store.rollups(room, on: .overview).first { $0.kind == .lights }!
        #expect(rollup.total == 1)
        #expect(rollup.targetEntityIds == ["light.primary"])

        store.allOff(rollup, in: room.areaId)
        #expect(store.states["light.primary"]?.state == "off")
        #expect(store.states["light.secondary"]?.state == "on",
                "a light the floor cannot show must not be acted on by the floor's All Off")
    }

    /// (b) Room detail's roll-up counts and acts on both — including the light the floor hides.
    @Test func aSecondaryTierLightCountsAndActsInRoomDetail() {
        let (store, room) = roomWithASecondaryLight()
        let rollup = store.rollups(room, on: .roomDetail).first { $0.kind == .lights }!
        #expect(rollup.total == 2)
        #expect(rollup.targetEntityIds.sorted() == ["light.primary", "light.secondary"])

        store.allOff(rollup, in: room.areaId)
        #expect(store.states["light.primary"]?.state == "off")
        #expect(store.states["light.secondary"]?.state == "off")
    }

    /// The other route to "hidden from the floor": a `.primary`-tier light the household explicitly
    /// removed from the dashboard, per `AddableDeviceTests.roomWithHiddenGarage`'s pattern. Curation
    /// alone would show it everywhere; the override is what takes it off the overview specifically.
    private func roomWithAHouseholdRemovedLight() -> (HomeStore, RoomSection) {
        let store = HomeStore()
        for id in ["light.visible", "light.removed"] {
            store.states[id] = EntityState(entityId: id, state: "on", attributes: [:],
                                           lastUpdated: Date(timeIntervalSince1970: 0))
        }
        store.home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "F", level: 0, areas: [
            ResolvedArea(id: "den", name: "Den",
                         entityIds: ["light.visible", "light.removed"],
                         tiers: ["light.visible": .primary, "light.removed": .primary])])])
        store.config.seedForTesting(
            DashboardDocument().settingMembership(.hidden, for: "light.removed", on: .overview))
        return (store, store.rooms().first { $0.areaId == "den" }!)
    }

    /// (a), the override route: a light the household took off the dashboard is not counted or
    /// acted on there, even though curation alone would have shown it.
    @Test func aHouseholdRemovedLightDoesNotCountOrActOnTheFloor() {
        let (store, room) = roomWithAHouseholdRemovedLight()
        let rollup = store.rollups(room, on: .overview).first { $0.kind == .lights }!
        #expect(rollup.total == 1)
        #expect(rollup.targetEntityIds == ["light.visible"])

        store.allOff(rollup, in: room.areaId)
        #expect(store.states["light.visible"]?.state == "off")
        #expect(store.states["light.removed"]?.state == "on",
                "a light the household took off the floor must not be acted on by the floor's All Off")
    }

    /// (b), the override route: room detail never saw the override, so it still counts and acts on
    /// the removed light.
    @Test func aHouseholdRemovedLightCountsAndActsInRoomDetail() {
        let (store, room) = roomWithAHouseholdRemovedLight()
        let rollup = store.rollups(room, on: .roomDetail).first { $0.kind == .lights }!
        #expect(rollup.total == 2)
        #expect(rollup.targetEntityIds.sorted() == ["light.removed", "light.visible"])

        store.allOff(rollup, in: room.areaId)
        #expect(store.states["light.visible"]?.state == "off")
        #expect(store.states["light.removed"]?.state == "off")
    }
}
