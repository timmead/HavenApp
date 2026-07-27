/// A reading uplifted out of a room's tile grid and into its heading, as a small pill.
///
/// Moved here from `HomeSection` when rooms stopped taking these solely from Home Assistant's area
/// registry: which sensor is *the* room's temperature is now a Haven configuration decision (see
/// `RoomEnvironmentResolver`), and this type is the vocabulary that decision is expressed in — on
/// the wire in the dashboard document, in the resolver, and in the future configuration picker.
public struct UpliftedSensor: Sendable, Equatable, Identifiable {
    public enum Role: String, Sendable, Hashable, Codable { case temperature, humidity }

    /// Where the reading is actually read from.
    ///
    /// Two forms rather than one because a great many rooms have a thermostat and no separate
    /// sensor: a `climate` entity carries the room's temperature in `current_temperature`, not in
    /// its state (which is `heat`/`cool`/`off`). Collapsing both to "an entity id" would either
    /// exclude those rooms or require every reader to re-derive which case it is holding.
    public enum Source: Sendable, Equatable {
        /// The entity's own state — an ordinary `sensor.*`.
        case state
        /// A named attribute on the entity, e.g. `current_temperature` on a `climate.*`.
        case attribute(String)
    }

    public let role: Role
    public let entityId: String
    public let source: Source

    public init(role: Role, entityId: String, source: Source) {
        self.role = role; self.entityId = entityId; self.source = source
    }

    /// Identity is the **role**, deliberately not the entity id: a thermostat-only room nominates
    /// the same `climate.*` entity for both temperature and humidity, so keying a `ForEach` on the
    /// entity id there yields two views with the same identity — SwiftUI drops one pill or thrashes
    /// view identity. A room has at most one sensor per role by construction, so role is unique.
    public var id: Role { role }
}

/// One room's nominated sources, as stored in the dashboard document.
///
/// Both fields are optional independently: a room may well have a temperature reading and no
/// humidity one.
public struct RoomEnvironmentOverride: Sendable, Equatable {
    public var temperature: UpliftedSensor?
    public var humidity: UpliftedSensor?

    public init(temperature: UpliftedSensor? = nil, humidity: UpliftedSensor? = nil) {
        self.temperature = temperature; self.humidity = humidity
    }

    public var isEmpty: Bool { temperature == nil && humidity == nil }

    public subscript(role: UpliftedSensor.Role) -> UpliftedSensor? {
        get { role == .temperature ? temperature : humidity }
        set { if role == .temperature { temperature = newValue } else { humidity = newValue } }
    }
}

/// One room's resolved environment: what its pills read from, and what else they *could* read from.
public struct RoomEnvironment: Sendable, Equatable {
    public var temperature: UpliftedSensor?
    public var humidity: UpliftedSensor?

    /// Every source in this room that could be nominated, in the same rank order the auto-pick
    /// uses.
    ///
    /// Public API rather than an implementation detail because enumerating a room's sources *is*
    /// the feature: the configuration flow needs a list to populate its picker from, and a
    /// resolver that only returned the winner would leave it with nothing to show.
    public var temperatureCandidates: [UpliftedSensor] = []
    public var humidityCandidates: [UpliftedSensor] = []

    /// Roles whose nomination was *proposed* here rather than read from the dashboard document —
    /// so, the ones worth writing back. A role is absent from this set when the document already
    /// nominated it, and when the proposal is not worth persisting yet (see the resolver).
    public var proposed: Set<UpliftedSensor.Role> = []

    public init(temperature: UpliftedSensor? = nil, humidity: UpliftedSensor? = nil,
                temperatureCandidates: [UpliftedSensor] = [], humidityCandidates: [UpliftedSensor] = [],
                proposed: Set<UpliftedSensor.Role> = []) {
        self.temperature = temperature; self.humidity = humidity
        self.temperatureCandidates = temperatureCandidates
        self.humidityCandidates = humidityCandidates
        self.proposed = proposed
    }

    public subscript(role: UpliftedSensor.Role) -> UpliftedSensor? {
        get { role == .temperature ? temperature : humidity }
        set { if role == .temperature { temperature = newValue } else { humidity = newValue } }
    }

    public func candidates(for role: UpliftedSensor.Role) -> [UpliftedSensor] {
        role == .temperature ? temperatureCandidates : humidityCandidates
    }

    /// The nominations this room wants written to the dashboard document, or nil if none.
    public var nominationsToPersist: RoomEnvironmentOverride? {
        var out = RoomEnvironmentOverride()
        for role in proposed { out[role] = self[role] }
        return out.isEmpty ? nil : out
    }

    /// What the room heading renders, in display order.
    public var headerSensors: [UpliftedSensor] { [temperature, humidity].compactMap { $0 } }
}

/// The per-entity facts candidacy needs that live in an entity's *state* rather than in the
/// registry.
///
/// They have to come from state because Home Assistant's `config/entity_registry/list` does not
/// carry them: it returns `EntityRegistryEntry.as_partial_dict`, which has no `device_class` and no
/// `original_device_class` (those appear only in `extended_dict`, used by `.../get`). Verified
/// against Home Assistant's source, not assumed — a resolver built on the registry field would find
/// zero candidates on every real home while every struct-literal test stayed green.
public struct RoomEnvironmentSource: Sendable, Equatable {
    public let deviceClass: String?
    public let hasCurrentTemperature: Bool
    public let hasCurrentHumidity: Bool

    public init(deviceClass: String?, hasCurrentTemperature: Bool = false,
                hasCurrentHumidity: Bool = false) {
        self.deviceClass = deviceClass
        self.hasCurrentTemperature = hasCurrentTemperature
        self.hasCurrentHumidity = hasCurrentHumidity
    }

    /// Reads the three facts off a live entity state.
    public init(_ state: EntityState) {
        self.deviceClass = state.deviceClass
        self.hasCurrentTemperature = state.attributes["current_temperature"]?.asDouble != nil
        self.hasCurrentHumidity = state.attributes["current_humidity"]?.asDouble != nil
    }
}

/// Decides which entity is *the* temperature (and humidity) of each room.
///
/// Home Assistant is the source of truth for what entities exist and which room they are in; this
/// decides only the one thing HA has no opinion about — which of a room's several thermometers the
/// room's own reading comes from. That decision is Haven configuration, stored in the dashboard
/// document, and this is what produces it.
public enum RoomEnvironmentResolver {
    /// Resolves every area in `home`.
    ///
    /// - Parameters:
    ///   - sources: per-entity facts from live state, keyed by entity id (see
    ///     `RoomEnvironmentSource`). Entities absent from this map are not candidates.
    ///   - stored: nominations already in the dashboard document, keyed by area id.
    ///   - isReadable: whether a proposed nomination currently yields a reading, and so whether it
    ///     is safe to *persist*. Defaults to always-true for callers that only want to render.
    ///     See the persistence note below for why this is not optional in practice.
    public static func resolve(
        home: ResolvedHome,
        sources: [String: RoomEnvironmentSource],
        stored: [String: RoomEnvironmentOverride] = [:],
        isReadable: (UpliftedSensor) -> Bool = { _ in true }
    ) -> [String: RoomEnvironment] {
        var out: [String: RoomEnvironment] = [:]
        for area in home.floors.flatMap(\.areas) {
            out[area.id] = resolve(area: area, sources: sources,
                                   stored: stored[area.id] ?? RoomEnvironmentOverride(),
                                   isReadable: isReadable)
        }
        return out
    }

    private static func resolve(area: ResolvedArea, sources: [String: RoomEnvironmentSource],
                                stored: RoomEnvironmentOverride,
                                isReadable: (UpliftedSensor) -> Bool) -> RoomEnvironment {
        var env = RoomEnvironment()
        env.temperatureCandidates = candidates(role: .temperature, area: area, sources: sources)
        env.humidityCandidates = candidates(role: .humidity, area: area, sources: sources)

        for role in [UpliftedSensor.Role.temperature, .humidity] {
            // 1. The dashboard document. Authoritative, full stop — used even when the entity is
            //    no longer in the area, no longer a candidate, or never was one. A user who
            //    deliberately nominates a diagnostic sensor must not have it quietly overruled by
            //    a heuristic, and a nomination whose entity has vanished renders "—" rather than
            //    silently becoming a different physical device (see `EnvironmentReading.display`).
            if let nomination = stored[role] {
                env[role] = nomination
                continue
            }
            // 2. What the user said in Home Assistant itself, via the area registry. An explicit
            //    human statement, so taken as-is with no filtering.
            // 3. Otherwise the top-ranked candidate.
            let registry = registryNomination(role: role, area: area)
            guard let proposal = registry ?? env.candidates(for: role).first else { continue }
            env[role] = proposal

            // Rendering a proposal is free; *writing* one is a decision that sticks, because rung 1
            // never re-picks. Candidacy reads `device_class` from live state, and an unavailable
            // entity arrives with its attributes stripped — so a launch that happens to catch the
            // room's real sensor offline would resolve a different one and persist it permanently,
            // with no in-app repair path until the configuration UX exists. Deferring the write to
            // a launch where the pick is actually readable costs one launch; getting it wrong costs
            // the user a wrong pill indefinitely.
            if isReadable(proposal) { env.proposed.insert(role) }
        }
        return env
    }

    /// Home Assistant's own `temperature_entity_id` / `humidity_entity_id` for the area. Present on
    /// `config/area_registry/list` (verified against `AreaEntry.json_fragment`), but rarely set —
    /// which is exactly why the auto-pick below exists.
    private static func registryNomination(role: UpliftedSensor.Role,
                                           area: ResolvedArea) -> UpliftedSensor? {
        let entityId = role == .temperature ? area.temperatureEntityId : area.humidityEntityId
        return entityId.map { UpliftedSensor(role: role, entityId: $0, source: .state) }
    }

    /// Every entity in the area that could serve as this room's reading, best first.
    ///
    /// Ordered `sensor.*` before `climate.*`: a dedicated thermometer measures the room, whereas a
    /// thermostat measures wherever the thermostat is — usually a hallway. Within each group,
    /// ascending entity id. That tiebreak is arbitrary but it must be *deterministic*: the winner
    /// is about to be written into shared household configuration, and a pick that varied by device
    /// or by launch would have two phones overwriting each other's choice forever.
    private static func candidates(role: UpliftedSensor.Role, area: ResolvedArea,
                                   sources: [String: RoomEnvironmentSource]) -> [UpliftedSensor] {
        let deviceClass = role == .temperature ? "temperature" : "humidity"
        let attribute = role == .temperature ? "current_temperature" : "current_humidity"

        var sensors: [UpliftedSensor] = []
        var thermostats: [UpliftedSensor] = []
        for entityId in area.entityIds {
            guard let source = sources[entityId] else { continue }
            switch Domain.of(entityId) {
            case .sensor:
                // Curation's tiers do real work here rather than being a nicety: Zigbee and Z-Wave
                // devices routinely expose a `device_class: temperature` *diagnostic* reporting the
                // device's own internal temperature, and `EntityCuration` already marks those
                // `.hidden` via `entity_category`. Without this filter a room would nominate a
                // light bulb's die temperature as the room temperature — and then persist it.
                guard source.deviceClass == deviceClass,
                      area.tier(of: entityId) == .primary || area.tier(of: entityId) == .secondary
                else { continue }
                sensors.append(UpliftedSensor(role: role, entityId: entityId, source: .state))
            case .climate:
                guard role == .temperature ? source.hasCurrentTemperature : source.hasCurrentHumidity
                else { continue }
                thermostats.append(UpliftedSensor(role: role, entityId: entityId,
                                                  source: .attribute(attribute)))
            default:
                continue
            }
        }
        // `area.entityIds` is already sorted (`RegistryResolver`), but sorted explicitly here so the
        // determinism this relies on is a property of this function rather than of a caller.
        return sensors.sorted { $0.entityId < $1.entityId }
             + thermostats.sorted { $0.entityId < $1.entityId }
    }
}
