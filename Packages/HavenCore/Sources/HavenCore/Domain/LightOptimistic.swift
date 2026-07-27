import Foundation

/// The local state a light command implies, applied before Home Assistant confirms it.
///
/// The sibling of `MediaPlayerOptimistic`, and here for the same reason: **an optimistic update has
/// to flip every attribute it implies, not just the obvious one.** This project's original instance
/// of that bug was a light — the brightness slider that went on reading its old percentage after
/// the light was switched off, because the write changed `state` and left `brightness` alone. The
/// mirror image is what this file exists for: a brightness drag that writes `brightness` and leaves
/// `state` alone would leave a tile whose bar has moved but whose icon, tint and name colour all
/// still say "off".
///
/// D spec §10b item 2 names brightness by name as a control that visibly snaps back between release
/// and Home Assistant's echo. That snap is what the optimistic write removes, and it can only
/// remove it if the value written round-trips *exactly* back through `LightState` — which is why
/// the tests assert the round trip across the whole range rather than checking one attribute.
public enum LightOptimistic {
    /// `light.turn_on` with `brightness_pct`.
    ///
    /// Writes `brightness` (0…255, which is what `LightState.brightnessPercent` reads back) and
    /// `state`, because a light given a brightness is on by definition — that is the whole implied
    /// set for this command.
    ///
    /// **This models `turn_on`, so it cannot express "off", and it deliberately does not try.**
    /// `percent` is clamped to at least 1: Home Assistant's behaviour for `brightness_pct: 0`
    /// varies by integration (some treat it as off, some ignore it), and encoding a guess about
    /// that here would put a state on screen that the instance may never agree with. Turning a
    /// light off is `setLight(on: false)`, a different command with its own optimistic path.
    public static func brightness(_ e: EntityState, percent: Int) -> EntityState {
        var next = e
        let clamped = max(1, min(100, percent))
        next.state = "on"
        next.attributes["brightness"] = .int(Int((Double(clamped) / 100 * 255).rounded()))
        return next
    }
}
