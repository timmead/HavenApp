import Foundation
import Testing
@testable import HavenCore

// MARK: - Binary sensors

/// The glyph and the word have to agree, always. A door reading "Open" beside a closed-door picture
/// is the failure this type exists to make impossible, so every case asserts both together.
@Test func aDoorSensorOpensAndCloses() {
    let open = TileState.binarySensor(deviceClass: "door", isActive: true)
    #expect(open == TileState(symbol: "door.left.hand.open", word: "Open"))
    let shut = TileState.binarySensor(deviceClass: "door", isActive: false)
    #expect(shut == TileState(symbol: "door.left.hand.closed", word: "Closed"))
}

/// **What "on" means is entirely device-class specific**, which is the whole reason this is a table
/// rather than an on/off word. Wet, detected and motion are all "on".
@Test func onMeansSomethingDifferentForEachKindOfSensor() {
    #expect(TileState.binarySensor(deviceClass: "moisture", isActive: true).word == "Wet")
    #expect(TileState.binarySensor(deviceClass: "smoke", isActive: true).word == "Detected")
    #expect(TileState.binarySensor(deviceClass: "motion", isActive: true).word == "Motion")
    #expect(TileState.binarySensor(deviceClass: "battery", isActive: true).word == "Low")
}

/// Home Assistant's `lock` binary sensor is inverted — `on` is *unlocked* — and reading it the
/// ordinary way round would state that a door is locked when it is standing open.
@Test func aLockSensorIsInverted() {
    #expect(TileState.binarySensor(deviceClass: "lock", isActive: true).word == "Unlocked")
    #expect(TileState.binarySensor(deviceClass: "lock", isActive: false).word == "Locked")
}

/// An unrecognised device class keeps one glyph in both states, deliberately. Haven does not know
/// what "on" means for it, and a picture that implies otherwise is worse than a neutral one.
@Test func anUnknownKindOfSensorDoesNotInventAPicture() {
    let active = TileState.binarySensor(deviceClass: "vibration", isActive: true)
    let clear = TileState.binarySensor(deviceClass: "vibration", isActive: false)
    #expect(active.symbol == clear.symbol)
    #expect(active.word == "Active")
    #expect(clear.word == "Clear")
}

// MARK: - Covers

@Test func aCoverLooksLikeWhatItIs() {
    #expect(TileState.cover(deviceClass: "garage", isOpen: true).symbol == "door.garage.open")
    #expect(TileState.cover(deviceClass: "curtain", isOpen: false).symbol == "curtains.closed")
    // Anything unrecognised is blinds, which is what the neutral cover glyph already was.
    #expect(TileState.cover(deviceClass: nil, isOpen: true).symbol == "blinds.horizontal.open")
}

// MARK: - Locks

/// Jammed is not a third shade of locked — it is a door that tried and failed — so it gets its own
/// glyph and its own word rather than being folded into either.
@Test func aJammedLockIsNeitherLockedNorUnlocked() {
    let jammed = TileState.lock(isLocked: false, isJammed: true)
    #expect(jammed.word == "Jammed")
    #expect(jammed.symbol != TileState.lock(isLocked: true, isJammed: false).symbol)
    #expect(jammed.symbol != TileState.lock(isLocked: false, isJammed: false).symbol)
}

// MARK: - Unreachable

/// **The rule `LockTile` wrote down, now every two-state tile's.**
///
/// `isLocked` reads false for an unreachable lock exactly as it would for an open one, so the domain
/// glyph would confidently state that a door is unlocked when Haven knows nothing about it. One
/// glyph asserting neither is the only honest answer — and critically it is not `lock.fill`, which
/// would swap one false claim for a worse one.
@Test func anUnreachableDeviceAssertsNothingAboutItsState() {
    #expect(TileState.lock(isLocked: false, isJammed: false, unavailable: true) == .unavailable)
    #expect(TileState.binarySensor(deviceClass: "door", isActive: true, unavailable: true) == .unavailable)
    #expect(TileState.cover(deviceClass: "garage", isOpen: true, unavailable: true) == .unavailable)
    #expect(TileState.unavailable.symbol == "questionmark.circle")
    #expect(TileState.unavailable.symbol != "lock.fill")
}

// MARK: - Which domains have a face at all

@Test func onlyTwoStateDomainsOfferTheChoice() {
    #expect(TileState.isTwoState(.binarySensor))
    #expect(TileState.isTwoState(.lock))
    #expect(TileState.isTwoState(.cover))
    #expect(!TileState.isTwoState(.sensor))
    #expect(!TileState.isTwoState(.camera))
    #expect(!TileState.isTwoState(.climate))
}

// MARK: - Switches

/// The glyph fills when on and hollows when off, doubling the distinction the tint already makes —
/// which is the point, since tint alone is what made every two-state tile look alike.
@Test func aSwitchFillsWhenItIsOn() {
    let on = TileState.switchOutlet(deviceClass: nil, isOn: true)
    let off = TileState.switchOutlet(deviceClass: nil, isOn: false)
    #expect(on.word == "On")
    #expect(off.word == "Off")
    #expect(on.symbol != off.symbol)
}

/// An outlet looks like an outlet rather than like a generic power symbol.
@Test func anOutletKeepsItsOwnPicture() {
    #expect(TileState.switchOutlet(deviceClass: "outlet", isOn: true).symbol
            == "poweroutlet.type.b.fill")
}

@Test func anUnreachableSwitchAssertsNothing() {
    #expect(TileState.switchOutlet(deviceClass: nil, isOn: false, unavailable: true) == .unavailable)
}

/// **A light is two-state as well, brightness slider and all.** It was left out at first on the
/// grounds that a centred glyph would have to sit around the slider — but a cover's tile carries one
/// too and shares the space without trouble, so the exception was not earned.
///
/// What stays out are the domains with something better to show than two states: a reading, a
/// picture, a temperature and a mode, or an action with no state at all.
@Test func aLightIsTwoStateButAThermostatIsNot() {
    #expect(TileState.isTwoState(.switchOutlet))
    #expect(TileState.isTwoState(.light))
    #expect(TileState.light(isOn: true).symbol == "lightbulb.fill")
    #expect(TileState.light(isOn: false).symbol == "lightbulb")
    #expect(TileState.light(isOn: true, unavailable: true) == .unavailable)
    #expect(!TileState.isTwoState(.climate))
    #expect(!TileState.isTwoState(.mediaPlayer))
}
