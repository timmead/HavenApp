import Foundation

/// Paces a repeating snapshot fetch so that a slow link degrades to a **lower frame rate** rather
/// than to no frames at all.
///
/// The bug this exists to make impossible: a refresh driven by a fixed clock starts the next fetch
/// on a timer regardless of whether the last one finished, and a view that restarts its load on
/// each tick therefore cancels its own in-flight request every interval. Wherever a round trip
/// reliably takes longer than the interval — a Nabu Casa relay, a 4K still, a slow
/// `camera_proxy` — *no fetch ever completes*, the view stays on its loading placeholder forever,
/// and the app spends one cancelled full-resolution JPEG request per interval to achieve it. There
/// is no error to show because nothing failed; it is a confident blank with a request loop behind
/// it, which is the exact failure shape the authenticated image path was built to eliminate.
///
/// The cure is to make the *next* fetch a function of when the *last one finished*, which is what
/// this computes. It lives here, in HavenCore under test, rather than inline in a SwiftUI `.task`,
/// because the case that matters is the one nobody exercises locally: a fetch slower than the
/// interval. On a fast LAN every implementation of this looks identical.
public enum SnapshotRefresh {
    /// The floor on the gap between one fetch finishing and the next starting.
    ///
    /// Never zero. A fetch that already takes longer than its interval is a signal that the link or
    /// the camera is struggling, and answering that by starting the next request the instant the
    /// last one lands turns the refresh into a busy loop against the user's own server — the same
    /// total work as the broken version, just with pictures to show for it. A quarter second is
    /// enough to keep the loop yielding and small enough to be invisible at any usable frame rate.
    public static let minimumGap: TimeInterval = 0.25

    /// How long to wait after a fetch that took `duration` before starting the next one, aiming for
    /// one fetch every `interval`.
    ///
    /// The target cadence is measured **from the start of one fetch to the start of the next**, so
    /// a fast link holds a steady rate instead of drifting by the fetch time on every cycle. When
    /// the fetch alone already exceeds the interval, the result is `minimumGap`: the cycle simply
    /// runs as fast as the link allows, which is the graceful degradation this whole type is for.
    ///
    /// A non-finite or negative `duration` (a clock that went backwards mid-fetch) is treated as
    /// zero rather than propagating into a nonsense delay — including a *negative* one, which
    /// `Task.sleep` would treat as no wait at all and turn straight back into the busy loop above.
    public static func delay(interval: TimeInterval, duration: TimeInterval) -> TimeInterval {
        let elapsed = duration.isFinite && duration > 0 ? duration : 0
        let target = interval.isFinite && interval > 0 ? interval : 0
        return max(minimumGap, target - elapsed)
    }
}
