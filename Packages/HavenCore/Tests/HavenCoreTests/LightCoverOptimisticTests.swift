import Foundation
import Testing
@testable import HavenCore

private func light(_ state: String, brightness: Int? = 128) -> EntityState {
    var attributes: [String: JSONValue] = ["supported_color_modes": .array([.string("brightness")])]
    if let brightness { attributes["brightness"] = .int(brightness) }
    return EntityState(entityId: "light.kitchen", state: state, attributes: attributes, lastUpdated: Date())
}

private func cover(_ state: String, position: Int? = 40) -> EntityState {
    var attributes: [String: JSONValue] = [:]
    if let position { attributes["current_position"] = .int(position) }
    return EntityState(entityId: "cover.blinds", state: state, attributes: attributes, lastUpdated: Date())
}

// MARK: - Light

/// The scar this file exists for, in its mirror image. The original bug wrote `state` and left
/// `brightness` stale; a brightness drag that writes `brightness` and leaves `state` alone would
/// leave a tile whose bar has moved but whose icon, tint and name colour all still say "off".
@Test func settingBrightnessTurnsTheLightOnInTheSameWrite() {
    let after = LightOptimistic.brightness(light("off", brightness: nil), percent: 60)
    #expect(LightState(after).isOn)
    #expect(LightState(after).brightnessPercent == 60)
}

/// The round trip is the whole point of the optimistic write: the value written has to read back as
/// the value the user released on, or the pip visibly snaps to a neighbouring percentage the moment
/// they let go — which is the snap D spec §10b item 2 describes, reintroduced by rounding.
@Test func everyBrightnessPercentRoundTripsExactly() {
    for percent in 1...100 {
        let after = LightOptimistic.brightness(light("on"), percent: percent)
        #expect(LightState(after).brightnessPercent == percent, "\(percent)% did not round-trip")
    }
}

/// It models `turn_on` and cannot express "off" — Home Assistant's behaviour for
/// `brightness_pct: 0` varies by integration, and guessing here would put a state on screen the
/// instance may never agree with. Turning a light off is a different command.
@Test func brightnessNeverWritesAnOffLight() {
    for percent in [0, -20] {
        let after = LightOptimistic.brightness(light("on"), percent: percent)
        #expect(LightState(after).isOn)
        #expect(LightState(after).brightnessPercent == 1)
    }
    #expect(LightState(LightOptimistic.brightness(light("on"), percent: 140)).brightnessPercent == 100)
}

// MARK: - Cover

/// `CoverState` reads openness from the entity's `state` string and position from an attribute, so
/// a write that moves only the number leaves a shade dragged half-open rendering as closed
/// everywhere else — tile tint, icon, name colour, and the room roll-up's "2 open" count.
@Test func settingAPositionAboveZeroAlsoOpensTheCover() {
    let after = CoverOptimistic.position(cover("closed", position: 0), percent: 50)
    #expect(CoverState(after).positionPercent == 50)
    #expect(CoverState(after).isOpen)
}

@Test func draggingACoverAllTheWayDownClosesIt() {
    let after = CoverOptimistic.position(cover("open", position: 40), percent: 0)
    #expect(CoverState(after).positionPercent == 0)
    #expect(!CoverState(after).isOpen)
}

/// A single point of travel is still open. The boundary matters because it is the one the tile's
/// active tint flips on, and "1% open" reading as closed would be visible and wrong.
@Test func onePercentIsOpen() {
    #expect(CoverState(CoverOptimistic.position(cover("closed", position: 0), percent: 1)).isOpen)
}

@Test func coverPositionClampsRatherThanWritingNonsense() {
    #expect(CoverState(CoverOptimistic.position(cover("open"), percent: 140)).positionPercent == 100)
    #expect(CoverState(CoverOptimistic.position(cover("open"), percent: -20)).positionPercent == 0)
    #expect(!CoverState(CoverOptimistic.position(cover("open"), percent: -20)).isOpen)
}

/// The in-motion states are the device's business, not our request's. `CoverState.isOpen` already
/// treats `opening` as open, so writing the settled state renders correctly either way — and
/// inventing `opening` would be claiming to know something about the hardware that we don't.
@Test func theSettledStateIsWrittenNotAnInventedInMotionOne() {
    let after = CoverOptimistic.position(cover("opening", position: 10), percent: 80)
    #expect(after.state == "open")
    #expect(CoverState(after).isOpen)
}
