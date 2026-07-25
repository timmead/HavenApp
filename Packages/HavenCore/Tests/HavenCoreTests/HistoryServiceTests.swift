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
