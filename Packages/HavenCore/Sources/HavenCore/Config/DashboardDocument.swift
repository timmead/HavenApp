import Foundation

/// Haven's dashboard definition: the thin configuration layer that sits on top of Home Assistant
/// without duplicating it.
///
/// Home Assistant remains the source of truth for every device and entity, its readings, and which
/// area and floor it lives in. What this document holds is only what HA has no opinion about —
/// today, which of a room's several temperature sources is *the* room's; later, tile positions,
/// labels and composite-device definitions.
///
/// Stored in the `havenapp` integration under scope `shared`, key `dashboard`. The integration
/// stores it and never parses it (subproject B design, §Category B), so the schema and every
/// migration of it belong here.
///
/// ## Why this wraps raw JSON instead of being a `Codable` struct
///
/// This is a **shared** document that newer app builds will extend. If this build decoded it into a
/// struct of the fields it knows and re-encoded that struct on write, every key it didn't know
/// about would be silently deleted — so an older phone in the household would strip a newer phone's
/// dashboard on its next routine write, and the loss would be invisible until someone noticed their
/// layout had reverted.
///
/// So the document is kept as raw `JSONValue` throughout, and `merging(_:)` rewrites *only* the
/// subtree it owns. Everything else is carried through untouched, including keys this build has
/// never heard of. That property is what `DashboardDocumentTests` exists to defend.
public struct DashboardDocument: Sendable, Equatable {
    /// The schema this build writes and understands.
    public static let schema = 1

    private static let schemaKey = "schema"
    private static let roomsKey = "rooms"
    private static let entitiesKey = "entities"
    private static let nameKey = "name"
    private static let surfacesKey = "surfaces"
    private static let stateStyleKey = "state_style"
    private static let devicesKey = "devices"
    private static let orderKey = "order"

    public let raw: JSONValue

    /// Wraps an existing payload, or mints an empty document when there is none yet.
    public init(raw: JSONValue? = nil) {
        if let raw, raw.asObject != nil {
            self.raw = raw
        } else {
            // Also the fallback for a payload that isn't a JSON object at all. Replacing such a
            // payload is safe in a way that replacing an *unknown but well-formed* one is not:
            // nothing this project has ever written is a non-object, so there is no version of
            // Haven whose data is being discarded here.
            self.raw = .object([Self.schemaKey: .int(Self.schema)])
        }
    }

    /// The document's declared schema, defaulting to this build's when absent (an early document
    /// written before the field existed is this build's own).
    public var declaredSchema: Int { raw.asObject?[Self.schemaKey]?.asInt ?? Self.schema }

    /// False when the document was written by a newer build than this one.
    ///
    /// A newer schema is readable-at-your-own-risk but never writable: this build cannot know what
    /// invariants the newer one relies on, and `merging(_:)`'s key-preserving discipline protects
    /// unknown *keys*, not unknown *semantics*. Same discipline `HavenIntegrationStatus` already
    /// applies to the integration's own `schemaVersion`.
    public var isWritable: Bool { declaredSchema <= Self.schema }

    /// The stored nomination for every room that has one, keyed by area id.
    ///
    /// Rooms with no entry, and entries that don't parse, are simply absent — a malformed room
    /// falls back to being proposed afresh rather than taking the whole document down with it.
    public var nominations: [String: RoomEnvironmentOverride] {
        guard let rooms = raw.asObject?[Self.roomsKey]?.asObject else { return [:] }
        return rooms.compactMapValues { room in
            guard let o = room.asObject else { return nil }
            let override = RoomEnvironmentOverride(
                temperature: Self.decodeSensor(o[UpliftedSensor.Role.temperature.rawValue],
                                               role: .temperature),
                humidity: Self.decodeSensor(o[UpliftedSensor.Role.humidity.rawValue],
                                            role: .humidity))
            return override.isEmpty ? nil : override
        }
    }

    /// This document with `nominations` written into it, and **everything else left exactly as it
    /// was** — unknown top-level keys, unknown keys inside each room, and rooms not mentioned here.
    ///
    /// Merges rather than replaces at every level for the reason in the type's doc comment. A room
    /// present in `nominations` has its `temperature`/`humidity` keys overwritten and its other
    /// keys (tile positions, labels, whatever a later build adds) preserved.
    public func merging(_ nominations: [String: RoomEnvironmentOverride]) -> DashboardDocument {
        guard !nominations.isEmpty else { return self }
        var root = raw.asObject ?? [:]
        root[Self.schemaKey] = .int(max(declaredSchema, Self.schema))
        var rooms = root[Self.roomsKey]?.asObject ?? [:]
        for (areaId, override) in nominations {
            var room = rooms[areaId]?.asObject ?? [:]
            for role in [UpliftedSensor.Role.temperature, .humidity] {
                guard let sensor = override[role] else { continue }
                room[role.rawValue] = Self.encodeSensor(sensor)
            }
            rooms[areaId] = .object(room)
        }
        root[Self.roomsKey] = .object(rooms)
        return DashboardDocument(raw: .object(root))
    }

    // MARK: - Display names

    /// Haven's own display names, keyed by entity id.
    ///
    /// At the document root rather than under a room, deliberately: an entity's name does not depend
    /// on which room it is in, and moving a device between areas in Home Assistant must not silently
    /// lose the name a user gave it.
    ///
    /// Blank stored names are dropped on the way out as well as refused on the way in — a document
    /// written by hand, or by a build with a different idea of blankness, must not produce a nameless
    /// tile. `DisplayName` applies the same rule at the point of use.
    public var displayNames: [String: String] {
        guard let entities = raw.asObject?[Self.entitiesKey]?.asObject else { return [:] }
        return entities.compactMapValues { entity in
            guard let name = entity.asObject?[Self.nameKey]?.asString,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return name
        }
    }

    /// This document with one entity's display name set, or — for a `nil` or blank name — removed.
    ///
    /// One entity at a time rather than a bulk merge, because that is how the feature works: a
    /// rename sheet edits one device. It merges at every level for the reason in the type's doc
    /// comment, so an entity's other keys (an icon, a tile size, whatever a later build adds) survive
    /// a rename, and clearing a name removes only that key rather than the entity's whole record.
    public func settingDisplayName(_ name: String?, for entityId: String) -> DashboardDocument {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        var root = raw.asObject ?? [:]
        root[Self.schemaKey] = .int(max(declaredSchema, Self.schema))
        var entities = root[Self.entitiesKey]?.asObject ?? [:]
        var entity = entities[entityId]?.asObject ?? [:]
        if let trimmed, !trimmed.isEmpty {
            entity[Self.nameKey] = .string(trimmed)
        } else {
            entity.removeValue(forKey: Self.nameKey)
        }
        // An entity record holding nothing at all is removed outright, so clearing the only name a
        // device ever had leaves the document exactly as it started rather than a shell keyed by
        // every entity anyone has ever opened.
        if entity.isEmpty {
            entities.removeValue(forKey: entityId)
        } else {
            entities[entityId] = .object(entity)
        }
        if entities.isEmpty {
            root.removeValue(forKey: Self.entitiesKey)
        } else {
            root[Self.entitiesKey] = .object(entities)
        }
        return DashboardDocument(raw: .object(root))
    }

    // MARK: - Tile order

    /// Every order this room has been arranged into, keyed by the surface it was arranged on.
    ///
    /// **One list per surface** — design decision 9. It was a single array, and that could not
    /// survive two arrangeable surfaces: a drag persists only the ids visible where it happened, so
    /// an overview drag wrote a list with no room-detail-only tile in it and silently reset every
    /// one of their positions.
    ///
    /// Stored under the room rather than per entity, because an order is a fact about the *room* —
    /// the same reason the temperature and humidity nominations live here.
    ///
    /// **A document still carrying the old array shape reads as unset**, here, by falling out of
    /// `asObject`. Nothing migrates: nothing has shipped, and a development document that reverts to
    /// the default order once is a smaller cost than a migration nobody will ever need again.
    /// Unknown surface keys are dropped rather than defaulted, exactly as `surfaceOverrides` drops
    /// what it cannot read.
    public func orders(forRoom areaId: String) -> [HavenSurface: [String]] {
        guard let room = raw.asObject?[Self.roomsKey]?.asObject?[areaId]?.asObject,
              let bySurface = room[Self.orderKey]?.asObject else { return [:] }
        return bySurface.reduce(into: [:]) { out, pair in
            guard let surface = HavenSurface(rawValue: pair.key), let ids = pair.value.asArray
            else { return }
            out[surface] = ids.compactMap { $0.asString }
        }
    }

    /// The order this room's tiles were arranged into **on one surface**, or an empty list when that
    /// surface has never been arranged.
    ///
    /// Empty means *unset*, not *default*: what an unarranged surface actually renders is the other
    /// surface's arrangement, then the default — a fallback resolved at read time in
    /// `RoomSection.refs(for:)`, not here, because it is a fact about a room's contents rather than
    /// about the document.
    public func order(forRoom areaId: String, on surface: HavenSurface) -> [String] {
        orders(forRoom: areaId)[surface] ?? []
    }

    /// This document with one room's order **on one surface** set, or — for an empty list — cleared
    /// back to unset.
    ///
    /// Each surface's list is written whole rather than as a delta. A reorder is not something two
    /// people would want merged: concurrent rearrangements of one room should end with the last one
    /// winning, which is what `HavenConfig`'s version-conflict retry already provides.
    ///
    /// **The sibling surface's list is untouched**, which is the merge discipline every mutator here
    /// follows and is load-bearing rather than tidy: the two surfaces are arranged independently, so
    /// a write that replaced the whole `order` object would make arranging the dashboard silently
    /// discard the arrangement of the room you had opened. Pinned by
    /// `arrangingOneSurfaceLeavesTheOthersListAlone`.
    ///
    /// A surface key holding nothing is removed, and an `order` holding no surfaces is removed with
    /// it, so clearing both surfaces leaves no `"order": {}` husk behind for the room-record cleanup
    /// below to trip over.
    public func settingOrder(_ ids: [String], forRoom areaId: String,
                             on surface: HavenSurface) -> DashboardDocument {
        var root = raw.asObject ?? [:]
        root[Self.schemaKey] = .int(max(declaredSchema, Self.schema))
        var rooms = root[Self.roomsKey]?.asObject ?? [:]
        var room = rooms[areaId]?.asObject ?? [:]
        // `?? [:]` also swallows the legacy array shape, which is what "reads as unset" means on the
        // write side: the first arrangement after this change replaces it rather than merging into
        // something it cannot understand.
        var bySurface = room[Self.orderKey]?.asObject ?? [:]
        if ids.isEmpty {
            bySurface.removeValue(forKey: surface.rawValue)
        } else {
            bySurface[surface.rawValue] = .array(ids.map { .string($0) })
        }
        if bySurface.isEmpty {
            room.removeValue(forKey: Self.orderKey)
        } else {
            room[Self.orderKey] = .object(bySurface)
        }
        // A room record holding nothing is removed, so resetting an arrangement in a room with no
        // nominations leaves the document exactly as it started.
        if room.isEmpty {
            rooms.removeValue(forKey: areaId)
        } else {
            rooms[areaId] = .object(room)
        }
        if rooms.isEmpty {
            root.removeValue(forKey: Self.roomsKey)
        } else {
            root[Self.roomsKey] = .object(rooms)
        }
        return DashboardDocument(raw: .object(root))
    }

    // MARK: - How a two-state tile shows its state

    /// Whether each two-state device shows a glyph or a word, keyed by entity id.
    ///
    /// **Not per surface**, unlike a subsection's tile size (`subsections.<kind>.size`, see
    /// `SubsectionConfig.swift`). Size is about how much room a tile has, and the two surfaces
    /// genuinely differ; whether "Open" is easier to read than an open door is a fact about the
    /// reader, and it would be strange to answer it twice for the same device.
    public var tileStateStyles: [String: TileStateStyle] {
        guard let entities = raw.asObject?[Self.entitiesKey]?.asObject else { return [:] }
        return entities.compactMapValues { entity in
            entity.asObject?[Self.stateStyleKey]?.asString.flatMap(TileStateStyle.init(rawValue:))
        }
    }

    /// This document with one entity's state style set, or — for `nil` — cleared back to the default.
    public func settingStateStyle(_ style: TileStateStyle?, for entityId: String) -> DashboardDocument {
        var root = raw.asObject ?? [:]
        root[Self.schemaKey] = .int(max(declaredSchema, Self.schema))
        var entities = root[Self.entitiesKey]?.asObject ?? [:]
        var entity = entities[entityId]?.asObject ?? [:]
        if let style {
            entity[Self.stateStyleKey] = .string(style.rawValue)
        } else {
            entity.removeValue(forKey: Self.stateStyleKey)
        }
        if entity.isEmpty {
            entities.removeValue(forKey: entityId)
        } else {
            entities[entityId] = .object(entity)
        }
        if entities.isEmpty {
            root.removeValue(forKey: Self.entitiesKey)
        } else {
            root[Self.entitiesKey] = .object(entities)
        }
        return DashboardDocument(raw: .object(root))
    }

    // MARK: - Composite devices

    /// One stored composite: what it is, where it lives, and what it is made of.
    public struct StoredDevice: Sendable, Equatable {
        public let id: String
        public let type: String
        public let areaId: String
        public let inputs: [DeviceRole: [String]]

        public init(id: String, type: String, areaId: String, inputs: [DeviceRole: [String]]) {
            self.id = id; self.type = type; self.areaId = areaId; self.inputs = inputs
        }
    }

    /// Every composite the household has made, by id.
    ///
    /// **Only composites are stored.** A light's device is implied by the light existing, which is
    /// what keeps this key small and what keeps every setting already stored against an entity id
    /// working untouched.
    ///
    /// A record missing a type, an area or a primary is dropped rather than half-built: a device
    /// with no primary has no state to read, and rendering one would be a tile that cannot say
    /// anything.
    /// **Keyed by the device's primary entity, whatever key it was written under.**
    ///
    /// A device's id is its primary's entity id — the one rule that gives the app a single id space
    /// and lets a device change type without losing its name, size or place. An earlier build
    /// generated `haven:…` ids instead, and those records would otherwise be invisible for good:
    /// the room renders a ref by its primary, so a device stored under any other key is looked up
    /// and never found.
    ///
    /// Re-keying on read repairs them without a migration write. Where two records claim the same
    /// primary — a straggler and the record that replaced it — **the one stored under the right key
    /// wins**, so a household that re-made a device gets the new one rather than the ghost.
    ///
    /// That comparison is on the *stored key*, and getting it wrong is what made a bound sensor
    /// appear not to persist: an earlier version compared the id it had just constructed, which is
    /// the primary in every case, so the test was always true and whichever record sorted first
    /// won. `haven:…` sorts before `switch.…`, so the ghost beat the real device every time and the
    /// freshly written binding was discarded on the next read.
    public var devices: [String: StoredDevice] {
        guard let stored = raw.asObject?[Self.devicesKey]?.asObject else { return [:] }
        var out: [String: StoredDevice] = [:]
        /// The key each winning record was actually stored under.
        var wonWithKey: [String: String] = [:]
        for (id, value) in stored.sorted(by: { $0.key < $1.key }) {
            guard let o = value.asObject,
                  let type = o["type"]?.asString, !type.isEmpty,
                  let areaId = o["area"]?.asString, !areaId.isEmpty,
                  let rawInputs = o["inputs"]?.asObject else { continue }
            var inputs: [DeviceRole: [String]] = [:]
            for (rawRole, rawIds) in rawInputs {
                guard let role = DeviceRole(rawValue: rawRole) else { continue }
                let ids = (rawIds.asArray ?? []).compactMap { $0.asString }.filter { !$0.isEmpty }
                if !ids.isEmpty { inputs[role] = ids }
            }
            guard let primary = inputs[.primary]?.first else { continue }
            // A record already stored under the right key is the real one; nothing displaces it.
            if wonWithKey[primary] == primary { continue }
            wonWithKey[primary] = id
            out[primary] = StoredDevice(id: primary, type: type, areaId: areaId, inputs: inputs)
        }
        return out
    }

    /// This document with one composite stored, or — for `nil` — removed.
    public func settingDevice(_ device: StoredDevice?, id: String) -> DashboardDocument {
        var root = raw.asObject ?? [:]
        root[Self.schemaKey] = .int(max(declaredSchema, Self.schema))
        var stored = root[Self.devicesKey]?.asObject ?? [:]
        if let device {
            var inputs: [String: JSONValue] = [:]
            for (role, ids) in device.inputs where !ids.isEmpty {
                inputs[role.rawValue] = .array(ids.map { .string($0) })
            }
            stored[id] = .object(["type": .string(device.type),
                                  "area": .string(device.areaId),
                                  "inputs": .object(inputs)])
        } else {
            stored.removeValue(forKey: id)
        }
        if stored.isEmpty {
            root.removeValue(forKey: Self.devicesKey)
        } else {
            root[Self.devicesKey] = .object(stored)
        }
        return DashboardDocument(raw: .object(root))
    }

    // MARK: - Surface membership

    /// Every user decision about which surfaces show which entity, keyed by entity id.
    ///
    /// Unknown surfaces and unknown membership values are dropped rather than defaulted: a build
    /// that adds a third surface, or a fourth membership state, must leave this one working rather
    /// than brick it on a value it cannot read.
    public var surfaceOverrides: [String: [HavenSurface: SurfaceMembership]] {
        guard let entities = raw.asObject?[Self.entitiesKey]?.asObject else { return [:] }
        return entities.compactMapValues { entity -> [HavenSurface: SurfaceMembership]? in
            guard let surfaces = entity.asObject?[Self.surfacesKey]?.asObject else { return nil }
            var out: [HavenSurface: SurfaceMembership] = [:]
            for (rawSurface, rawMembership) in surfaces {
                guard let surface = HavenSurface(rawValue: rawSurface),
                      let value = rawMembership.asString,
                      let membership = SurfaceMembership(rawValue: value) else { continue }
                out[surface] = membership
            }
            return out.isEmpty ? nil : out
        }
    }

    /// This document with one entity's membership of one surface set, or — for `nil` — cleared back
    /// to following curation.
    ///
    /// One entity and one surface at a time, because that is how the feature works: a tap removes a
    /// tile from the surface it was on. Merging at every level so a rename survives a removal and
    /// vice versa, and so clearing the last membership leaves no residue — see the tests.
    public func settingMembership(_ membership: SurfaceMembership?, for entityId: String,
                                  on surface: HavenSurface) -> DashboardDocument {
        var root = raw.asObject ?? [:]
        root[Self.schemaKey] = .int(max(declaredSchema, Self.schema))
        var entities = root[Self.entitiesKey]?.asObject ?? [:]
        var entity = entities[entityId]?.asObject ?? [:]
        var surfaces = entity[Self.surfacesKey]?.asObject ?? [:]
        if let membership {
            surfaces[surface.rawValue] = .string(membership.rawValue)
        } else {
            surfaces.removeValue(forKey: surface.rawValue)
        }
        if surfaces.isEmpty {
            entity.removeValue(forKey: Self.surfacesKey)
        } else {
            entity[Self.surfacesKey] = .object(surfaces)
        }
        if entity.isEmpty {
            entities.removeValue(forKey: entityId)
        } else {
            entities[entityId] = .object(entity)
        }
        if entities.isEmpty {
            root.removeValue(forKey: Self.entitiesKey)
        } else {
            root[Self.entitiesKey] = .object(entities)
        }
        return DashboardDocument(raw: .object(root))
    }

    // MARK: - One nomination's wire shape

    private static let entityIdKey = "entity_id"
    private static let sourceKey = "source"
    private static let attributeKey = "attribute"
    private static let sourceState = "state"
    private static let sourceAttribute = "attribute"

    private static func decodeSensor(_ value: JSONValue?, role: UpliftedSensor.Role) -> UpliftedSensor? {
        guard let o = value?.asObject, let entityId = o[entityIdKey]?.asString else { return nil }
        let source: UpliftedSensor.Source
        switch o[sourceKey]?.asString {
        case sourceAttribute:
            // An attribute source with no attribute name is meaningless — there is nothing to read.
            // Dropping it re-proposes the room, which is recoverable; inventing a name would
            // manufacture a permanent "—".
            guard let name = o[attributeKey]?.asString else { return nil }
            source = .attribute(name)
        case sourceState, nil:
            // `nil` covers a document written before `source` existed; those were all state reads.
            source = .state
        default:
            return nil
        }
        return UpliftedSensor(role: role, entityId: entityId, source: source)
    }

    private static func encodeSensor(_ sensor: UpliftedSensor) -> JSONValue {
        switch sensor.source {
        case .state:
            return .object([entityIdKey: .string(sensor.entityId), sourceKey: .string(sourceState)])
        case .attribute(let name):
            return .object([entityIdKey: .string(sensor.entityId),
                            sourceKey: .string(sourceAttribute),
                            attributeKey: .string(name)])
        }
    }
}
