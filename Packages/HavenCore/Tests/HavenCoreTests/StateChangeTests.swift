import Testing
import Foundation
@testable import HavenCore

/// A binary sensor's history is a sequence of state *strings* — "on"/"off", or device-class words
/// like "open"/"closed". `HistoryParsing.fromHistory` drops every one of them, because it parses
/// each row's state as a `Double`. That is why this parser exists rather than reusing it.
@Test func stateChangesKeepsTheStateStrings() {
    let json = #"{"binary_sensor.door":[{"s":"off","lu":1751328000.0},{"s":"on","lu":1751331600.0}]}"#
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(json.utf8))
    let changes = HistoryParsing.stateChanges(v, entityId: "binary_sensor.door")
    // Newest first: "on" (1751331600) is an hour after "off" (1751328000), so it comes first.
    #expect(changes.map(\.state) == ["on", "off"])
    #expect(changes.last?.time == Date(timeIntervalSince1970: 1751328000))
}

/// Newest first — the modal shows "what happened recently", and a reader starts at the top.
@Test func stateChangesAreNewestFirst() {
    let json = #"""
    {"binary_sensor.door":[{"s":"off","lu":100.0},{"s":"on","lu":200.0},{"s":"off","lu":300.0}]}
    """#
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(json.utf8))
    #expect(HistoryParsing.stateChanges(v, entityId: "binary_sensor.door").map(\.time)
            == [Date(timeIntervalSince1970: 300), Date(timeIntervalSince1970: 200),
                Date(timeIntervalSince1970: 100)])
}

/// `unavailable` and `unknown` are not events — a door that went offline did not open. Dropping
/// them keeps the list about the thing the sensor senses.
@Test func stateChangesDropsUnavailableRows() {
    let json = #"""
    {"binary_sensor.door":[{"s":"on","lu":100.0},{"s":"unavailable","lu":200.0},
                           {"s":"unknown","lu":300.0},{"s":"off","lu":400.0}]}
    """#
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(json.utf8))
    #expect(HistoryParsing.stateChanges(v, entityId: "binary_sensor.door").map(\.state) == ["off", "on"])
}

/// Home Assistant records a row per *update*, not per *change*, so a sensor that reports "off"
/// every 30 seconds yields hundreds of identical rows. Collapsing runs is what makes this a list
/// of events rather than a log.
@Test func stateChangesCollapsesConsecutiveRepeats() {
    let json = #"""
    {"binary_sensor.door":[{"s":"off","lu":100.0},{"s":"off","lu":150.0},{"s":"on","lu":200.0},
                           {"s":"on","lu":250.0},{"s":"off","lu":300.0}]}
    """#
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(json.utf8))
    let changes = HistoryParsing.stateChanges(v, entityId: "binary_sensor.door")
    #expect(changes.map(\.state) == ["off", "on", "off"])
    // The *first* row of each run is the moment it changed — not the last.
    #expect(changes.map(\.time) == [Date(timeIntervalSince1970: 300), Date(timeIntervalSince1970: 200),
                                    Date(timeIntervalSince1970: 100)])
}

/// A run broken only by an `unavailable`/`unknown` gap must read as one continuous state, not
/// as a change-away-and-back. This is the property `stateChangesDropsUnavailableRows` looks
/// like it covers but doesn't: there the gap is followed by a *different* state
/// (`on → unavailable → unknown → off`), which a naive "compare to the immediately preceding
/// *row*" implementation would pass just as happily as the real one. Here the gap is followed
/// by the *same* state on both sides (`on → unavailable → on`, and again `on → unknown → on`):
/// a naive implementation would see the row after the gap differ from the raw previous row
/// (`unavailable`/`unknown`) and record a spurious second "on" transition after each outage. The
/// real parser compares against the last *kept* row, so a door sensor that drops offline and
/// comes back to the same reading emits nothing extra — only the eventual real change to "off"
/// produces a second entry.
@Test func stateChangesTreatsAGapAsAContinuationNotAChange() {
    let json = #"""
    {"binary_sensor.door":[{"s":"on","lu":100.0},{"s":"unavailable","lu":200.0},
                           {"s":"on","lu":300.0},{"s":"unknown","lu":400.0},
                           {"s":"on","lu":500.0},{"s":"off","lu":600.0}]}
    """#
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(json.utf8))
    let changes = HistoryParsing.stateChanges(v, entityId: "binary_sensor.door")
    #expect(changes.map(\.state) == ["off", "on"])
    // The surviving "on" entry is the *first* row of the run (100) — the moment it actually
    // changed — not the row that happens to follow either gap (300 or 500).
    #expect(changes.map(\.time) == [Date(timeIntervalSince1970: 600), Date(timeIntervalSince1970: 100)])
}

@Test func stateChangesOfAnAbsentEntityIsEmpty() {
    let v = try! HACoding.decoder.decode(JSONValue.self, from: Data(#"{}"#.utf8))
    #expect(HistoryParsing.stateChanges(v, entityId: "binary_sensor.door").isEmpty)
}
