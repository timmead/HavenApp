import Foundation

/// Which surfaces an entity is allowed to appear on.
///
/// Curation is a *tier* rather than a visible/hidden flag on purpose: a real Home Assistant
/// exposes hundreds of entities per home, and the useful answer is almost never "drop it" but
/// "not *here*". A humidity sensor belongs in room detail and the header chips, not on the
/// overview grid; a battery level belongs with its device. A boolean cannot express that, so
/// each surface picks the tiers it renders instead.
public enum CurationTier: String, Sendable, Equatable, Codable {
    /// Directly controllable and worth a tile on the room overview grid.
    case primary
    /// Real, user-facing information that would drown the overview grid — room detail only.
    /// Also the fallback for domains curation doesn't recognise, so an unknown domain is
    /// demoted rather than disappearing (a device that silently never renders is unfindable).
    case secondary
    /// Per-device telemetry (battery, link quality, …) that belongs *behind* its parent device
    /// rather than beside it. No surface renders this tier today — device-level grouping lands
    /// with the composite-device work — so its only current effect is keeping this noise out of
    /// room detail, plus its position in the never-empty-a-room rescue below.
    case companion
    /// Not rendered anywhere: HA settings/telemetry entities (`entity_category`) and entities
    /// the user hid in HA itself (`hidden_by`).
    case hidden
}

/// A rule about how one physical device's entities relate to one another.
///
/// **Why a table rather than a heuristic.** Home Assistant integrations model devices however they
/// please, and no single rule describes all of them: a UniFi Protect doorbell is a camera that owns
/// a speaker, while a three-gang wall switch is one device that genuinely is three switches. So
/// these are rows to be added as devices are observed, not a general theory of what a device is —
/// and each row is one line plus a test.
///
/// Every rule may only ever **demote**, and only from `.primary` to `.companion`. None of them can
/// promote, none touches `.hidden` — what the user hid in Home Assistant outranks every heuristic
/// here — and none touches `.secondary`, which is already off the overview grid. The one direction
/// that could cost someone a control they can reach today is the direction none of this takes;
/// `rulesNeverRaiseATier` holds it to that.
public enum DeviceCurationRule: Sendable, Equatable, Hashable {
    /// A domain that defines what a device **is**.
    ///
    /// When a device has a `.primary` entity in `domain`, that device's `.primary` entities in
    /// *other* domains drop to `.companion`. A doorbell camera's speaker and chime stop being
    /// devices you own and go back to being parts of the doorbell.
    ///
    /// Same-domain siblings are deliberately untouched, and that is the whole reason this is not
    /// "one tile per device": a three-gang switch is one device with three switch entities, and all
    /// three are things you press.
    case container(domain: String)

    /// For an integration that exposes one physical thing as several unrelated controls.
    ///
    /// When a device's entities come from `platform`, only the highest-ranked one survives —
    /// ranked by `preferring`, earliest domain first, ties broken by lowest entity id so the same
    /// home renders the same way on every launch. Everything else on that device drops to
    /// `.companion`.
    ///
    /// **Ships with no rows.** It exists because the shape is foreseeable, not because a device has
    /// been observed needing it; `defaultRules` is deliberately just the camera.
    case singlePrimary(platform: String, preferring: [String])
}

/// The deterministic first pass of entity curation (design spec §11, first bullet). Pure and
/// registry-only — every input is already fetched by `HomeConnection.loadStructure()`, and no
/// state, history or user preference is consulted. Relevance ranking, usage-based promotion
/// and user overrides belong to the configuration sub-project, deliberately not here.
public enum EntityCuration {
    /// Entity-id *prefixes* that earn a tile on the overview grid. Derived from the entity id,
    /// never from `Domain` — `media_player.*` maps to `Domain.unknown` yet is squarely a
    /// primary control, and the same prefix-not-enum discipline is what keeps service calls
    /// honest elsewhere (see `Domain.serviceDomain(of:)`).
    ///
    /// The spec's seven (light, switch, cover, lock, climate, media_player, scene) plus the
    /// helper/actuator prefixes that already ship working renderers — demoting those would be
    /// a visible regression from today. Domains with no renderer are deliberately *not* listed:
    /// under-promotion leaves them one tap away in room detail, over-promotion rebuilds the
    /// wall of tiles this exists to remove.
    ///
    /// `camera` joined the list with D.2 Task 4, when a renderer for it first existed. Before that
    /// it was deliberately absent under the rule stated above — promoting it would have put a
    /// `GenericTile` showing the word "idle" on the overview grid where a picture belongs.
    static let primaryDomains: Set<String> = [
        "light", "switch", "input_boolean", "cover", "lock", "climate",
        "media_player", "camera", "scene", "script", "button", "input_button",
    ]

    /// Object-id suffixes that mark per-device telemetry rather than a thing in the room.
    /// Matched against the id's object part, either whole or after an underscore, so
    /// `sensor.hall_motion_battery` matches and `sensor.battery_room_temp` does not.
    static let companionSuffixes: Set<String> = [
        "battery", "battery_level", "battery_state", "battery_voltage", "power_source",
        "linkquality", "link_quality", "lqi", "rssi", "signal_strength",
        "uptime", "last_seen", "update_available", "firmware", "identify",
    ]

    /// The tier of a single entity, ignoring its room. Rules run in this order because they are
    /// ordered by authority: what the user said in HA, then what the integration declared, then
    /// our own heuristics.
    public static func tier(of entry: EntityRegistryEntry) -> CurationTier {
        // The user already hid this in HA. Nothing below (including the rescue) overrides it.
        if entry.hiddenBy != nil { return .hidden }
        // `config`/`diagnostic` are HA's own statement that this is a setting or telemetry —
        // a "restart" button or an RSSI reading — not something you came to the room to use.
        if entry.entityCategory == "config" || entry.entityCategory == "diagnostic" { return .hidden }
        let domain = Domain.serviceDomain(of: entry.entityId)
        let isPrimaryDomain = primaryDomains.contains(domain)
        // Companion telemetry only ever *demotes*: a control keeps its tile whatever it's named,
        // so a stray suffix match can never cost the user a switch they can reach today.
        if !isPrimaryDomain, entry.deviceId != nil, isCompanionSuffix(entry.entityId) { return .companion }
        return isPrimaryDomain ? .primary : .secondary
    }

    /// Tiers for one area's entities, applying the never-empty-a-room rescue.
    ///
    /// A blank room reads as a broken app, so if the rules above leave an area with nothing on
    /// the overview grid, the best available demoted group is promoted wholesale back to
    /// `.primary` — controllable things our own heuristics hid first, then ordinary sensors,
    /// then device companions, then anything else we hid. Entities the user hid in HA are never
    /// rescued, and an area with genuinely no entities stays empty; there is nothing to show.
    /// - Parameter rules: the device-shape rules to apply. Defaulted so callers get the shipped
    ///   table, and injectable so tests can drive a rule *kind* without depending on which rows
    ///   happen to ship.
    public static func tiers(for entries: [EntityRegistryEntry],
                             rules: [DeviceCurationRule] = defaultRules) -> [String: CurationTier] {
        var result = [String: CurationTier](minimumCapacity: entries.count)
        for entry in entries { result[entry.entityId] = tier(of: entry) }
        // **Between the per-entity pass and the rescue, deliberately.** After, because a rule needs
        // to know what each entity would have been on its own. Before, because a room that these
        // rules empty must still be rescued rather than rendering blank — which is exactly what
        // happens to a room holding only a doorbell's speaker and chime.
        applyDeviceRules(rules, to: &result, entries: entries)
        guard !result.values.contains(.primary) else { return result }

        let rescuable = entries.filter { $0.hiddenBy == nil }
        let ladder: [(EntityRegistryEntry) -> Bool] = [
            // The case the sanity rule names: a controllable entity kept off the grid only by
            // our category heuristic. Showing it beats showing an empty room.
            { result[$0.entityId] == .hidden && primaryDomains.contains(Domain.serviceDomain(of: $0.entityId)) },
            { result[$0.entityId] == .secondary },
            { result[$0.entityId] == .companion },
            { result[$0.entityId] == .hidden },
        ]
        for rung in ladder {
            let promoted = rescuable.filter(rung)
            guard !promoted.isEmpty else { continue }
            for entry in promoted { result[entry.entityId] = .primary }
            break
        }
        return result
    }

    /// The rules that ship.
    ///
    /// One row, because one device shape has actually been observed getting this wrong: a UniFi
    /// Protect doorbell exposing `camera`, `media_player` (its speaker) and `button` (its chime) as
    /// three separate tiles. Rows are added from observation — see `DeviceCurationRule`.
    public static let defaultRules: [DeviceCurationRule] = [
        .container(domain: "camera"),
    ]

    /// Applies every rule to every device represented in `entries`.
    ///
    /// Entities are grouped by `deviceId`; anything without one has no parent to be part of and is
    /// left alone. Note the grouping is within *this area's* entries: an entity carrying its own
    /// `areaId` is resolved into that area by `RegistryResolver`, so deliberately moving a camera's
    /// speaker to another room in Home Assistant leaves it a tile there. That is HA configuration
    /// outranking our heuristic, the same order of authority `tier(of:)` already applies to
    /// `hidden_by`.
    private static func applyDeviceRules(_ rules: [DeviceCurationRule],
                                         to result: inout [String: CurationTier],
                                         entries: [EntityRegistryEntry]) {
        guard !rules.isEmpty else { return }
        var byDevice: [String: [EntityRegistryEntry]] = [:]
        for entry in entries {
            guard let deviceId = entry.deviceId else { continue }
            byDevice[deviceId, default: []].append(entry)
        }
        // Sorted so the outcome cannot depend on dictionary iteration order.
        for deviceId in byDevice.keys.sorted() {
            let device = byDevice[deviceId]!.sorted { $0.entityId < $1.entityId }
            for rule in rules { apply(rule, to: &result, device: device) }
        }
    }

    /// One rule against one device's entities, already sorted by entity id.
    ///
    /// Only ever writes `.companion`, and only over `.primary` — see `DeviceCurationRule` for why
    /// that is the whole safety argument.
    private static func apply(_ rule: DeviceCurationRule,
                              to result: inout [String: CurationTier],
                              device: [EntityRegistryEntry]) {
        func isPrimary(_ entry: EntityRegistryEntry) -> Bool { result[entry.entityId] == .primary }
        func demote(_ entry: EntityRegistryEntry) { result[entry.entityId] = .companion }

        switch rule {
        case .container(let domain):
            // Gated on the container actually being *shown*. If the camera was hidden in HA, this
            // device has no tile to be a part of, and taking the speaker away as well would leave
            // the user with nothing for a device they hid one entity of.
            guard device.contains(where: { isPrimary($0) && Domain.serviceDomain(of: $0.entityId) == domain })
            else { return }
            for entry in device where isPrimary(entry)
                && Domain.serviceDomain(of: entry.entityId) != domain {
                demote(entry)
            }

        case .singlePrimary(let platform, let preferring):
            guard device.allSatisfy({ $0.platform == platform }) else { return }
            let candidates = device.filter(isPrimary)
            guard candidates.count > 1 else { return }
            // Earliest domain in `preferring` wins; `preferring.count` parks anything unlisted
            // behind all of them. `device` is already sorted by entity id, and `min(by:)` keeps the
            // first of equal ranks, so the tie-break is the lowest id.
            func rank(_ entry: EntityRegistryEntry) -> Int {
                preferring.firstIndex(of: Domain.serviceDomain(of: entry.entityId)) ?? preferring.count
            }
            guard let winner = candidates.min(by: { rank($0) < rank($1) }) else { return }
            for entry in candidates where entry.entityId != winner.entityId { demote(entry) }
        }
    }

    private static func isCompanionSuffix(_ entityId: String) -> Bool {
        guard let dot = entityId.firstIndex(of: ".") else { return false }
        let object = String(entityId[entityId.index(after: dot)...])
        return companionSuffixes.contains { object == $0 || object.hasSuffix("_" + $0) }
    }
}
