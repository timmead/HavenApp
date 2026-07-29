import Foundation
import Testing
@testable import HavenCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

@Test func relativeAgeReadsInSecondsMinutesThenHours() {
    #expect(RelativeAge.describe(ago(12), now: now) == "12s ago")
    #expect(RelativeAge.describe(ago(59), now: now) == "59s ago")
    #expect(RelativeAge.describe(ago(60), now: now) == "1m ago")
    #expect(RelativeAge.describe(ago(1_440), now: now) == "24m ago")
    #expect(RelativeAge.describe(ago(3_599), now: now) == "59m ago")
    #expect(RelativeAge.describe(ago(3_600), now: now) == "1h ago")
    #expect(RelativeAge.describe(ago(7_200), now: now) == "2h ago")
}

@Test func anythingUnderTwoSecondsIsJustNow() {
    #expect(RelativeAge.describe(now, now: now) == "just now")
    #expect(RelativeAge.describe(ago(1.9), now: now) == "just now")
    #expect(RelativeAge.describe(ago(2), now: now) == "2s ago")
}

/// The phone and the Home Assistant instance disagreeing about the time must not produce a negative
/// age — the same clamp `CameraSnapshotAge` has always had, now living one level down.
@Test func aFutureDateIsJustNowRatherThanNegative() {
    #expect(RelativeAge.describe(now.addingTimeInterval(30), now: now) == "just now")
    #expect(RelativeAge.age(of: now.addingTimeInterval(30), now: now) == nil)
}

@Test func spokenPhrasingSingularisesAndOmitsThePrefix() {
    #expect(RelativeAge.spoken(ago(12), now: now) == "12 seconds ago")
    #expect(RelativeAge.spoken(ago(60), now: now) == "1 minute ago")
    #expect(RelativeAge.spoken(ago(120), now: now) == "2 minutes ago")
    #expect(RelativeAge.spoken(ago(3_600), now: now) == "1 hour ago")
    #expect(RelativeAge.spoken(now, now: now) == "just now")
}

/// The reason this type refuses an optional at all: `CameraSnapshotAge` reads a missing date as
/// "just now", which is right for a frame being fetched and would be a false claim about an event
/// nobody has a time for. The two surfaces are meant to differ here, so both are held to it.
@Test func theSnapshotWrapperKeepsItsOwnNilMeaningAndItsOwnPhrasing() {
    #expect(CameraSnapshotAge.describe(capturedAt: nil, now: now) == "just now")
    #expect(CameraSnapshotAge.spoken(capturedAt: nil, now: now) == "updated just now")
    #expect(CameraSnapshotAge.age(capturedAt: nil, now: now) == nil)
    // Delegation, not duplication: the same interval reads the same way through both surfaces.
    #expect(CameraSnapshotAge.describe(capturedAt: ago(1_440), now: now) == RelativeAge.describe(ago(1_440), now: now))
    #expect(CameraSnapshotAge.spoken(capturedAt: ago(12), now: now) == "updated \(RelativeAge.spoken(ago(12), now: now))")
}
