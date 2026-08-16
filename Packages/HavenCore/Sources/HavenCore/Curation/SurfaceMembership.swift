import Foundation

/// A place in Haven that renders a room's devices.
///
/// Two, and they show different things by design: the dashboard's room section is a *summary* of
/// what you control, and room detail is the room's *inventory*. Curation decides the default for
/// each (see `CurationTier`), and a user's decision is per surface — taking a light off the
/// dashboard says nothing about whether it is reachable one tap deeper.
public enum HavenSurface: String, Sendable, Codable, CaseIterable {
    case overview
    /// `room_detail` on the wire: the stored document is JSON read by other builds, so the raw
    /// values are spelled deliberately rather than left to Swift's case names.
    case roomDetail = "room_detail"

    /// The tiers this surface renders when the user has said nothing.
    var defaultTiers: Set<CurationTier> {
        switch self {
        case .overview: return [.primary]
        case .roomDetail: return [.primary, .secondary]
        }
    }

    /// The surface that is not this one — meaningful only because there are exactly two.
    ///
    /// Promoted here, internal rather than public, so `RoomSection.storedOrder(for:)` (decision 9's
    /// own-then-other-then-none fallback for tile order) and `Subsections.resolve` (decision 10's
    /// identical shape for subsection span) can share one switch instead of each keeping its own —
    /// they are the two call sites within this module, and neither is a reason for `HavenApp` to be
    /// able to ask a surface what its opposite is. Exhaustive with no `default`, so a third surface
    /// has to decide here what it is the opposite of, rather than inheriting a wrong answer.
    var other: HavenSurface {
        switch self {
        case .overview: return .roomDetail
        case .roomDetail: return .overview
        }
    }
}

/// What a user decided about one entity on one surface.
///
/// Deliberately **not** a boolean, and deliberately absent by default, which makes three states:
///
/// - *absent* — follow curation. Where nearly everything stays.
/// - `hidden` — the user took it off this surface.
/// - `shown` — the user put it on this surface though curation did not.
///
/// The third is what makes configuration mode's `+` an *addition* rather than an undo: putting a
/// humidity sensor on the dashboard grid overrides curation upward, and a design holding only a
/// hidden set could restore what the user removed and nothing else.
public enum SurfaceMembership: String, Sendable, Codable {
    case hidden, shown

    /// Whether `surface` shows an entity of `tier`, given the user's decision about it.
    ///
    /// A function rather than a set lookup because of the first clause: **`shown` cannot resurrect a
    /// `.hidden` tier.** That tier is Home Assistant's own doing — `hidden_by`, or an
    /// `entity_category` marking a configuration/diagnostic entity — and HA outranks everything
    /// Haven decides, the same order of authority `EntityCuration` and `LockTile` already obey. The
    /// picker never offers those entities, so such an override cannot be made through the UI; this
    /// refuses it anyway, so a document edited by hand or by a future build cannot make Haven
    /// contradict Home Assistant.
    public static func shows(tier: CurationTier, on surface: HavenSurface,
                             override: SurfaceMembership?) -> Bool {
        guard tier != .hidden else { return false }
        switch override {
        case .hidden: return false
        case .shown: return true
        case nil: return surface.defaultTiers.contains(tier)
        }
    }
}
