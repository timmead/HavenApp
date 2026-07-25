import Testing
import Foundation
@testable import HavenCore

@Test func historyServiceDay() async throws {
    let conn = FakeWebSocketConnection(); let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#); await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { d in
        if let o = try? JSONSerialization.jsonObject(with: d) as? [String:Any], let id = o["id"] as? Int,
           (o["type"] as? String) == "history/history_during_period" {
            await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":{"sensor.p":[{"s":"124","lu":1751328000.0}]}}"#)
        }
    }
    let home = HomeConnection(client: client)
    let s = try await home.history(entityId: "sensor.p", range: .day, now: Date(timeIntervalSince1970: 1751414400))
    #expect(s.points.count == 1); #expect(s.points.first?.value == 124)
}
