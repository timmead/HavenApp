import Foundation

/// The local state a cover command implies, applied before Home Assistant confirms it.
///
/// The sibling of `MediaPlayerOptimistic` and `LightOptimistic`, and the one where "flip every
/// attribute it implies" is least optional: **a cover's position and its open/closed state are two
/// readings of one fact**, and `CoverState` derives them from two different places — `isOpen` from
/// the entity's `state` string, `positionPercent` from the `current_position` attribute.
///
/// Write only the position and a shade dragged from shut to half-open renders with its bar at 50%
/// and everything else still saying "closed": the tile's active tint, its icon, its name colour and
/// the room roll-up's "2 open" count, all disagreeing with the control the user just moved. Write
/// only the state and the bar snaps back. Both are written here, together, once.
///
/// D spec §10b item 2 names cover position by name as a control that visibly snaps back between
/// release and Home Assistant's echo.
public enum CoverOptimistic {
    /// `cover.set_cover_position`.
    ///
    /// `state` follows the position because that is what Home Assistant itself reports once the
    /// cover finishes moving: any position above zero is `open`, and exactly zero is `closed`.
    ///
    /// The intermediate `opening`/`closing` states are deliberately **not** invented. They describe
    /// a cover that is physically in motion, which is a fact about the device and not about our
    /// request — and `CoverState.isOpen` already treats `opening` as open, so writing the settled
    /// state here gives the correct rendering either way. Whichever of the four the integration
    /// actually reports arrives moments later and replaces this wholesale.
    public static func position(_ e: EntityState, percent: Int) -> EntityState {
        var next = e
        let clamped = max(0, min(100, percent))
        next.attributes["current_position"] = .int(clamped)
        next.state = clamped > 0 ? "open" : "closed"
        return next
    }
}
