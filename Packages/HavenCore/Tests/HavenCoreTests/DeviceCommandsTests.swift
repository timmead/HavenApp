import Testing
import Foundation
@testable import HavenCore

private func authed() async throws -> (FakeWebSocketConnection, HomeConnection) {
    let conn = FakeWebSocketConnection(); let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#); await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { d in
        if let o = try? JSONSerialization.jsonObject(with: d) as? [String:Any], let id = o["id"] as? Int, o["type"] as? String == "call_service" {
            await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":null}"#)
        }
    }
    return (conn, HomeConnection(client: client))
}

@Test func setBrightnessEmitsTurnOnWithPct() async throws {
    let (conn, home) = try await authed()
    try await home.setBrightness("light.k", percent: 60)
    let sent = await conn.sentTexts()
    #expect(sent.contains { $0.contains("\"service\":\"turn_on\"") && $0.contains("brightness_pct") && $0.contains("60") })
}
@Test func closeCoverEmitsService() async throws {
    let (conn, home) = try await authed()
    try await home.closeCover("cover.b")
    #expect(await conn.sentTexts().contains { $0.contains("\"domain\":\"cover\"") && $0.contains("close_cover") })
}
@Test func lockEmitsService() async throws {
    let (conn, home) = try await authed()
    try await home.setLock("lock.f", locked: true)
    #expect(await conn.sentTexts().contains { $0.contains("\"domain\":\"lock\"") && $0.contains("\"service\":\"lock\"") })
}
@Test func activateUsesEntityPrefixDomain() async throws {
    let (conn, home) = try await authed()
    try await home.activate(sceneOrScript: "input_button.doorbell")
    let sent = await conn.sentTexts()
    #expect(sent.contains { $0.contains("\"domain\":\"input_button\"") && $0.contains("\"service\":\"press\"") })
}
@Test func activateSceneAndScript() async throws {
    let (conn, home) = try await authed()
    try await home.activate(sceneOrScript: "scene.movie")
    try await home.activate(sceneOrScript: "script.bedtime")
    let sent = await conn.sentTexts()
    #expect(sent.contains { $0.contains("\"domain\":\"scene\"") && $0.contains("\"service\":\"turn_on\"") })
    #expect(sent.contains { $0.contains("\"domain\":\"script\"") && $0.contains("\"service\":\"turn_on\"") })
}
@Test func setSwitchUsesEntityPrefixDomain() async throws {
    let (conn, home) = try await authed()
    try await home.setSwitch("input_boolean.guest", on: true)
    #expect(await conn.sentTexts().contains { $0.contains("\"domain\":\"input_boolean\"") })
}
