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
