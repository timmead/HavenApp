import Foundation
import Testing
@testable import HavenCore

private func info(_ deviceId: String?) -> EntityRegistryInfo {
    EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: deviceId)
}

private func state(_ id: String, _ s: String, _ deviceClass: String? = nil,
                   unit: String? = nil, name: String? = nil) -> EntityState {
    var attrs: [String: JSONValue] = [:]
    if let deviceClass { attrs["device_class"] = .string(deviceClass) }
    if let unit { attrs["unit_of_measurement"] = .string(unit) }
    if let name { attrs["friendly_name"] = .string(name) }
    return EntityState(entityId: id, state: s, attributes: attrs,
                       lastUpdated: Date(timeIntervalSince1970: 0))
}

// MARK: - Discovery

/// A lock and the door sensor on the same physical device: the case the whole feature exists for.
/// The lock says locked; whether the door is actually shut is a different entity.
@Test func aCompanionOnTheSameDeviceBecomesAReading() {
    let out = CompositeState.resolve(
        primary: "lock.front", deviceId: "d1",
        registry: ["lock.front": info("d1"), "binary_sensor.front_door": info("d1")],
        tiers: ["lock.front": .primary, "binary_sensor.front_door": .companion],
        states: ["lock.front": state("lock.front", "locked"),
                 "binary_sensor.front_door": state("binary_sensor.front_door", "off", "door")])
    #expect(out.primary == "lock.front")
    #expect(out.readings.map(\.entityId) == ["binary_sensor.front_door"])
    // The word is TileState's, so a door reads "Closed" rather than "Off".
    #expect(out.readings.first?.value == "Closed")
    #expect(out.readings.first?.isActive == false)
}

/// Only `.companion` entities. A `.primary` sibling has a tile of its own and must not also turn up
/// as somebody else's footnote.
@Test func aPrimarySiblingIsNotACompanion() {
    let out = CompositeState.resolve(
        primary: "lock.front", deviceId: "d1",
        registry: ["lock.front": info("d1"), "switch.chime": info("d1")],
        tiers: ["lock.front": .primary, "switch.chime": .primary],
        states: [:])
    #expect(out.readings.isEmpty)
}

@Test func anotherDevicesEntityIsNotACompanion() {
    let out = CompositeState.resolve(
        primary: "lock.front", deviceId: "d1",
        registry: ["lock.front": info("d1"), "binary_sensor.other": info("d2")],
        tiers: ["lock.front": .primary, "binary_sensor.other": .companion],
        states: [:])
    #expect(out.readings.isEmpty)
}

/// **A device-less primary matches nothing rather than everything.** Many integrations create
/// entities with no `device_id`, and a naive `==` on two optionals would make every one of them a
/// companion of every other — the trap `CameraEvents.related` records on the same rung.
@Test func aPrimaryWithNoDeviceMatchesNothing() {
    let out = CompositeState.resolve(
        primary: "lock.front", deviceId: nil,
        registry: ["lock.front": info(nil), "binary_sensor.loose": info(nil)],
        tiers: ["lock.front": .primary, "binary_sensor.loose": .companion],
        states: [:])
    #expect(out.readings.isEmpty)
}

// MARK: - Ordering

/// **The contract a tile depends on.** A tile will show only the first reading, so the first has to
/// be the one qualifying the device's own state — not its battery.
@Test func theMostContextualReadingComesFirst() {
    let out = CompositeState.resolve(
        primary: "cover.garage", deviceId: "d1",
        registry: ["cover.garage": info("d1"),
                   "sensor.garage_battery": info("d1"),
                   "binary_sensor.garage_closed": info("d1")],
        tiers: ["cover.garage": .primary,
                "sensor.garage_battery": .companion,
                "binary_sensor.garage_closed": .companion],
        states: ["sensor.garage_battery": state("sensor.garage_battery", "88", "battery", unit: "%"),
                 "binary_sensor.garage_closed": state("binary_sensor.garage_closed", "off", "door")])
    #expect(out.readings.map(\.entityId)
            == ["binary_sensor.garage_closed", "sensor.garage_battery"])
}

/// Ties break on entity id, so a home renders identically on every launch rather than reshuffling
/// with whatever order the registry dictionary happened to enumerate in.
@Test func tiesBreakOnEntityIdSoTheOrderIsStable() {
    let registry = ["lock.f": info("d1"), "binary_sensor.b": info("d1"),
                    "binary_sensor.a": info("d1"), "binary_sensor.c": info("d1")]
    let tiers: [String: CurationTier] = ["lock.f": .primary, "binary_sensor.a": .companion,
                                          "binary_sensor.b": .companion, "binary_sensor.c": .companion]
    for _ in 0..<5 {
        let out = CompositeState.resolve(primary: "lock.f", deviceId: "d1",
                                         registry: registry, tiers: tiers, states: [:])
        #expect(out.readings.map(\.entityId)
                == ["binary_sensor.a", "binary_sensor.b", "binary_sensor.c"])
    }
}

// MARK: - Reading one companion

/// An unreachable companion says so. Dropping it would make an offline door sensor and an absent one
/// look identical, which is the opposite of telling the user what the device knows.
@Test func anUnreachableCompanionIsStillAReading() {
    let out = CompositeState.resolve(
        primary: "lock.front", deviceId: "d1",
        registry: ["lock.front": info("d1"), "binary_sensor.front_door": info("d1")],
        tiers: ["lock.front": .primary, "binary_sensor.front_door": .companion],
        states: ["binary_sensor.front_door": state("binary_sensor.front_door", "unavailable", "door")])
    #expect(out.readings.first?.value == TileState.unavailable.word)
    // And it is not tinted: "unavailable" is not an alarm.
    #expect(out.readings.first?.isActive == nil)
}

/// A companion with no state at all — in the registry, never seen in the state machine — reads the
/// same way rather than crashing or vanishing.
@Test func aCompanionWithNoStateReadsAsUnavailable() {
    let out = CompositeState.resolve(
        primary: "lock.front", deviceId: "d1",
        registry: ["lock.front": info("d1"), "binary_sensor.ghost": info("d1")],
        tiers: ["lock.front": .primary, "binary_sensor.ghost": .companion],
        states: [:])
    #expect(out.readings.first?.value == TileState.unavailable.word)
}

/// A numeric companion reads as its value and unit, not through the binary vocabulary — and is not
/// tinted, because a percentage is not an alarm.
@Test func aNumericCompanionReadsAsItsValue() {
    let out = CompositeState.resolve(
        primary: "lock.front", deviceId: "d1",
        registry: ["lock.front": info("d1"), "sensor.b": info("d1")],
        tiers: ["lock.front": .primary, "sensor.b": .companion],
        states: ["sensor.b": state("sensor.b", "88", "battery", unit: "%")])
    #expect(out.readings.first?.value == "88 %")
    #expect(out.readings.first?.isActive == nil)
}

/// The label is the companion's own display name, so a device whose entities were named in Home
/// Assistant reads that way here too.
@Test func theLabelIsTheCompanionsDisplayName() {
    let out = CompositeState.resolve(
        primary: "lock.front", deviceId: "d1",
        registry: ["lock.front": info("d1"), "binary_sensor.front_door": info("d1")],
        tiers: ["lock.front": .primary, "binary_sensor.front_door": .companion],
        states: ["binary_sensor.front_door":
                    state("binary_sensor.front_door", "on", "door", name: "Front Door Contact")])
    #expect(out.readings.first?.label == "Front Door Contact")
}

// MARK: - What the parent already renders

/// A camera's motion sensors are chips in `CameraModal`; listing them again as readings is one fact
/// twice. The caller says what it has already drawn.
@Test func whatTheParentAlreadyRendersIsSkipped() {
    let out = CompositeState.resolve(
        primary: "camera.door", deviceId: "d1",
        registry: ["camera.door": info("d1"), "binary_sensor.motion": info("d1"),
                   "sensor.battery": info("d1")],
        tiers: ["camera.door": .primary, "binary_sensor.motion": .companion,
                "sensor.battery": .companion],
        states: ["binary_sensor.motion": state("binary_sensor.motion", "on", "motion"),
                 "sensor.battery": state("sensor.battery", "70", "battery", unit: "%")],
        excluding: ["binary_sensor.motion"])
    // The chip's sensor is gone; the battery — which no chip shows — remains.
    #expect(out.readings.map(\.entityId) == ["sensor.battery"])
}

// MARK: - The derived face

private func garage(_ closedLimit: String, _ openLimit: String) -> [DeviceRole: String] {
    [.closedLimit: closedLimit, .openLimit: openLimit]
}

/// **The row that justifies the whole feature.** `cover.garage` reports open or closed; a door
/// stopped half way is neither, and only both limit sensors reading off can say so.
@Test func neitherLimitReachedIsPartlyOpen() {
    let out = CompositeState.resolve(
        primary: "cover.garage", deviceId: "d1",
        registry: ["cover.garage": info("d1")],
        tiers: ["cover.garage": .primary],
        states: ["cover.garage": state("cover.garage", "open", "garage"),
                 "binary_sensor.closed": state("binary_sensor.closed", "off"),
                 "binary_sensor.open": state("binary_sensor.open", "off")],
        bindings: garage("binary_sensor.closed", "binary_sensor.open"))
    #expect(out.face?.word == "Partly open")
}

@Test func theClosedLimitReadsClosed() {
    let out = CompositeState.resolve(
        primary: "cover.garage", deviceId: "d1",
        registry: ["cover.garage": info("d1")],
        tiers: ["cover.garage": .primary],
        states: ["cover.garage": state("cover.garage", "open", "garage"),
                 "binary_sensor.closed": state("binary_sensor.closed", "on"),
                 "binary_sensor.open": state("binary_sensor.open", "off")],
        bindings: garage("binary_sensor.closed", "binary_sensor.open"))
    #expect(out.face?.word == "Closed")
    // And it outranks the cover entity's own "open", which is the point of deriving at all.
    #expect(out.face?.symbol == "door.garage.closed")
}

@Test func theOpenLimitReadsOpen() {
    let out = CompositeState.resolve(
        primary: "cover.garage", deviceId: "d1",
        registry: ["cover.garage": info("d1")],
        tiers: ["cover.garage": .primary],
        states: ["cover.garage": state("cover.garage", "closed", "garage"),
                 "binary_sensor.closed": state("binary_sensor.closed", "off"),
                 "binary_sensor.open": state("binary_sensor.open", "on")],
        bindings: garage("binary_sensor.closed", "binary_sensor.open"))
    #expect(out.face?.word == "Open")
}

/// Contradictory hardware resolves to Closed: a garage reported shut by its own closed sensor is
/// the reading you act on.
@Test func bothLimitsOnReadsClosed() {
    let out = CompositeState.resolve(
        primary: "cover.garage", deviceId: "d1",
        registry: ["cover.garage": info("d1")],
        tiers: ["cover.garage": .primary],
        states: ["binary_sensor.closed": state("binary_sensor.closed", "on"),
                 "binary_sensor.open": state("binary_sensor.open", "on")],
        bindings: garage("binary_sensor.closed", "binary_sensor.open"))
    #expect(out.face?.word == "Closed")
}

/// **An unreachable limit yields no face at all, not a guess.** A door whose closed sensor is
/// offline is a door Haven does not know about, and "Partly open" asserted from one working sensor
/// is the confident wrong answer this codebase keeps refusing to give.
@Test func anUnreachableLimitRefinesNothing() {
    let out = CompositeState.resolve(
        primary: "cover.garage", deviceId: "d1",
        registry: ["cover.garage": info("d1")],
        tiers: ["cover.garage": .primary],
        states: ["binary_sensor.closed": state("binary_sensor.closed", "unavailable"),
                 "binary_sensor.open": state("binary_sensor.open", "off")],
        bindings: garage("binary_sensor.closed", "binary_sensor.open"))
    #expect(out.face == nil)
}

/// One limit bound and the other not says nothing either — half a pair cannot distinguish "partly
/// open" from "at the other limit".
@Test func oneLimitAloneRefinesNothing() {
    let out = CompositeState.resolve(
        primary: "cover.garage", deviceId: "d1",
        registry: ["cover.garage": info("d1")],
        tiers: ["cover.garage": .primary],
        states: ["binary_sensor.closed": state("binary_sensor.closed", "off")],
        bindings: [.closedLimit: "binary_sensor.closed"])
    #expect(out.face == nil)
}

/// An unbound device is unchanged — the common case, and the one that must not regress.
@Test func nothingBoundRefinesNothing() {
    let out = CompositeState.resolve(
        primary: "cover.garage", deviceId: "d1",
        registry: ["cover.garage": info("d1")],
        tiers: ["cover.garage": .primary],
        states: [:])
    #expect(out.face == nil)
}

/// Only covers derive a face today. A lock with bindings would otherwise fall through the cover
/// rule and read "Partly open", which is not a thing a lock is.
@Test func onlyACoverDerivesAFace() {
    let out = CompositeState.resolve(
        primary: "lock.front", deviceId: "d1",
        registry: ["lock.front": info("d1")],
        tiers: ["lock.front": .primary],
        states: ["binary_sensor.closed": state("binary_sensor.closed", "off"),
                 "binary_sensor.open": state("binary_sensor.open", "off")],
        bindings: garage("binary_sensor.closed", "binary_sensor.open"))
    #expect(out.face == nil)
}

/// A bound entity is read into the face and drops out of the readings — the same fact three times
/// is two times too many.
@Test func aBoundEntityLeavesTheReadings() {
    let out = CompositeState.resolve(
        primary: "cover.garage", deviceId: "d1",
        registry: ["cover.garage": info("d1"),
                   "binary_sensor.closed": info("d1"),
                   "binary_sensor.open": info("d1"),
                   "sensor.signal": info("d1")],
        tiers: ["cover.garage": .primary, "binary_sensor.closed": .companion,
                "binary_sensor.open": .companion, "sensor.signal": .companion],
        states: ["binary_sensor.closed": state("binary_sensor.closed", "off"),
                 "binary_sensor.open": state("binary_sensor.open", "off"),
                 "sensor.signal": state("sensor.signal", "-61")],
        bindings: garage("binary_sensor.closed", "binary_sensor.open"))
    #expect(out.face?.word == "Partly open")
    #expect(out.readings.map(\.entityId) == ["sensor.signal"])
}

// MARK: - Which domains offer roles

/// **Roles belong to a type, not a domain.** A plain shade is a cover and has none; a garage door is
/// also a cover and has two. Keying them on the domain was right for one type and wrong for a
/// registry, which is what choosing a type in the `+` flow made obvious.
@Test func rolesBelongToATypeRatherThanADomain() {
    let garage = DeviceTypes.type(id: "garage_door")!
    #expect(garage.roles.map(\.role) == [.primary, .openLimit, .closedLimit])
    let shade = DeviceTypes.type(id: "cover")!
    #expect(shade.roles.map(\.role) == [.primary])
    let group = DeviceTypes.type(id: "shade_group")!
    #expect(group.roles.map(\.role) == [.primary, .follower])
}

/// **Partly open must not look like open.** A tile set to the icon style shows no word, so if the
/// two share a glyph then a garage standing half open and one standing fully open render
/// identically — the one comparison this feature exists to make.
@Test func partlyOpenDoesNotLookLikeOpen() {
    let partly = CompositeState.derivedFace(
        primary: "cover.garage",
        bindings: garage("binary_sensor.closed", "binary_sensor.open"),
        states: ["cover.garage": state("cover.garage", "open", "garage"),
                 "binary_sensor.closed": state("binary_sensor.closed", "off"),
                 "binary_sensor.open": state("binary_sensor.open", "off")])
    let open = TileState.cover(deviceClass: "garage", isOpen: true)
    let closed = TileState.cover(deviceClass: "garage", isOpen: false)
    #expect(partly?.symbol != open.symbol)
    #expect(partly?.symbol != closed.symbol)
}
