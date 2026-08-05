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
    /// The device's state once its bound roles are read.
    ///
    /// **`nil` when nothing refines it**, which is the common case: a surface falls back to the
    /// primary entity's own state, so a device with no bindings renders exactly as it did before
    /// any of this existed.
    public let face: TileState?
    /// Whether the derived state is the notable one, for tint — nil when nothing is derived.
    ///
    /// **It travels with the face because the two must agree.** A relay opener is a `switch`, and a
    /// tile that took its tint from the switch showed a part-open door greyed out as though it were
    /// off: the relay's own state says a contact closed, not where the door is.
    public let isActive: Bool?
    /// Supporting readings, most contextually important first. See `CompositeState.rank`.
    ///
    /// An entity consumed by `face` is **not** also listed here. "Partly open" over "Fully Open —
    /// Off, Fully Closed — Off" is one fact three times, and the third is the one people read.
    public let readings: [DeviceReading]

    public init(primary: String, face: TileState? = nil, isActive: Bool? = nil,
                readings: [DeviceReading]) {
        self.primary = primary
        self.face = face
        self.isActive = isActive
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
    /// - Parameter bindings: which companion plays which role — see `DeviceRole`. A bound entity is
    ///   read into `face` and drops out of `readings`.
    /// - Parameter type: what kind of device this is. **What derives a face is the type, not the
    ///   primary's domain** — a garage door opener is a `switch` as often as it is a `cover`, and
    ///   keying on the domain silently refused to derive anything for the switch case.
    public static func resolve(primary: String, deviceId: String?,
                               registry: [String: EntityRegistryInfo],
                               tiers: [String: CurationTier],
                               states: [String: EntityState],
                               type: DeviceType? = nil,
                               bindings: [DeviceRole: String] = [:],
                               excluding: Set<String> = []) -> DeviceState {
        // **The tint comes back with the face rather than being read off its word.** It used to be
        // `word != "Closed"`, which is a string comparison standing in for a decision the derivation
        // had already made — and one that would have silently started lying the moment a word
        // changed, which "Not closed" would have done.
        let derivedState = derived(primary: primary, type: type, bindings: bindings, states: states)
        let face = derivedState?.face
        let isActive = derivedState?.isActive
        let bound = Set(bindings.values)
        guard let deviceId, !deviceId.isEmpty else {
            return DeviceState(primary: primary, face: face, isActive: isActive, readings: [])
        }
        let companions = registry.keys.filter { id in
            id != primary
                && !excluding.contains(id)
                && !bound.contains(id)
                && registry[id]?.deviceId == deviceId
                && tiers[id] == .companion
        }
        let readings = companions
            .map { reading($0, states[$0]) }
            .sorted { lhs, rhs in
                let l = rank(lhs.entityId), r = rank(rhs.entityId)
                return l == r ? lhs.entityId < rhs.entityId : l < r
            }
        return DeviceState(primary: primary, face: face, isActive: isActive, readings: readings)
    }

    /// The device's own state, derived from its bound roles — or `nil` when they cannot say.
    ///
    /// **A cover's limits express states the cover entity cannot.** `cover.garage` reports open or
    /// closed; a door stopped half way is neither, and a relay opener's own state says only that a
    /// contact closed. What the limits say is the real answer.
    ///
    /// **One limit is still worth having, and says less rather than nothing.** With only the fully
    /// open sensor, a door is *Open* or *Not open* — it cannot distinguish shut from half way, and
    /// claiming either would be inventing a reading. With only the fully closed sensor it is
    /// *Closed* or *Not closed*. Refusing to derive anything until both were bound was the first
    /// rule and it was needlessly strict: half the information is not none of it.
    ///
    /// **An unreachable limit counts as absent**, so a working pair-mate still answers what it can:
    /// a door whose closed sensor is offline and whose open sensor reads off is *Not open*, which is
    /// true whatever the offline one would have said. Both unreachable derives nothing.
    ///
    /// Both limits on is contradictory hardware, and resolves to **Closed** — a garage reported shut
    /// by its own closed sensor is the reading you act on.
    static func derived(primary: String, type: DeviceType?,
                        bindings: [DeviceRole: String],
                        states: [String: EntityState]) -> (face: TileState, isActive: Bool)? {
        guard type?.id == "garage_door" else { return nil }

        /// A bound limit that is actually reporting. Unreachable and unbound are the same thing
        /// here: neither can tell you where the door is.
        func limit(_ role: DeviceRole) -> Bool? {
            guard let id = bindings[role], let state = states[id], !state.isUnavailable else {
                return nil
            }
            return state.state == "on"
        }

        // A garage's glyphs, whatever the opener happens to be. A switch-primary opener has no cover
        // device class of its own, and rendering it as blinds would be a picture of the wrong object.
        let shut = TileState.cover(deviceClass: "garage", isOpen: false)
        let wide = TileState.cover(deviceClass: "garage", isOpen: true)
        func between(_ word: String) -> TileState {
            TileState(symbol: partlyOpenSymbol, word: word)
        }

        switch (limit(.closedLimit), limit(.openLimit)) {
        case (nil, nil):
            return nil
        case let (closed?, open?):
            if closed { return (shut, false) }
            if open { return (wide, true) }
            return (between("Partly open"), true)
        case let (closed?, nil):
            // Not closed covers both half way and fully open, and says so rather than guessing.
            return closed ? (shut, false) : (between("Not closed"), true)
        case let (nil, open?):
            return open ? (wide, true) : (between("Not open"), false)
        }
    }

    /// The glyph for a cover between its limits — one shape for every cover kind.
    ///
    /// **It has to differ from the open glyph, and the first version did not.** "The word carries the
    /// distinction" was the reasoning, which forgot that a tile set to the icon style shows no word:
    /// a garage standing half open and one standing fully open rendered identically, which is the
    /// one comparison this whole feature exists to make.
    ///
    /// `rectangle.tophalf.filled` — a shape half filled, which is what a door stopped part-way
    /// actually is, and which belongs to no cover family so it reads the same for a garage, a blind
    /// or a curtain.
    ///
    /// **Checked against the SDK rather than assumed.** The first attempt used
    /// `door.garage.double.1closed`, which does not exist on this SDK: `Image(systemName:)` renders
    /// *nothing* for a name it cannot resolve, so a garage standing half open drew an empty tile —
    /// a worse failure than the ambiguity it was fixing, and one no test would catch because the
    /// string is valid Swift either way.
    private static let partlyOpenSymbol = "rectangle.tophalf.filled"

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
