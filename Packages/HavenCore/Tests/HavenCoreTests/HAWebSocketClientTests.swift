import Testing
import Foundation
@testable import HavenCore

@Test func authHandshakeSendsTokenAfterAuthRequired() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "tok")
    let texts = await conn.sentTexts()
    #expect(texts.contains { $0.contains("\"type\":\"auth\"") && $0.contains("tok") })
}

@Test func authInvalidThrows() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_invalid","error":{"code":"x","message":"bad"}}"#)
    await #expect(throws: (any Error).self) { try await client.authenticate(token: "tok") }
}

@Test func requestCorrelatesResultById() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    // When the client sends a command, reply with a success result for its id.
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let id = obj?["id"] as? Int, obj?["type"] as? String == "get_states" {
            await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":[1,2,3]}"#)
        }
    }
    let result = try await client.request { WSCommand.getStates(id: $0) }
    #expect(result.asArray?.count == 3)
}
