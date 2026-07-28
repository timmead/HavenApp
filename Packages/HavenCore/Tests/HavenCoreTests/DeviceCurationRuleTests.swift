import Testing
@testable import HavenCore

/// **Entities that are part of a bigger thing should not sit beside it on the grid.**
///
/// Observed: a UniFi Protect doorbell is one device exposing a camera, a speaker
/// (`media_player`), and a chime (`button`). All three are primary domains, so all three earned
/// their own tile and the room showed a "camera speaker" as though it were a device you own.
///
/// The rules only ever *demote*, and only from `.primary` to `.companion`. They never promote,
/// never touch `.hidden` — what the user hid in Home Assistant outranks every heuristic here — and
/// never touch `.secondary`, which is already off the overview grid.
@Suite struct DeviceCurationRuleTests {
    private func entity(_ id: String, device: String? = "device-1",
                        hiddenBy: String? = nil, platform: String? = nil) -> EntityRegistryEntry {
        EntityRegistryEntry(entityId: id, areaId: "living", deviceId: device, name: nil,
                            hiddenBy: hiddenBy, platform: platform)
    }

    // MARK: - container

    /// The case this exists for.
    @Test func aContainerDemotesItsSiblingsInOtherDomains() {
        let tiers = EntityCuration.tiers(for: [
            entity("camera.doorbell"),
            entity("media_player.doorbell_speaker"),
            entity("button.doorbell_chime"),
        ], rules: [.container(domain: "camera")])

        #expect(tiers["camera.doorbell"] == .primary)
        #expect(tiers["media_player.doorbell_speaker"] == .companion)
        #expect(tiers["button.doorbell_chime"] == .companion)
    }

    /// **The case that rules out "one tile per device".** A three-gang wall switch is one device
    /// with three switch entities, and all three are things you press. A rule that demoted
    /// same-domain siblings would take two of them away.
    @Test func aContainerLeavesItsSameDomainSiblingsAlone() {
        let tiers = EntityCuration.tiers(for: [
            entity("switch.hall_gang1"),
            entity("switch.hall_gang2"),
            entity("switch.hall_gang3"),
        ], rules: [.container(domain: "switch")])

        #expect(tiers["switch.hall_gang1"] == .primary)
        #expect(tiers["switch.hall_gang2"] == .primary)
        #expect(tiers["switch.hall_gang3"] == .primary)
    }

    /// A rule is about one physical device, never about the room. A speaker that happens to share a
    /// room with a camera is still a speaker you own.
    @Test func aContainerDoesNotReachAcrossDevices() {
        let tiers = EntityCuration.tiers(for: [
            entity("camera.doorbell", device: "camera-device"),
            entity("media_player.kitchen_sonos", device: "sonos-device"),
        ], rules: [.container(domain: "camera")])

        #expect(tiers["camera.doorbell"] == .primary)
        #expect(tiers["media_player.kitchen_sonos"] == .primary)
    }

    /// **A container that isn't showing demotes nothing.** Hiding the camera in Home Assistant and
    /// then losing its speaker too would leave the device with no presence at all — and the user
    /// hid one entity, not the device.
    @Test func aHiddenContainerLeavesItsSiblingsWhereTheyWere() {
        let tiers = EntityCuration.tiers(for: [
            entity("camera.doorbell", hiddenBy: "user"),
            entity("media_player.doorbell_speaker"),
        ], rules: [.container(domain: "camera")])

        #expect(tiers["camera.doorbell"] == .hidden)
        #expect(tiers["media_player.doorbell_speaker"] == .primary)
    }

    /// An entity with no device has no parent to be part of.
    @Test func anEntityWithNoDeviceIsUntouched() {
        let tiers = EntityCuration.tiers(for: [
            entity("camera.doorbell"),
            entity("media_player.standalone", device: nil),
        ], rules: [.container(domain: "camera")])

        #expect(tiers["media_player.standalone"] == .primary)
    }

    // MARK: - singlePrimary

    /// For an integration that exposes one physical thing as several controls. Ships with no rows
    /// — see `EntityCuration.defaultRules` — so this pins the mechanism, not a shipped behaviour.
    @Test func singlePrimaryKeepsOnlyTheHighestRankedEntity() {
        let tiers = EntityCuration.tiers(for: [
            entity("switch.vac_pause", platform: "roborock"),
            entity("button.vac_dock", platform: "roborock"),
            entity("scene.vac_spot", platform: "roborock"),
        ], rules: [.singlePrimary(platform: "roborock", preferring: ["scene", "switch", "button"])])

        #expect(tiers["scene.vac_spot"] == .primary)
        #expect(tiers["switch.vac_pause"] == .companion)
        #expect(tiers["button.vac_dock"] == .companion)
    }

    /// Two entities of the winning domain on one device would otherwise leave the outcome to
    /// whatever order the registry happened to arrive in. Lowest entity id wins, so the same home
    /// renders the same way every launch.
    @Test func singlePrimaryBreaksTiesDeterministically() {
        let forwards = EntityCuration.tiers(for: [
            entity("switch.vac_a", platform: "roborock"),
            entity("switch.vac_b", platform: "roborock"),
        ], rules: [.singlePrimary(platform: "roborock", preferring: ["switch"])])
        let backwards = EntityCuration.tiers(for: [
            entity("switch.vac_b", platform: "roborock"),
            entity("switch.vac_a", platform: "roborock"),
        ], rules: [.singlePrimary(platform: "roborock", preferring: ["switch"])])

        #expect(forwards["switch.vac_a"] == .primary)
        #expect(forwards["switch.vac_b"] == .companion)
        #expect(forwards == backwards)
    }

    /// A rule scoped to one integration must not touch another's devices.
    @Test func singlePrimaryOnlyAppliesToItsOwnPlatform() {
        let tiers = EntityCuration.tiers(for: [
            entity("switch.vac_pause", device: "vac", platform: "roborock"),
            entity("switch.lamp", device: "lamp", platform: "hue"),
            entity("button.lamp_reset", device: "lamp", platform: "hue"),
        ], rules: [.singlePrimary(platform: "roborock", preferring: ["switch"])])

        #expect(tiers["switch.lamp"] == .primary)
        #expect(tiers["button.lamp_reset"] == .primary)
    }

    // MARK: - Invariants

    /// **Rules demote and nothing else.** The one direction that could cost a user a control they
    /// can reach today is the one direction this must never take.
    @Test func rulesNeverRaiseATier() {
        let entries = [
            entity("camera.doorbell"),
            entity("media_player.doorbell_speaker"),
            entity("sensor.doorbell_battery"),
            entity("switch.doorbell_led", hiddenBy: "user"),
        ]
        let without = EntityCuration.tiers(for: entries, rules: [])
        let with = EntityCuration.tiers(for: entries, rules: [.container(domain: "camera")])

        let rank: [CurationTier: Int] = [.primary: 3, .secondary: 2, .companion: 1, .hidden: 0]
        for (id, before) in without {
            let after = with[id]!
            #expect(rank[after]! <= rank[before]!, "\(id) was raised from \(before) to \(after)")
        }
    }

    /// The never-empty-a-room rescue runs *after* the rules, so a room the rules emptied still
    /// shows something rather than reading as a broken app. A camera in one room and its speaker
    /// alone in another is the shape that gets here.
    @Test func aRoomEmptiedByTheRulesIsStillRescued() {
        let tiers = EntityCuration.tiers(for: [
            entity("camera.doorbell"),
            entity("media_player.doorbell_speaker"),
            entity("button.doorbell_chime"),
        ], rules: [.container(domain: "camera"), .container(domain: "media_player")])

        // Whatever the rules did, the room is not blank.
        #expect(tiers.values.contains(.primary))
    }

    /// The shipped table, stated so a change to it is a deliberate edit rather than a surprise.
    @Test func onlyTheCameraRuleShipsToday() {
        #expect(EntityCuration.defaultRules == [.container(domain: "camera")])
    }
}
