import Testing
import Foundation
@testable import HavenCore

@Test func rangeMapping() {
    #expect(HistoryRange.day.usesStatistics == false)
    #expect(HistoryRange.month.usesStatistics)
    #expect(HistoryRange.threeMonths.label == "3M")
    #expect(HistoryRange.allCases.count == 5)
}

@Test func parseStatistics() {
    let json = #"{"sensor.p":[{"start":1751328000000,"mean":100.0,"min":10.0,"max":300.0},{"start":1751331600000,"mean":120.0}]}"#
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(json.utf8))
    let s = HistoryParsing.fromStatistics(v, statisticId: "sensor.p")
    #expect(s.points.count == 2); #expect(s.points.first?.value == 100.0); #expect(s.max == 300.0)
}

@Test func parseRawHistory() {
    let json = #"{"sensor.p":[{"s":"124","lu":1751328000.0},{"s":"nan","lu":1751328600.0},{"s":"130","lu":1751329200.0}]}"#
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(json.utf8))
    let s = HistoryParsing.fromHistory(v, entityId: "sensor.p")
    #expect(s.points.count == 2)   // non-numeric "nan" dropped
    #expect(s.points.first?.value == 124)
}

@Test func statisticsConvertsMillisecondsAndCarriesMinMax() {
    let json = #"{"sensor.p":[{"start":1751328000000,"mean":100.0,"min":10.0,"max":300.0}]}"#
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(json.utf8))
    let s = HistoryParsing.fromStatistics(v, statisticId: "sensor.p")
    #expect(s.points.first?.time == Date(timeIntervalSince1970: 1751328000))
    #expect(s.min == 10.0)
    #expect(s.max == 300.0)
}

@Test func rawHistoryUsesSecondsEpoch() {
    let json = #"{"sensor.p":[{"s":"124","lu":1751328000.0}]}"#
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(json.utf8))
    let s = HistoryParsing.fromHistory(v, entityId: "sensor.p")
    #expect(s.points.first?.time == Date(timeIntervalSince1970: 1751328000))
}

@Test func rawHistoryDropsNonFiniteAndNonNumericStates() {
    let json = #"{"sensor.p":[{"s":"inf","lu":1.0},{"s":"unavailable","lu":2.0},{"s":"unknown","lu":3.0},{"s":"","lu":4.0},{"s":"7","lu":5.0}]}"#
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(json.utf8))
    let s = HistoryParsing.fromHistory(v, entityId: "sensor.p")
    #expect(s.points.count == 1)
    #expect(s.points.first?.value == 7)
}

@Test func statisticsWithNoPlottableRowsYieldsEmptySeriesWithNoMinMax() {
    // no mean, no state, no sum -> nothing plottable, so min/max must stay nil
    let json = #"{"sensor.p":[{"start":1751328000000,"min":1.0,"max":2.0}]}"#
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(json.utf8))
    let s = HistoryParsing.fromStatistics(v, statisticId: "sensor.p")
    #expect(s.points.isEmpty)
    #expect(s.min == nil)
    #expect(s.max == nil)
}

@Test func statisticsSumOnlyRowYieldsAPoint() {
    // total/total_increasing (energy) sensors report `sum`, not `mean`/`state`.
    let json = #"{"sensor.p":[{"start":1751328000000,"sum":9.0}]}"#
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(json.utf8))
    let s = HistoryParsing.fromStatistics(v, statisticId: "sensor.p")
    #expect(s.points.count == 1)
    #expect(s.points.first?.value == 9.0)
}

@Test func statisticsParsesISO8601StringStart() {
    // Modern HA (2026.x) returns statistics `start` as an ISO-8601 string, not a ms epoch.
    let json = #"{"sensor.p":[{"start":"2026-07-25T10:00:00+00:00","mean":42.5}]}"#
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(json.utf8))
    let s = HistoryParsing.fromStatistics(v, statisticId: "sensor.p")
    #expect(s.points.count == 1)
    #expect(s.points.first?.value == 42.5)
    let expected = ISO8601DateFormatter().date(from: "2026-07-25T10:00:00+00:00")
    #expect(s.points.first?.time == expected)
}

@Test func statisticsParsesISO8601StringStartWithFractionalSeconds() {
    let json = #"{"sensor.p":[{"start":"2026-07-25T10:00:00.123+00:00","mean":7.0}]}"#
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(json.utf8))
    let s = HistoryParsing.fromStatistics(v, statisticId: "sensor.p")
    #expect(s.points.count == 1)
    #expect(s.points.first?.value == 7.0)
}

@Test func statisticsNumericMsStartStillParses() {
    // Regression guard: existing ms-epoch-number behaviour must keep working.
    let json = #"{"sensor.p":[{"start":1751328000000,"mean":100.0}]}"#
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(json.utf8))
    let s = HistoryParsing.fromStatistics(v, statisticId: "sensor.p")
    #expect(s.points.count == 1)
    #expect(s.points.first?.time == Date(timeIntervalSince1970: 1751328000))
    #expect(s.points.first?.value == 100.0)
}

@Test func malformedPayloadsDegradeToEmptySeries() {
    func series(_ raw: String) -> HistorySeries {
        let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(raw.utf8))
        return HistoryParsing.fromHistory(v, entityId: "sensor.p")
    }
    #expect(series("{}").points.isEmpty)
    #expect(series(#"{"sensor.p":null}"#).points.isEmpty)
    #expect(series(#"{"other.entity":[{"s":"1","lu":1.0}]}"#).points.isEmpty)
}
