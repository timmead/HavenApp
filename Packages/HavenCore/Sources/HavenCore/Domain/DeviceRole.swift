import Foundation

/// What a companion entity *is*, to the device it belongs to.
///
/// A garage door reports open or closed; two limit sensors report *fully* open and *fully* closed,
/// and between them describe a third state the cover entity cannot — partly open. Haven cannot tell
/// which sensor is which by looking, so the household says.
///
/// **Bound rather than guessed, and the reason is failure mode.** Matching entity names for "fully
/// open" was the alternative: integrations name these every way there is, and a heuristic that
/// misses fails *silently* — no refinement, nothing saying why, and a user comparing their entity
/// names against a rule they cannot see.
public enum DeviceRole: String, Sendable, Equatable, CaseIterable {
    /// The entity a device's state is read from. **Every type has exactly one**, which is what lets
    /// `DeviceState.primary` mean the same thing for a light, a garage door and a shade group: a
    /// group's primary is the master shade the household nominated, and a light's is itself.
    case primary = "primary"
    case openLimit = "open_limit"
    case closedLimit = "closed_limit"
    /// A device that receives the primary's commands without supplying any state — a shade group's
    /// followers.
    ///
    /// **Commanded, not read.** Reconciling several positions produces a number no shade is actually
    /// at: three at 40%, 60% and 100% average to 67%, which none of them holds and no action would
    /// produce. The master's position is honest and converges after any group command.
    case follower = "follower"

    /// The label a configuration sheet shows for this role.
    public var label: String {
        switch self {
        case .primary: return "Main device"
        case .openLimit: return "Fully open sensor"
        case .closedLimit: return "Fully closed sensor"
        case .follower: return "Also control"
        }
    }

}

/// How many entities a role holds.
public enum Cardinality: Sendable, Equatable {
    case one, many
}

/// One role on one type: which entities may fill it, how many, and whether the device can exist
/// without it.
public struct DeviceTypeRole: Sendable, Equatable {
    public let role: DeviceRole
    /// The domains an entity must be in to fill this role. Empty means any.
    public let domains: [Domain]
    public let cardinality: Cardinality
    /// A role the device cannot be without. A garage door needs its cover; its limit sensors are
    /// what make it *better*, not what make it exist.
    public let isRequired: Bool

    public init(role: DeviceRole, domains: [Domain] = [], cardinality: Cardinality = .one,
                isRequired: Bool = false) {
        self.role = role
        self.domains = domains
        self.cardinality = cardinality
        self.isRequired = isRequired
    }

    public func accepts(_ entityId: String) -> Bool {
        domains.isEmpty || domains.contains(Domain.of(entityId))
    }
}

/// What kind of thing a device is, and therefore what renders it.
public struct DeviceType: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let roles: [DeviceTypeRole]

    public init(id: String, name: String, roles: [DeviceTypeRole]) {
        self.id = id
        self.name = name
        self.roles = roles
    }

    public var primaryRole: DeviceTypeRole? { roles.first { $0.role == .primary } }

    /// Whether this entity could be the primary of a device of this type.
    public func acceptsAsPrimary(_ entityId: String) -> Bool {
        primaryRole?.accepts(entityId) ?? false
    }
}
