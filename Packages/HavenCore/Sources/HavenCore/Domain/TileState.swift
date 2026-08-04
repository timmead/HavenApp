import Foundation

/// How a two-state tile shows what it is doing.
public enum TileStateStyle: String, Sendable, Equatable, CaseIterable {
    /// A large glyph that differs between the two states — an open door against a closed one.
    case icon
    /// A word: "Open", "Locked", "Detected".
    case label
}

/// What a two-state device's current state looks like: the glyph that shows it, and the word for it.
///
/// **Both together, from one call, because they are one decision.** A door that reads "Open" must
/// not draw a closed door beside it, and keeping the two vocabularies in separate switches in
/// separate files is how that happens. `TileStateStyle` picks which one is shown; this decides what
/// each of them says.
///
/// In HavenCore rather than in the tiles because it is a table with rules in it — Home Assistant's
/// device classes name a *kind* of thing, and what "on" means differs completely between them: a
/// door is open, a smoke detector has detected something, a moisture sensor is wet. Four tiles were
/// otherwise going to grow four copies of that judgement.
public struct TileState: Sendable, Equatable {
    public let symbol: String
    public let word: String

    public init(symbol: String, word: String) {
        self.symbol = symbol
        self.word = word
    }

    /// What every domain shows when the device cannot be reached.
    ///
    /// **`questionmark.circle`, and never the domain's own glyph.** `LockTile` records why in full:
    /// `isLocked` reads false for an unreachable lock exactly as it would for an open one, so the
    /// domain glyph would state confidently that a door is unlocked when Haven knows nothing about
    /// it — and swapping it for the *locked* variant is worse still in a security context. One glyph
    /// that asserts neither is the only honest answer, and it belongs to every two-state tile rather
    /// than to the one that happened to think about it.
    public static let unavailable = TileState(symbol: "questionmark.circle", word: "Unavailable")

    /// A binary sensor's state, by what Home Assistant says it is a sensor *of*.
    ///
    /// The default pair deliberately does **not** vary its glyph. For an unrecognised device class
    /// Haven does not know what "on" means, and a picture that implies it does — an open door for a
    /// sensor that might be reporting vibration — is worse than one that stays put and lets the
    /// tint carry the state.
    public static func binarySensor(deviceClass: String?, isActive: Bool,
                                    unavailable: Bool = false) -> TileState {
        guard !unavailable else { return .unavailable }
        switch deviceClass {
        case "door", "garage_door":
            return isActive ? TileState(symbol: "door.left.hand.open", word: "Open")
                            : TileState(symbol: "door.left.hand.closed", word: "Closed")
        case "window", "opening":
            return isActive ? TileState(symbol: "window.vertical.open", word: "Open")
                            : TileState(symbol: "window.vertical.closed", word: "Closed")
        case "motion", "occupancy", "presence":
            return isActive ? TileState(symbol: "figure.walk.motion", word: "Motion")
                            : TileState(symbol: "figure.stand", word: "Clear")
        case "moisture":
            return isActive ? TileState(symbol: "drop.fill", word: "Wet")
                            : TileState(symbol: "drop", word: "Dry")
        case "smoke":
            return isActive ? TileState(symbol: "smoke.fill", word: "Detected")
                            : TileState(symbol: "smoke", word: "Clear")
        case "gas", "carbon_monoxide":
            return isActive ? TileState(symbol: "aqi.medium", word: "Detected")
                            : TileState(symbol: "aqi.low", word: "Clear")
        case "battery":
            return isActive ? TileState(symbol: "battery.25", word: "Low")
                            : TileState(symbol: "battery.100", word: "OK")
        case "lock":
            // A binary sensor *reporting* a lock, not a lock. HA's convention is inverted here —
            // `on` means unlocked — and getting it backwards would be the same false claim
            // `unavailable` above exists to avoid.
            return isActive ? TileState(symbol: "lock.open.fill", word: "Unlocked")
                            : TileState(symbol: "lock.fill", word: "Locked")
        default:
            return TileState(symbol: "dot.radiowaves.left.and.right",
                             word: isActive ? "Active" : "Clear")
        }
    }

    /// A cover's state, by what kind of cover it is.
    public static func cover(deviceClass: String?, isOpen: Bool,
                             unavailable: Bool = false) -> TileState {
        guard !unavailable else { return .unavailable }
        switch deviceClass {
        case "garage":
            return isOpen ? TileState(symbol: "door.garage.open", word: "Open")
                          : TileState(symbol: "door.garage.closed", word: "Closed")
        case "door":
            return isOpen ? TileState(symbol: "door.left.hand.open", word: "Open")
                          : TileState(symbol: "door.left.hand.closed", word: "Closed")
        case "curtain":
            return isOpen ? TileState(symbol: "curtains.open", word: "Open")
                          : TileState(symbol: "curtains.closed", word: "Closed")
        case "window":
            return isOpen ? TileState(symbol: "window.vertical.open", word: "Open")
                          : TileState(symbol: "window.vertical.closed", word: "Closed")
        default:
            return isOpen ? TileState(symbol: "blinds.horizontal.open", word: "Open")
                          : TileState(symbol: "blinds.horizontal.closed", word: "Closed")
        }
    }

    /// A switch or an outlet's state.
    ///
    /// The glyph fills when on and hollows when off, which is the same distinction the tint already
    /// makes — and the point of doubling it is that tint alone is what made every two-state tile look
    /// alike from across a room.
    public static func switchOutlet(deviceClass: String?, isOn: Bool,
                                    unavailable: Bool = false) -> TileState {
        guard !unavailable else { return .unavailable }
        switch deviceClass {
        case "outlet":
            return isOn ? TileState(symbol: "poweroutlet.type.b.fill", word: "On")
                        : TileState(symbol: "poweroutlet.type.b", word: "Off")
        default:
            return isOn ? TileState(symbol: "power.circle.fill", word: "On")
                        : TileState(symbol: "power.circle", word: "Off")
        }
    }

    /// A lock's state — the one with three of them.
    ///
    /// Jammed is not a third shade of locked: it is a door that tried and failed, and it gets its own
    /// glyph and its own word so it cannot be read as either.
    public static func lock(isLocked: Bool, isJammed: Bool, unavailable: Bool = false) -> TileState {
        guard !unavailable else { return .unavailable }
        if isJammed {
            return TileState(symbol: "lock.trianglebadge.exclamationmark", word: "Jammed")
        }
        return isLocked ? TileState(symbol: "lock.fill", word: "Locked")
                        : TileState(symbol: "lock.open.fill", word: "Unlocked")
    }

    /// Whether a domain has a two-state face at all, and so whether the configuration sheet offers a
    /// choice of how to show it.
    public static func isTwoState(_ domain: Domain) -> Bool {
        switch domain {
        case .binarySensor, .lock, .cover, .switchOutlet: return true
        // A light is deliberately absent: its tile carries a brightness slider, and a glyph in the
        // middle would have to sit around a control that is the more useful thing on it.
        case .light, .climate, .mediaPlayer, .camera, .scene, .script, .button,
             .sensor, .unknown: return false
        }
    }
}
