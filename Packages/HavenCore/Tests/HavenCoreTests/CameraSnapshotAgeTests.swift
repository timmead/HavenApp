import Foundation
import Testing
@testable import HavenCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

@Test func snapshotAgeReadsInSecondsMinutesThenHours() {
    #expect(CameraSnapshotAge.describe(capturedAt: ago(12), now: now) == "12s ago")
    #expect(CameraSnapshotAge.describe(capturedAt: ago(59), now: now) == "59s ago")
    #expect(CameraSnapshotAge.describe(capturedAt: ago(60), now: now) == "1m ago")
    #expect(CameraSnapshotAge.describe(capturedAt: ago(210), now: now) == "3m ago")
    #expect(CameraSnapshotAge.describe(capturedAt: ago(3599), now: now) == "59m ago")
    #expect(CameraSnapshotAge.describe(capturedAt: ago(3600), now: now) == "1h ago")
    #expect(CameraSnapshotAge.describe(capturedAt: ago(7200), now: now) == "2h ago")
}

/// The stamp refreshes on a five-second cadence over a ten-second fetch, so anything under two
/// seconds would flicker "1s ago"/"2s ago" for no informational gain — motion for its own sake on a
/// dashboard glanced at for two seconds.
@Test func aFreshFrameReadsAsJustNow() {
    #expect(CameraSnapshotAge.describe(capturedAt: now, now: now) == "just now")
    #expect(CameraSnapshotAge.describe(capturedAt: ago(1.9), now: now) == "just now")
    #expect(CameraSnapshotAge.describe(capturedAt: ago(2), now: now) == "2s ago")
}

/// The phone and the instance disagreeing about the time must not produce "-4s ago".
@Test func aFrameStampedInTheFutureReadsAsJustNowRatherThanNegative() {
    #expect(CameraSnapshotAge.describe(capturedAt: now.addingTimeInterval(30), now: now) == "just now")
    #expect(CameraSnapshotAge.age(capturedAt: now.addingTimeInterval(30), now: now) == nil)
}

/// `nil` is "no frame has ever arrived", which the caller renders as nothing at all — measuring it
/// here would be stamping a picture that does not exist.
@Test func noFrameYetHasNoMeasurableAge() {
    #expect(CameraSnapshotAge.age(capturedAt: nil, now: now) == nil)
}

/// The spoken form is the same measurement, not a second one — and it has to be grammatical, since
/// "1 minutes ago" is the version a VoiceOver user actually hears.
@Test func theSpokenAgeIsGrammaticalAtEveryBoundary() {
    #expect(CameraSnapshotAge.spoken(capturedAt: ago(12), now: now) == "updated 12 seconds ago")
    #expect(CameraSnapshotAge.spoken(capturedAt: ago(60), now: now) == "updated 1 minute ago")
    #expect(CameraSnapshotAge.spoken(capturedAt: ago(120), now: now) == "updated 2 minutes ago")
    #expect(CameraSnapshotAge.spoken(capturedAt: ago(3600), now: now) == "updated 1 hour ago")
    #expect(CameraSnapshotAge.spoken(capturedAt: ago(7200), now: now) == "updated 2 hours ago")
    #expect(CameraSnapshotAge.spoken(capturedAt: now, now: now) == "updated just now")
}
