import Foundation
import Testing
@testable import HavenCore

/// A fetch comfortably inside its interval holds a steady cadence, measured start-to-start: the
/// wait is the interval *minus* what the fetch already spent, not the interval on top of it. The
/// naive version drifts by the fetch time every single cycle.
@Test func aFastFetchWaitsOutTheRemainderOfItsInterval() {
    #expect(SnapshotRefresh.delay(interval: 10, duration: 0.2) == 9.8)
    #expect(SnapshotRefresh.delay(interval: 1, duration: 0.1).isApproximately(0.9))
}

/// **The case the whole type exists for, and the one nobody hits on a LAN.** A fetch slower than
/// its interval must degrade to a lower frame rate — never to a negative or zero wait, which is how
/// a fixed-clock refresh ends up cancelling its own in-flight request every tick and completing
/// none of them.
@Test func aFetchSlowerThanItsIntervalDegradesToALowerFrameRateNotToNothing() {
    #expect(SnapshotRefresh.delay(interval: 1, duration: 1.5) == SnapshotRefresh.minimumGap)
    #expect(SnapshotRefresh.delay(interval: 1, duration: 30) == SnapshotRefresh.minimumGap)
    #expect(SnapshotRefresh.delay(interval: 10, duration: 12) == SnapshotRefresh.minimumGap)
}

/// The floor is never zero. A camera already too slow for its interval answering with a
/// zero-gap loop is the same total load on the user's own server as the broken version — it just
/// has pictures to show for it.
@Test func theGapIsNeverZero() {
    #expect(SnapshotRefresh.minimumGap > 0)
    #expect(SnapshotRefresh.delay(interval: 1, duration: 1) == SnapshotRefresh.minimumGap)
    // An interval shorter than the floor still yields the floor rather than a busy loop.
    #expect(SnapshotRefresh.delay(interval: 0.05, duration: 0) == SnapshotRefresh.minimumGap)
}

/// A clock that moved backwards mid-fetch must not produce a *negative* wait, which `Task.sleep`
/// reads as no wait at all — straight back to the busy loop.
@Test func nonsenseDurationsCannotProduceANegativeOrInfiniteWait() {
    // A value that isn't a real measurement is discarded rather than trusted, so it can never
    // shorten the wait — the direction that matters, since the only harmful answer here is a
    // small one.
    #expect(SnapshotRefresh.delay(interval: 10, duration: -5) == 10)
    #expect(SnapshotRefresh.delay(interval: 10, duration: .nan) == 10)
    #expect(SnapshotRefresh.delay(interval: 10, duration: .infinity) == 10)
    #expect(SnapshotRefresh.delay(interval: .nan, duration: 1) == SnapshotRefresh.minimumGap)
    // The invariant, whatever the inputs: finite, and never at or below zero.
    for interval in [-1.0, 0, .nan, .infinity, 1, 10] {
        for duration in [-1.0, 0, .nan, .infinity, 0.5, 100] {
            let delay = SnapshotRefresh.delay(interval: interval, duration: duration)
            #expect(delay.isFinite && delay >= SnapshotRefresh.minimumGap)
        }
    }
}

private extension Double {
    func isApproximately(_ other: Double) -> Bool { abs(self - other) < 0.000_001 }
}
