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
    case openLimit = "open_limit"
    case closedLimit = "closed_limit"

    /// The label a configuration sheet shows for this role.
    public var label: String {
        switch self {
        case .openLimit: return "Fully open sensor"
        case .closedLimit: return "Fully closed sensor"
        }
    }

    /// The roles worth binding for a domain, or none.
    ///
    /// **Two roles, because two are needed.** A lock's door contact is a real role — it would let
    /// Haven say "locked, but the door is open" — and it is deliberately absent: that is a second
    /// derivation with its own question about what the tile should then read, and inventing storage
    /// for it now would be designing against a device nobody has described.
    public static func roles(for domain: Domain) -> [DeviceRole] {
        switch domain {
        case .cover: return [.openLimit, .closedLimit]
        case .light, .switchOutlet, .lock, .climate, .mediaPlayer, .camera, .scene, .script,
             .button, .sensor, .binarySensor, .unknown: return []
        }
    }
}
