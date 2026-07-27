import Foundation

/// Maps a second series onto a first series' Y axis, and back.
///
/// Swift Charts has exactly one Y scale per chart. Plotting a room's temperature (roughly
/// 15–30°C) and its humidity (0–100%) against that one scale unmodified makes the temperature a
/// flat line at the bottom — technically correct and completely unreadable. So the humidity is
/// *projected* into the temperature's domain before plotting, and the trailing axis is labelled
/// with `unproject`, which is what turns a shared scale back into two honest axes.
///
/// This lives in HavenCore, away from the view, because it is arithmetic with edge cases that
/// are invisible on screen until they aren't: a room whose humidity has not moved all day gives
/// a zero-width domain, and dividing by it yields NaN positions that Swift Charts silently
/// declines to draw — a blank card for a room with perfectly good data.
public struct DualAxisScale: Sendable, Equatable {
    public let primaryDomain: ClosedRange<Double>
    public let secondaryDomain: ClosedRange<Double>

    /// Half-width of the band given to a series whose values are all identical, in that series'
    /// own units. Arbitrary, and only ever used when the alternative is a zero-width domain.
    private static let flatSeriesPadding = 0.5

    /// Projects between two already-decided axis ranges.
    ///
    /// Deliberately takes domains rather than the series they came from: *what range an axis
    /// should cover* is a policy question involving the reading's role, its unit and what counts
    /// as an ordinary indoor value (see `EnvironmentAxisBounds`), whereas this type is the
    /// arithmetic that maps one range onto another. Keeping them apart is what lets the bands be
    /// retuned without touching a line of the projection.
    ///
    /// A degenerate range is widened rather than rejected: dividing by a zero-width domain yields
    /// NaN positions, and Swift Charts silently declines to draw those — a blank card for a room
    /// with perfectly good data. Callers normally pass ranges that cannot be degenerate, so this
    /// is a floor under a caller mistake rather than an expected path.
    public init(primary: ClosedRange<Double>, secondary: ClosedRange<Double>) {
        primaryDomain = Self.widened(primary)
        secondaryDomain = Self.widened(secondary)
    }

    private static func widened(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
        range.lowerBound < range.upperBound
            ? range
            : (range.lowerBound - flatSeriesPadding)...(range.lowerBound + flatSeriesPadding)
    }

    private static func domain(_ lo: Double, _ hi: Double) -> ClosedRange<Double> {
        lo < hi ? lo...hi : (lo - flatSeriesPadding)...(lo + flatSeriesPadding)
    }

    /// The padded domain for a *single* series — for a chart with only one axis, which has no
    /// `DualAxisScale` to project through and so would otherwise have no source for this at all.
    /// Goes through the same `domain(_:_:)` and `flatSeriesPadding` as `init?` uses for each of
    /// its two series, rather than leaving a caller to reimplement the flat-series padding a
    /// second time: that arithmetic's edge case (a series that hasn't moved) is exactly the one
    /// this type exists to contain in one place. `nil` when the series has no plottable data.
    public static func domain(for series: HistorySeries) -> ClosedRange<Double>? {
        guard let lo = series.min, let hi = series.max else { return nil }
        return domain(lo, hi)
    }

    /// A secondary-axis value, as a Y position on the primary axis.
    public func project(_ secondaryValue: Double) -> Double {
        let fraction = (secondaryValue - secondaryDomain.lowerBound)
            / (secondaryDomain.upperBound - secondaryDomain.lowerBound)
        return primaryDomain.lowerBound
            + fraction * (primaryDomain.upperBound - primaryDomain.lowerBound)
    }

    /// A Y position on the primary axis, as a secondary-axis value. The inverse of `project`.
    public func unproject(_ primaryValue: Double) -> Double {
        let fraction = (primaryValue - primaryDomain.lowerBound)
            / (primaryDomain.upperBound - primaryDomain.lowerBound)
        return secondaryDomain.lowerBound
            + fraction * (secondaryDomain.upperBound - secondaryDomain.lowerBound)
    }

    /// Trailing-axis labels at round values: each carries the position to draw it at (primary
    /// space, which is what the chart plots against) and the value to print (secondary space,
    /// which is what the reader came for).
    ///
    /// Driven by a *step* rather than a count, because a count cannot survive the axis growing.
    /// Five evenly spaced ticks across 30–70% read 30/40/50/60/70; the same five across a range
    /// grown to 20–70 read 20/32.5/45/57.5/70. Stepping instead means the labels stay round
    /// whatever the range turns out to be — and roundness is most of what makes an axis look
    /// deliberate rather than computed.
    public func secondaryTicks(step: Double) -> [(position: Double, value: Double)] {
        EnvironmentAxisBounds.ticks(in: secondaryDomain, step: step)
            .map { (position: project($0), value: $0) }
    }
}
