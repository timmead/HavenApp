import Testing
import Foundation
@testable import HavenCore

private func series(_ values: [Double]) -> HistorySeries {
    HistorySeries(points: values.enumerated().map {
        HistoryPoint(time: Date(timeIntervalSince1970: Double($0.offset)), value: $0.element)
    })
}

/// The whole point: a humidity value must land at the same *relative height* in the chart as it
/// sits in its own range, so the two lines are comparable by shape even though their units are
/// not comparable at all.
@Test func projectionMapsRelativePosition() {
    let scale = DualAxisScale(primary: series([20, 24]), secondary: series([40, 60]))!
    #expect(scale.project(40) == scale.primaryDomain.lowerBound)
    #expect(scale.project(60) == scale.primaryDomain.upperBound)
    let mid = scale.project(50)
    #expect(abs(mid - (scale.primaryDomain.lowerBound + scale.primaryDomain.upperBound) / 2) < 1e-9)
}

@Test func unprojectIsTheInverseOfProject() {
    let scale = DualAxisScale(primary: series([18.2, 23.7]), secondary: series([38, 71]))!
    for value in [38.0, 44.5, 60.0, 71.0] {
        #expect(abs(scale.unproject(scale.project(value)) - value) < 1e-9)
    }
}

/// A room whose humidity has not moved all day. Without a guard the domain is zero-width and
/// every projection divides by zero, so the chart renders NaN positions and Swift Charts draws
/// nothing at all — a blank card for a room that has perfectly good data.
@Test func aFlatSecondarySeriesStillProjectsFinitely() {
    let scale = DualAxisScale(primary: series([20, 24]), secondary: series([50, 50]))!
    #expect(scale.project(50).isFinite)
    #expect(scale.secondaryDomain.lowerBound < scale.secondaryDomain.upperBound)
    // A flat series sits in the middle of its padded band, not pinned to an edge.
    let centre = (scale.primaryDomain.lowerBound + scale.primaryDomain.upperBound) / 2
    #expect(abs(scale.project(50) - centre) < 1e-9)
}

@Test func aFlatPrimarySeriesAlsoYieldsAFiniteDomain() {
    let scale = DualAxisScale(primary: series([21, 21]), secondary: series([40, 60]))!
    #expect(scale.primaryDomain.lowerBound < scale.primaryDomain.upperBound)
    #expect(scale.project(50).isFinite)
}

@Test func aSinglePointSeriesIsUsable() {
    let scale = DualAxisScale(primary: series([21]), secondary: series([50]))!
    #expect(scale.primaryDomain.lowerBound < scale.primaryDomain.upperBound)
    #expect(scale.project(50).isFinite)
}

/// No scale without both series — a one-series chart uses its own axis directly and must not go
/// through a projection at all.
@Test func anEmptySeriesYieldsNoScale() {
    #expect(DualAxisScale(primary: series([]), secondary: series([40, 60])) == nil)
    #expect(DualAxisScale(primary: series([20, 24]), secondary: series([])) == nil)
    #expect(DualAxisScale(primary: series([]), secondary: series([])) == nil)
}

/// Ticks are the trailing axis labels: positioned in the *primary* domain (what Swift Charts
/// plots against) and labelled with the *secondary* value (what the reader needs).
@Test func secondaryTicksArePositionedInPrimarySpaceAndLabelledInSecondary() {
    let scale = DualAxisScale(primary: series([20, 24]), secondary: series([40, 60]))!
    let ticks = scale.secondaryTicks(count: 5)
    #expect(ticks.count == 5)
    for tick in ticks {
        #expect(abs(scale.project(tick.value) - tick.position) < 1e-9)
        #expect(scale.primaryDomain.contains(tick.position))
    }
    #expect(ticks.first?.value == scale.secondaryDomain.lowerBound)
    #expect(ticks.last?.value == scale.secondaryDomain.upperBound)
}

/// A caller asking for a degenerate tick count must not get a divide-by-zero or an empty axis.
@Test func tickCountsBelowTwoDegradeToTheDomainBounds() {
    let scale = DualAxisScale(primary: series([20, 24]), secondary: series([40, 60]))!
    #expect(scale.secondaryTicks(count: 0).count == 2)
    #expect(scale.secondaryTicks(count: 1).count == 2)
}

/// Every projected value lands inside `primaryDomain`. True by construction, pinned here because
/// the chart depends on it: Task 5 sets the chart's Y scale to `primaryDomain`, and a projection
/// that escaped it would put part of the humidity line outside the plot area, where Swift Charts
/// clips it without complaint.
@Test func everyProjectedValueLandsInsideThePrimaryDomain() {
    let scale = DualAxisScale(primary: series([20, 24]), secondary: series([40, 60]))!
    for value in [40.0, 47.5, 55.0, 60.0] {
        #expect(scale.primaryDomain.contains(scale.project(value)))
    }
}
