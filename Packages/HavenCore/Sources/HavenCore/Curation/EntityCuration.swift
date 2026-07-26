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
    static let primaryDomains: Set<String> = [
        "light", "switch", "input_boolean", "cover", "lock", "climate",
        "media_player", "scene", "script", "button", "input_button",
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
    public static func tiers(for entries: [EntityRegistryEntry]) -> [String: CurationTier] {
        var result = [String: CurationTier](minimumCapacity: entries.count)
        for entry in entries { result[entry.entityId] = tier(of: entry) }
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

    private static func isCompanionSuffix(_ entityId: String) -> Bool {
        guard let dot = entityId.firstIndex(of: ".") else { return false }
        let object = String(entityId[entityId.index(after: dot)...])
        return companionSuffixes.contains { object == $0 || object.hasSuffix("_" + $0) }
    }
}
