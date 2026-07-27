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

    /// `nil` unless *both* series have plottable data — a chart with one series uses its own
    /// axis directly and must never route through a projection.
    public init?(primary: HistorySeries, secondary: HistorySeries) {
        guard let pMin = primary.min, let pMax = primary.max,
              let sMin = secondary.min, let sMax = secondary.max else { return nil }
        primaryDomain = Self.domain(pMin, pMax)
        secondaryDomain = Self.domain(sMin, sMax)
    }

    private static func domain(_ lo: Double, _ hi: Double) -> ClosedRange<Double> {
        lo < hi ? lo...hi : (lo - flatSeriesPadding)...(lo + flatSeriesPadding)
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

    /// Evenly spaced trailing-axis labels: each carries the position to draw it at (primary
    /// space, which is what the chart plots against) and the value to print (secondary space,
    /// which is what the reader came for).
    public func secondaryTicks(count: Int) -> [(position: Double, value: Double)] {
        let steps = Swift.max(count, 2) - 1
        return (0...steps).map { step in
            let value = secondaryDomain.lowerBound
                + (Double(step) / Double(steps))
                * (secondaryDomain.upperBound - secondaryDomain.lowerBound)
            return (position: project(value), value: value)
        }
    }
}
