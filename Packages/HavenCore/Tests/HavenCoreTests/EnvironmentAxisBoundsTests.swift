import Testing
import Foundation
@testable import HavenCore

private func series(_ values: [Double]) -> HistorySeries {
    HistorySeries(points: values.enumerated().map {
        HistoryPoint(time: Date(timeIntervalSince1970: Double($0.offset)), value: $0.element)
    })
}

// MARK: - The band holds when the data fits inside it

/// The whole point of the change: an ordinary room does not get an axis fitted to its own noise.
/// A day drifting 24.0→24.5°C is half a degree of movement and should look like half a degree.
@Test func anOrdinaryRoomGetsTheWholeBandNotItsOwnRange() {
    let domain = EnvironmentAxisBounds.domain(role: .temperature, unit: "°C",
                                              series: series([24.0, 24.2, 24.5]))
    #expect(domain == 15...30)
}

@Test func anOrdinaryHumidityGetsTheWholeBand() {
    #expect(EnvironmentAxisBounds.domain(role: .humidity, unit: "%",
                                         series: series([44, 46, 49])) == 30...70)
}

/// Two rooms with different readings share a scale, which is what makes them comparable — the
/// property a data-fitted axis cannot have.
@Test func twoDifferentRoomsShareTheSameAxis() {
    let cool = EnvironmentAxisBounds.domain(role: .temperature, unit: "°C", series: series([18, 19]))
    let warm = EnvironmentAxisBounds.domain(role: .temperature, unit: "°C", series: series([26, 27]))
    #expect(cool == warm)
}

// MARK: - Growth

/// The band is a starting point, never a clamp. The chart pins its Y scale to this range, so a
/// reading outside it would otherwise be silently clipped at the edge of the plot.
@Test func theDomainAlwaysContainsEveryReading() {
    let cases: [(UpliftedSensor.Role, String, [Double])] = [
        (.temperature, "°C", [-8, 3, 12]),        // an outdoor sensor filed to a room
        (.temperature, "°C", [31, 34, 41]),       // a conservatory in a heatwave
        (.humidity, "%", [12, 18]),               // a very dry room
        (.humidity, "%", [88, 103]),              // and a miscalibrated one reading past 100
        (.temperature, "°F", [40, 95]),
    ]
    for (role, unit, values) in cases {
        let s = series(values)
        let domain = EnvironmentAxisBounds.domain(role: role, unit: unit, series: s)!
        #expect(domain.contains(s.min!), "\(unit) \(values) lost its minimum")
        #expect(domain.contains(s.max!), "\(unit) \(values) lost its maximum")
    }
}

/// Growth snaps outward in whole steps, so the labels stay round. Extending 30–70 to "whatever
/// contains 22" would give 22–70 and ticks at 22/34/46/58/70.
@Test func growthSnapsOutwardToWholeSteps() {
    #expect(EnvironmentAxisBounds.domain(role: .humidity, unit: "%", series: series([22, 45])) == 20...70)
    #expect(EnvironmentAxisBounds.domain(role: .humidity, unit: "%", series: series([45, 73])) == 30...80)
    #expect(EnvironmentAxisBounds.domain(role: .temperature, unit: "°C", series: series([11, 20])) == 10...30)
    #expect(EnvironmentAxisBounds.domain(role: .temperature, unit: "°C", series: series([20, 31])) == 15...35)
}

/// A reading exactly on a step boundary must not push the axis out by a whole extra step.
@Test func aReadingExactlyOnABoundaryDoesNotGrowTheAxis() {
    #expect(EnvironmentAxisBounds.domain(role: .temperature, unit: "°C", series: series([15, 30])) == 15...30)
    #expect(EnvironmentAxisBounds.domain(role: .humidity, unit: "%", series: series([30, 70])) == 30...70)
}

// MARK: - Units

/// Bands are per unit rather than converted, because 60–85°F is a better way of saying "an
/// ordinary indoor Fahrenheit range" than 59–86 (which is what converting 15–30°C produces).
@Test func fahrenheitAndKelvinGetTheirOwnBands() {
    #expect(EnvironmentAxisBounds.domain(role: .temperature, unit: "°F", series: series([70, 72])) == 60...85)
    #expect(EnvironmentAxisBounds.domain(role: .temperature, unit: "K", series: series([295])) == 285...305)
}

@Test func theDegreeSignAndCasingAreIgnored() {
    for unit in ["°C", "C", "c", " °c "] {
        #expect(EnvironmentAxisBounds.band(role: .temperature, unit: unit)?.range == 15...30, "\(unit)")
    }
}

/// Guessing Celsius for an unrecognised unit would put a 71°F reading 41 degrees above the band
/// and produce a chart far worse than the data-fitted one. So an unknown unit keeps the old
/// behaviour: fit the axis to the data.
@Test func anUnknownUnitFallsBackToTheDataRange() {
    #expect(EnvironmentAxisBounds.band(role: .temperature, unit: "°") == nil)
    let domain = EnvironmentAxisBounds.domain(role: .temperature, unit: "°", series: series([70, 72]))
    #expect(domain == 70...72)
}

/// Humidity is a percentage on every integration, so its band does not depend on the unit string
/// at all — including the empty one an unavailable entity reports.
@Test func humidityIgnoresTheUnitEntirely() {
    for unit in ["%", "", "°", "nonsense"] {
        #expect(EnvironmentAxisBounds.band(role: .humidity, unit: unit)?.range == 30...70, "\(unit)")
    }
}

// MARK: - Empty series

/// A room whose history hasn't loaded still gets a sensible axis rather than nothing, so the
/// chart's gridlines don't appear and then jump when the data lands.
@Test func anEmptySeriesStillGetsItsBand() {
    #expect(EnvironmentAxisBounds.domain(role: .temperature, unit: "°C", series: series([])) == 15...30)
    #expect(EnvironmentAxisBounds.domain(role: .humidity, unit: "%", series: series([])) == 30...70)
}

/// Except where there is no band to fall back on — then there is genuinely nothing to draw against.
@Test func anEmptySeriesWithAnUnknownUnitHasNoDomain() {
    #expect(EnvironmentAxisBounds.domain(role: .temperature, unit: "°", series: series([])) == nil)
}

// MARK: - Ticks

@Test func ticksAreEveryRoundValueInRangeIncludingBothEnds() {
    #expect(EnvironmentAxisBounds.ticks(in: 30...70, step: 10) == [30, 40, 50, 60, 70])
    #expect(EnvironmentAxisBounds.ticks(in: 15...30, step: 5) == [15, 20, 25, 30])
}

/// The property that survives growth — a count cannot do this. Five evenly spaced ticks across a
/// range grown to 20–70 would read 20/32.5/45/57.5/70.
@Test func ticksStayRoundWhenTheAxisGrows() {
    #expect(EnvironmentAxisBounds.ticks(in: 20...70, step: 10) == [20, 30, 40, 50, 60, 70])
    #expect(EnvironmentAxisBounds.ticks(in: 15...35, step: 5) == [15, 20, 25, 30, 35])
}

/// Binary floating point makes `10 * 0.3` slightly more than `3`. Without a tolerance the final
/// tick of a range whose bound is an exact step multiple in decimal would silently go missing.
@Test func aBoundThatIsAStepMultipleStillYieldsItsFinalTick() {
    #expect(EnvironmentAxisBounds.ticks(in: 0...0.3, step: 0.1).count == 4)
    #expect(EnvironmentAxisBounds.ticks(in: 285...305, step: 5) == [285, 290, 295, 300, 305])
}

/// A degenerate range or a nonsense step must not hang or return nothing — an axis with no ticks
/// renders unlabelled, which reads as broken.
@Test func degenerateInputsStillYieldATick() {
    #expect(EnvironmentAxisBounds.ticks(in: 20...20, step: 5) == [20])
    #expect(EnvironmentAxisBounds.ticks(in: 20...30, step: 0) == [20])
    #expect(EnvironmentAxisBounds.ticks(in: 20...30, step: -5) == [20])
}


/// **The invariant that keeps every axis label round**, and the one worth pinning because it is
/// invisible until someone reads the chart: a band whose bounds are not multiples of its own step
/// produces ticks that skip both ends. The Kelvin band was originally 288–303 — a faithful
/// conversion of 15–30°C — which ticked 290/295/300 and silently lost both bounds.
@Test func everyBandIsStepAligned() {
    let bands: [(String, EnvironmentAxisBounds.Band)] = [
        ("°C", EnvironmentAxisBounds.temperature(unit: "°C")!),
        ("°F", EnvironmentAxisBounds.temperature(unit: "°F")!),
        ("K", EnvironmentAxisBounds.temperature(unit: "K")!),
        ("%", EnvironmentAxisBounds.humidity),
    ]
    for (name, band) in bands {
        let ticks = EnvironmentAxisBounds.ticks(in: band.range, step: band.step)
        #expect(ticks.first == band.range.lowerBound, "\(name) band does not start on a tick")
        #expect(ticks.last == band.range.upperBound, "\(name) band does not end on a tick")
        #expect(ticks.count >= 4, "\(name) band gives only \(ticks.count) gridlines")
    }
}
