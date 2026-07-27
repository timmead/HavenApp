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
