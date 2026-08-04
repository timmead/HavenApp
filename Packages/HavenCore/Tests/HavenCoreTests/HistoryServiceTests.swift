import Testing
import Foundation
@testable import HavenCore

private func obj(_ d: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
}

/// Replies to whichever frame carries a given `type`; any other framed request (a
/// crossed-branch bug) gets a generic empty-success reply so the test fails an
/// assertion instead of hanging forever waiting for a reply that never comes.
private func respondOnly(_ conn: FakeWebSocketConnection, to expectedType: String, with resultJSON: String) async {
    await conn.setOnSend { d in
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let id = o["id"] as? Int else { return }
        if (o["type"] as? String) == expectedType {
            await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":\#(resultJSON)}"#)
        } else {
            await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":{}}"#)
        }
    }
}

/// An authenticated `HomeConnection` whose every request is answered with `result`.
private func connectedHistoryHome(result: String) async throws
    -> (HomeConnection, FakeWebSocketConnection) {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { data in
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? Int else { return }
        await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":\#(result)}"#)
    }
    return (HomeConnection(client: client), conn)
}

@Test func historyServiceDay() async throws {
    let conn = FakeWebSocketConnection(); let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#); await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await respondOnly(conn, to: "history/history_during_period",
                      with: #"{"sensor.p":[{"s":"124","lu":1751328000.0}]}"#)

    let home = HomeConnection(client: client)
    let s = try await home.history(entityId: "sensor.p", range: .day, now: Date(timeIntervalSince1970: 1751414400))

    #expect(s.points.count == 1); #expect(s.points.first?.value == 124)

    // Prove the day range actually routed to history/history_during_period (not
    // statistics), and that the injected `now:` produces the expected 24h window.
    let sent = await conn.sentTexts()
    let frame = obj(Data(sent.last!.utf8))
    #expect(frame["type"] as? String == "history/history_during_period")
    #expect(frame["start_time"] as? String == "2025-07-01T00:00:00Z")
    #expect(frame["end_time"] as? String == "2025-07-02T00:00:00Z")
}

@Test func historyServiceWeekUsesStatistics() async throws {
    let conn = FakeWebSocketConnection(); let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#); await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await respondOnly(conn, to: "recorder/statistics_during_period",
                      with: #"{"sensor.p":[{"start":1751328000000,"mean":100.0,"min":10.0,"max":300.0}]}"#)

    let home = HomeConnection(client: client)
    let s = try await home.history(entityId: "sensor.p", range: .week, now: Date(timeIntervalSince1970: 1751414400))

    // Proves fromStatistics (not fromHistory) was applied: the mean becomes the point
    // value, and the row-level max (300.0) is surfaced distinctly from the mean series.
    #expect(s.points.count == 1); #expect(s.points.first?.value == 100.0)
    #expect(s.max == 300.0)

    let sent = await conn.sentTexts()
    let frame = obj(Data(sent.last!.utf8))
    #expect(frame["type"] as? String == "recorder/statistics_during_period")
    #expect(frame["period"] != nil)
}

/// An attribute source needs the attributes, so this request must *not* carry the
/// `no_attributes`/`minimal_response` flags the state path uses — with them, HA sends no `a`
/// key and every row is dropped, giving a permanently empty chart with no error anywhere.
@Test func attributeHistoryRequestsAttributes() async throws {
    let (home, conn) = try await connectedHistoryHome(
        result: #"{"climate.lr":[{"s":"heat","a":{"current_temperature":20.5},"lu":1751328000.0}]}"#)
    let series = try await home.history(entityId: "climate.lr", attribute: "current_temperature",
                                        range: .day, now: Date(timeIntervalSince1970: 1751331600))
    #expect(series.points.first?.value == 20.5)

    let frames = await conn.sentTexts().compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
    let request = try #require(frames.first { $0["type"] as? String == "history/history_during_period" })
    #expect(request["no_attributes"] as? Bool == false)
    #expect(request["minimal_response"] as? Bool == false)
}

/// The state path is unchanged — every existing caller (SensorModal) still gets the compact
/// response it has always had.
@Test func stateHistoryStillRequestsTheCompactResponse() async throws {
    let (home, conn) = try await connectedHistoryHome(
        result: #"{"sensor.t":[{"s":"21.5","lu":1751328000.0}]}"#)
    _ = try await home.history(entityId: "sensor.t", range: .day,
                               now: Date(timeIntervalSince1970: 1751331600))
    let frames = await conn.sentTexts().compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
    let request = try #require(frames.first { $0["type"] as? String == "history/history_during_period" })
    #expect(request["no_attributes"] as? Bool == true)
    #expect(request["minimal_response"] as? Bool == true)
}

/// Long-term statistics are keyed by entity and derived from its *state*, so no attribute has
/// them at any range. Firing the request anyway would spend a round trip to be told `{}`, and
/// — worse — `fromStatistics` would read the *entity's* statistics if the entity happened to
/// have some, plotting an unrelated number as the room's temperature.
@Test func attributeHistoryBeyondADayIsEmptyWithoutARequest() async throws {
    let (home, conn) = try await connectedHistoryHome(result: #"{}"#)
    for range in HistoryRange.allCases where range.usesStatistics {
        let series = try await home.history(entityId: "climate.lr", attribute: "current_temperature",
                                            range: range, now: Date(timeIntervalSince1970: 1751331600))
        #expect(series.points.isEmpty)
        #expect(series.min == nil)
    }
    #expect(await conn.sentTexts().allSatisfy { !$0.contains("statistics_during_period") })
}

// MARK: - Several entities in one request

/// **One frame, one series per entity.** Six sparklines on a dashboard was six round trips for one
/// glance; `entity_ids` was always a list and the reply was always keyed by entity id.
@Test func severalEntitiesTravelInOneRequest() async throws {
    let conn = FakeWebSocketConnection(); let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#); await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await respondOnly(conn, to: "history/history_during_period",
                      with: #"{"sensor.a":[{"s":"1","lu":1751328000.0}],"sensor.b":[{"s":"2","lu":1751328000.0},{"s":"3","lu":1751331600.0}]}"#)

    let home = HomeConnection(client: client)
    let out = try await home.histories(entityIds: ["sensor.a", "sensor.b"], range: .day,
                                       now: Date(timeIntervalSince1970: 1751414400))

    #expect(out["sensor.a"]?.points.map(\.value) == [1])
    #expect(out["sensor.b"]?.points.map(\.value) == [2, 3])

    let frames = await conn.sentTexts().map { obj(Data($0.utf8)) }
        .filter { $0["type"] as? String == "history/history_during_period" }
    #expect(frames.count == 1)
    #expect(frames.first?["entity_ids"] as? [String] == ["sensor.a", "sensor.b"])
}

/// **An entity the recorder has nothing for comes back empty, not missing.**
///
/// A caller that asked for three and got two keys back cannot tell "no data" from "the request lost
/// it", so it would keep asking forever. An empty series is an answer; an absent key is a question.
@Test func anEntityWithNoRowsComesBackEmptyRatherThanAbsent() async throws {
    let conn = FakeWebSocketConnection(); let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#); await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await respondOnly(conn, to: "history/history_during_period",
                      with: #"{"sensor.a":[{"s":"1","lu":1751328000.0}]}"#)

    let home = HomeConnection(client: client)
    let out = try await home.histories(entityIds: ["sensor.a", "sensor.excluded"], range: .day,
                                       now: Date(timeIntervalSince1970: 1751414400))

    #expect(out.count == 2)
    #expect(out["sensor.excluded"]?.points.isEmpty == true)
}

/// Asking for nothing sends nothing — a screen with no sparklines must not produce an empty frame.
@Test func anEmptyBatchMakesNoRequest() async throws {
    let conn = FakeWebSocketConnection(); let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#); await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")

    let home = HomeConnection(client: client)
    let out = try await home.histories(entityIds: [], range: .day, now: Date())

    #expect(out.isEmpty)
    let frames = await conn.sentTexts().map { obj(Data($0.utf8)) }
        .filter { $0["type"] as? String == "history/history_during_period" }
    #expect(frames.isEmpty)
}

/// **A statistics range must not be answered with a history command.** Both return a series, so the
/// mistake is invisible in the result — it shows up only as a wrong window, which is worse than an
/// error. `.week` is served one entity at a time, correctly, rather than quickly.
@Test func aStatisticsRangeIsNotSentAsAHistoryCommand() async throws {
    let conn = FakeWebSocketConnection(); let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#); await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await respondOnly(conn, to: "recorder/statistics_during_period",
                      with: #"{"sensor.a":[{"start":1751328000000,"mean":5.0}]}"#)

    let home = HomeConnection(client: client)
    _ = try await home.histories(entityIds: ["sensor.a"], range: .week,
                                 now: Date(timeIntervalSince1970: 1751414400))

    let types = await conn.sentTexts().map { obj(Data($0.utf8))["type"] as? String }
    #expect(types.contains("recorder/statistics_during_period"))
    #expect(!types.contains("history/history_during_period"))
}
