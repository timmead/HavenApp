import Testing
import Foundation
@testable import HavenCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Test func progressTicksForwardWhilePlaying() {
    // The whole point: Home Assistant reported 30s at t0 and has said nothing since, so at t0+45
    // the track is 75s in — not still 30s in, which is what rendering `media_position` directly
    // would show.
    let e = MediaProgress.elapsed(position: 30, updatedAt: t0, isPlaying: true, duration: 300, now: t0.addingTimeInterval(45))
    #expect(e == 75)
}

@Test func progressDoesNotTickWhilePaused() {
    // A paused player's `media_position_updated_at` keeps receding into the past. Adding that
    // interval would race the bar to the end of a track nobody is playing.
    let e = MediaProgress.elapsed(position: 30, updatedAt: t0, isPlaying: false, duration: 300, now: t0.addingTimeInterval(600))
    #expect(e == 30)
}

@Test func progressWithoutATimestampCannotTick() {
    // No `media_position_updated_at` means there is no anchor to measure from. Showing the raw
    // position is the honest answer; interpolating from `lastUpdated` or from "now" would invent a
    // number that drifts further from the truth the longer the view stays open.
    let e = MediaProgress.elapsed(position: 30, updatedAt: nil, isPlaying: true, duration: 300, now: t0.addingTimeInterval(45))
    #expect(e == 30)
}

@Test func progressNeverRunsBackwardsOnClockSkew() {
    // The phone's clock can sit behind the instance's. A negative interval means the clocks
    // disagree, not that the track went backwards — and a negative elapsed lays out as a bar with
    // negative width.
    let e = MediaProgress.elapsed(position: 30, updatedAt: t0, isPlaying: true, duration: 300, now: t0.addingTimeInterval(-90))
    #expect(e == 30)
    // A negative *position* is equally impossible and clamps the same way.
    #expect(MediaProgress.elapsed(position: -5, updatedAt: t0, isPlaying: false, duration: 300, now: t0) == 0)
}

@Test func progressStopsAtTheEndOfTheTrack() {
    // Interpolation outlives the track: HA reports nothing more until the next song starts, so
    // without a clamp the bar would keep growing past 100% for as long as the modal stays open.
    let e = MediaProgress.elapsed(position: 290, updatedAt: t0, isPlaying: true, duration: 300, now: t0.addingTimeInterval(600))
    #expect(e == 300)
}

@Test func progressWithNoDurationStillTicks() {
    // A live radio stream reports no duration. That removes the clamp, not the ticking — the
    // elapsed readout is still the useful part.
    let e = MediaProgress.elapsed(position: 10, updatedAt: t0, isPlaying: true, duration: nil, now: t0.addingTimeInterval(20))
    #expect(e == 30)
}

@Test func progressIsNilWithoutAPosition() {
    #expect(MediaProgress.elapsed(position: nil, updatedAt: t0, isPlaying: true, duration: 300, now: t0) == nil)
}

@Test func progressFractionRefusesToDivideByNothing() {
    #expect(MediaProgress.fraction(elapsed: 75, duration: 300) == 0.25)
    #expect(MediaProgress.fraction(elapsed: nil, duration: 300) == nil)
    #expect(MediaProgress.fraction(elapsed: 75, duration: nil) == nil)
    // A live stream reports duration 0. Dividing by it yields a non-finite width that lays out as
    // a garbage bar rather than as no bar at all.
    #expect(MediaProgress.fraction(elapsed: 75, duration: 0) == nil)
    // Belt and braces: even if elapsed somehow exceeded duration, the fraction stays in 0…1.
    #expect(MediaProgress.fraction(elapsed: 400, duration: 300) == 1)
}

@Test func progressFormatsAsClockTime() {
    #expect(MediaProgress.format(0) == "0:00")
    #expect(MediaProgress.format(7) == "0:07")
    #expect(MediaProgress.format(187) == "3:07")
    #expect(MediaProgress.format(3723) == "1:02:03")
    // Never a minus sign in the corner of the now-playing card.
    #expect(MediaProgress.format(-5) == "0:00")
    #expect(MediaProgress.format(.nan) == "0:00")
}

@Test func positionTimestampParsesEveryShapeHomeAssistantSends() {
    // Built rather than written as a literal epoch, so the assertions below check the parser and
    // not this test's own arithmetic.
    var c = DateComponents()
    c.year = 2026; c.month = 7; c.day = 26; c.hour = 10; c.minute = 0; c.second = 0
    c.timeZone = TimeZone(secondsFromGMT: 0)
    let expected = try! #require(Calendar(identifier: .gregorian).date(from: c))

    // `datetime.isoformat()` — six fractional digits, which is what Home Assistant actually emits.
    // A parser that only knows three returns nil here, and a nil timestamp means the bar never
    // ticks: the exact frozen-progress bug this file exists to prevent, reintroduced silently.
    let micro = MediaProgress.parseUpdatedAt(.string("2026-07-26T10:00:00.123456+00:00"))
    #expect(micro != nil)
    #expect(abs((micro ?? .distantPast).timeIntervalSince(expected) - 0.123456) < 0.001)

    // Milliseconds, and no fractional part at all.
    #expect(MediaProgress.parseUpdatedAt(.string("2026-07-26T10:00:00.123+00:00")) != nil)
    #expect(MediaProgress.parseUpdatedAt(.string("2026-07-26T10:00:00+00:00")) == expected)
    // Zulu spelling of the same instant.
    #expect(MediaProgress.parseUpdatedAt(.string("2026-07-26T10:00:00Z")) == expected)

    #expect(MediaProgress.parseUpdatedAt(nil) == nil)
    #expect(MediaProgress.parseUpdatedAt(.string("")) == nil)
    #expect(MediaProgress.parseUpdatedAt(.string("yesterday")) == nil)
}

@Test func positionTimestampRoundTripsThroughOurOwnFormatter() {
    // An optimistic pause writes this attribute back itself (see `MediaPlayerOptimistic`). If the
    // shape it writes is not one this parser accepts, the pause silently loses the position and
    // the bar jumps to wherever the last server-reported value was.
    let now = Date(timeIntervalSince1970: 1_785_060_000.5)
    let text = MediaProgress.formatUpdatedAt(now)
    let parsed = MediaProgress.parseUpdatedAt(.string(text))
    #expect(abs((parsed ?? .distantPast).timeIntervalSince1970 - now.timeIntervalSince1970) < 0.001)
}
