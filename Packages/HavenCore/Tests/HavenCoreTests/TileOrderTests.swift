import Foundation
import Testing
@testable import HavenCore

// MARK: - The default order

/// 5a's banding, unchanged: climate leads because a room's temperature is what a glance is usually
/// for, cameras trail because four feeds at the top of every room would make the dashboard a
/// security console, and everything else keeps the order it arrived in.
@Test func theDefaultOrderIsClimateThenTheRestThenMediaThenCameras() {
    let ids = ["camera.front", "light.a", "media_player.tv", "climate.hall", "light.b"]
    #expect(TileOrder.defaultOrder(ids) == ["climate.hall", "light.a", "light.b",
                                            "media_player.tv", "camera.front"])
}

// MARK: - Resolution

@Test func aStoredOrderIsHonoured() {
    let resolved = TileOrder.resolve(stored: ["light.b", "light.a"], present: ["light.a", "light.b"])
    #expect(resolved == ["light.b", "light.a"])
}

/// **The rule that makes this survive a real home.** Home Assistant gains entities after someone has
/// arranged a room, and a new one has to appear somewhere obvious: at the end. Dropping it would lose
/// a device the user owns, and leading with it would rearrange a room nobody touched.
@Test func somethingNewAppearsAtTheEndInDefaultOrder() {
    let resolved = TileOrder.resolve(stored: ["light.b", "light.a"],
                                     present: ["light.a", "light.b", "camera.new", "climate.new"])
    // The stored pair keep their arrangement; the two newcomers follow in default order — which puts
    // the thermostat before the camera even though the ids say otherwise.
    #expect(resolved == ["light.b", "light.a", "climate.new", "camera.new"])
}

/// A device removed in Home Assistant leaves the stored list rather than haunting it, or the order
/// grows forever with things nobody can see.
@Test func somethingRemovedDropsOutOfTheOrder() {
    let resolved = TileOrder.resolve(stored: ["light.gone", "light.a"], present: ["light.a"])
    #expect(resolved == ["light.a"])
}

@Test func noStoredOrderIsSimplyTheDefault() {
    let present = ["camera.front", "light.a", "climate.hall"]
    #expect(TileOrder.resolve(stored: [], present: present) == TileOrder.defaultOrder(present))
}

// MARK: - Moving

@Test func movingBackwardsInsertsBeforeTheTarget() {
    let order = ["a", "b", "c", "d"]
    #expect(TileOrder.moving("d", before: "b", in: order) == ["a", "d", "b", "c"])
}

/// **Forwards is where the off-by-one lives.** Removing "a" shifts everything after it down one, so
/// an implementation that finds the target's index *before* removing lands one place early.
@Test func movingForwardsPastItsOwnPositionLandsBeforeTheTarget() {
    let order = ["a", "b", "c", "d"]
    #expect(TileOrder.moving("a", before: "d", in: order) == ["b", "c", "a", "d"])
}

@Test func movingWithNoTargetPutsItLast() {
    #expect(TileOrder.moving("a", before: nil, in: ["a", "b", "c"]) == ["b", "c", "a"])
}

/// Dropping a tile on itself is a gesture users make constantly — a lift that goes nowhere. It has
/// to be a no-op, not a duplication and not a removal.
@Test func movingSomethingOntoItselfChangesNothing() {
    let order = ["a", "b", "c"]
    #expect(TileOrder.moving("b", before: "b", in: order) == order)
}

@Test func movingSomethingAbsentChangesNothing() {
    let order = ["a", "b", "c"]
    #expect(TileOrder.moving("zzz", before: "b", in: order) == order)
    #expect(TileOrder.moving("a", before: "zzz", in: order) == order)
}
