import Testing
import Foundation
@testable import HavenCore

private func series(_ values: [Double]) -> HistorySeries {
    HistorySeries(points: values.enumerated().map {
        HistoryPoint(time: Date(timeIntervalSince1970: Double($0.offset)), value: $0.element)
    })
}

// MARK: - Projection

/// The whole point: a humidity value lands at the same *relative height* in the chart as it sits
/// in its own range, so the two lines are comparable by shape even though their units are not.
@Test func projectionMapsRelativePosition() {
    let scale = DualAxisScale(primary: 15...30, secondary: 30...70)
    #expect(scale.project(30) == 15)
    #expect(scale.project(70) == 30)
    #expect(scale.project(50) == 22.5)
}

@Test func unprojectIsTheInverseOfProject() {
    let scale = DualAxisScale(primary: 18.2...23.7, secondary: 38...71)
    for value in [38.0, 44.5, 60.0, 71.0] {
        #expect(abs(scale.unproject(scale.project(value)) - value) < 1e-9)
    }
}

/// Every projected value lands inside `primaryDomain`. True by construction, pinned because the
/// chart depends on it: the view sets its Y scale to `primaryDomain`, and a projection that
/// escaped would put part of the humidity line outside the plot area, where Swift Charts clips it
/// without complaint.
@Test func everyProjectedValueLandsInsideThePrimaryDomain() {
    let scale = DualAxisScale(primary: 15...30, secondary: 30...70)
    for value in stride(from: 30.0, through: 70.0, by: 2.5) {
        #expect(scale.primaryDomain.contains(scale.project(value)))
    }
}

// MARK: - Degenerate domains

/// A zero-width domain makes every projection divide by zero, and Swift Charts silently declines
/// to draw NaN — a blank card for a room with perfectly good data. Callers normally cannot produce
/// one; this is the floor under that.
///
/// Asserted on *both* axes and for centring, not merely finiteness: an asymmetric guard would
/// leave a flat line pinned to an edge of the plot rather than running through the middle of it,
/// and only a centring assertion catches that.
@Test func aDegeneratePrimaryDomainIsWidenedSymmetrically() {
    let scale = DualAxisScale(primary: 21...21, secondary: 30...70)
    #expect(scale.primaryDomain.lowerBound == 20.5)
    #expect(scale.primaryDomain.upperBound == 21.5)
    #expect(scale.project(50).isFinite)
}

@Test func aDegenerateSecondaryDomainIsWidenedSymmetrically() {
    let scale = DualAxisScale(primary: 15...30, secondary: 50...50)
    #expect(scale.secondaryDomain.lowerBound == 49.5)
    #expect(scale.secondaryDomain.upperBound == 50.5)
    // A flat series sits in the middle of its widened band, not pinned to an edge.
    #expect(scale.project(50) == 22.5)
}

// MARK: - The single-series data-fitted domain

@Test func domainForASeriesIsItsOwnRange() {
    #expect(DualAxisScale.domain(for: series([18, 24])) == 18...24)
}

@Test func domainForAFlatSeriesIsPaddedAndCentred() {
    #expect(DualAxisScale.domain(for: series([21, 21])) == 20.5...21.5)
}

@Test func domainForASinglePointSeriesIsPadded() {
    #expect(DualAxisScale.domain(for: series([21])) == 20.5...21.5)
}

@Test func domainForAnEmptySeriesIsNil() {
    #expect(DualAxisScale.domain(for: series([])) == nil)
}

// MARK: - Ticks

/// Ticks carry the position to draw at (primary space, what the chart plots against) and the value
/// to print (secondary space, what the reader came for). The pairing is asserted against
/// independently computed positions — not by re-deriving them with `project`, which is what
/// `secondaryTicks` uses internally and so could not fail.
@Test func secondaryTicksArePositionedInPrimarySpaceAndLabelledInSecondary() {
    let scale = DualAxisScale(primary: 15...30, secondary: 30...70)
    let ticks = scale.secondaryTicks(step: 10)
    #expect(ticks.map(\.value) == [30, 40, 50, 60, 70])
    #expect(ticks.map(\.position) == [15, 18.75, 22.5, 26.25, 30])
}

/// Stepping rather than counting is what keeps labels round once an axis grows — see
/// `EnvironmentAxisBounds`.
@Test func secondaryTicksStayRoundOnAGrownAxis() {
    let scale = DualAxisScale(primary: 15...35, secondary: 20...70)
    #expect(scale.secondaryTicks(step: 10).map(\.value) == [20, 30, 40, 50, 60, 70])
}
