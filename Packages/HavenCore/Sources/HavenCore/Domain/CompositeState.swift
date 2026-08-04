import Foundation

/// One device's state, as the compound of its entities.
///
/// **The value every surface reads, and no surface computes.** A device's state being more than one
/// entity's state is a fact about the device — a lock says *locked*, and whether the door is
/// actually shut is a different entity — so it is resolved once, here. A modal renders all of it, a
/// tile renders the part that fits, and the two cannot disagree because neither decides.
///
/// Built the other way round, as a section inside a modal, hoisting it to the tile would have meant
/// writing "is this door actually shut" a second time. Two answers to that question is exactly the
/// class of disagreement `TileState` exists to end.
public struct DeviceState: Sendable, Equatable {
    /// The entity a surface is rendering — the one with the controls.
    public let primary: String
    /// Supporting readings, most contextually important first. See `CompositeState.rank`.
    public let readings: [DeviceReading]

    public init(primary: String, readings: [DeviceReading]) {
        self.primary = primary
        self.readings = readings
    }
}

/// One companion entity, as something to read.
public struct DeviceReading: Sendable, Equatable, Identifiable {
    public let entityId: String
    /// What this reading is *of* — the companion's own display name.
    public let label: String
    /// What it currently says: "Closed", "Detected", "88 %".
    public let value: String
    /// Whether it is in its notable state, for tint.
    ///
    /// `nil` where the notion does not apply: a battery percentage is not "active", and colouring
    /// one as though it were would invent an alarm out of a number.
    public let isActive: Bool?

    public var id: String { entityId }

    public init(entityId: String, label: String, value: String, isActive: Bool?) {
        self.entityId = entityId
        self.label = label
        self.value = value
        self.isActive = isActive
    }
}

public enum CompositeState {
    /// A primary entity and the companions belonging to the same physical device.
    ///
    /// A companion is an entity sharing the primary's registry `device_id` whose curation tier is
    /// `.companion` — both facts Haven already has. `EntityCuration`'s `container(domain:)` rule is
    /// what produces that tier, and until now no surface rendered it at all.
    ///
    /// An entity moved to another area in Home Assistant is `.primary` there and so is not a
    /// companion anywhere — HA's configuration outranking the heuristic, with no special case here
    /// to say so.
    ///
    /// - Parameter deviceId: the primary's own `device_id`, or `nil`. **`nil` matches nothing.**
    ///   Many integrations create entities without a device, and comparing two optionals with `==`
    ///   would make every one of them a companion of every other — the same trap
    ///   `CameraEvents.related` documents on its own strong rung.
    /// - Parameter excluding: entities the caller's own view already renders. A camera's motion
    ///   sensors are chips in `CameraModal`; listing them again as readings is one fact twice. This
    ///   is a parameter rather than a rule in here because which view draws what is a *rendering*
    ///   fact, not a fact about the device.
    public static func resolve(primary: String, deviceId: String?,
                               registry: [String: EntityRegistryInfo],
                               tiers: [String: CurationTier],
                               states: [String: EntityState],
                               excluding: Set<String> = []) -> DeviceState {
        guard let deviceId, !deviceId.isEmpty else {
            return DeviceState(primary: primary, readings: [])
        }
        let companions = registry.keys.filter { id in
            id != primary
                && !excluding.contains(id)
                && registry[id]?.deviceId == deviceId
                && tiers[id] == .companion
        }
        let readings = companions
            .map { reading($0, states[$0]) }
            .sorted { lhs, rhs in
                let l = rank(lhs.entityId), r = rank(rhs.entityId)
                return l == r ? lhs.entityId < rhs.entityId : l < r
            }
        return DeviceState(primary: primary, readings: readings)
    }

    /// **The ordering contract, and it is a contract rather than a rendering choice.**
    ///
    /// A tile will show only `readings.first`, so the first has to be the reading that qualifies the
    /// device's own state — the door sensor beside a lock, not its battery. Deciding that here is
    /// what stops a tile and a modal disagreeing about which companion matters.
    ///
    /// Binary sensors first because they answer the question the primary raises — *is it actually
    /// shut* — and numeric sensors second because a percentage is background. Ties break on entity
    /// id, so a home renders identically on every launch.
    static func rank(_ entityId: String) -> Int {
        switch Domain.of(entityId) {
        case .binarySensor: return 0
        case .sensor: return 1
        default: return 2
        }
    }

    /// One companion, read.
    ///
    /// **The words are `TileState`'s.** A door companion reads *Closed*, not *Off*; a smoke detector
    /// has *Detected*. A second vocabulary for the same states is how "Open" and "Opened" end up on
    /// one screen.
    ///
    /// An unreachable companion reads *Unavailable* rather than being dropped: an offline door
    /// sensor and an absent one looking identical is the opposite of telling the user what the
    /// device knows.
    static func reading(_ entityId: String, _ state: EntityState?) -> DeviceReading {
        let label = DisplayName.resolve(override: nil,
                                        friendlyName: state?.attributes["friendly_name"]?.asString,
                                        entityId: entityId)
        guard let state, !state.isUnavailable else {
            return DeviceReading(entityId: entityId, label: label,
                                 value: TileState.unavailable.word, isActive: nil)
        }
        if Domain.of(entityId) == .binarySensor {
            let active = state.state == "on"
            let face = TileState.binarySensor(deviceClass: state.deviceClass, isActive: active)
            return DeviceReading(entityId: entityId, label: label, value: face.word,
                                 isActive: active)
        }
        let sensor = SensorState(state)
        let value = [sensor.value, sensor.unit].compactMap { $0 }.joined(separator: " ")
        return DeviceReading(entityId: entityId, label: label, value: value, isActive: nil)
    }
}
