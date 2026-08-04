/// One thing a room shows.
///
/// **A device, not an entity** — most devices are one entity and arrive as `.entity`, which is why
/// that case carries no type: a light's device id *is* its entity id, and every stored name, size,
/// membership and order keyed on that id keeps working untouched.
///
/// `.composite` is the rest: a garage door and its limit sensors, a shade group and its followers.
/// It carries a stable stored id rather than one derived from its inputs — deriving it would orphan
/// the device's own name and size the moment somebody added a shade to the group.
public enum DeviceRef: Sendable, Equatable, Identifiable {
    case entity(String)
    case composite(id: String, type: String, inputs: [DeviceRole: [String]])

    public var id: String {
        switch self {
        case .entity(let e): return e
        case .composite(let id, _, _): return id
        }
    }

    /// The entity this device's state is read from.
    ///
    /// For a composite that is its `primary` role — a shade group's master, whose position the tile
    /// shows and towards which every follower converges after a command.
    public var primaryEntityId: String? {
        switch self {
        case .entity(let e): return e
        case .composite(_, _, let inputs): return inputs[.primary]?.first
        }
    }

    /// Every entity this device consumes, in any role. What a room removes from its own tiles, so a
    /// shade group and its three shades are one tile rather than four.
    public var entityIds: [String] {
        switch self {
        case .entity(let e): return [e]
        case .composite(_, _, let inputs): return inputs.values.flatMap { $0 }
        }
    }
}
