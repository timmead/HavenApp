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
@Test func mediaTransportEmitsExplicitPlayAndPause() async throws {
    // Explicit `media_play`/`media_pause` rather than the `media_play_pause` toggle: the caller
    // already knows which direction it is going, and these two map one-to-one onto the two
    // `supported_features` bits the button is gated on.
    let (conn, home) = try await authed()
    try await home.mediaPlay("media_player.kitchen")
    try await home.mediaPause("media_player.kitchen")
    try await home.mediaNextTrack("media_player.kitchen")
    try await home.mediaPreviousTrack("media_player.kitchen")
    let sent = await conn.sentTexts()
    #expect(sent.contains { $0.contains("\"domain\":\"media_player\"") && $0.contains("\"service\":\"media_play\"") })
    #expect(sent.contains { $0.contains("\"service\":\"media_pause\"") })
    #expect(sent.contains { $0.contains("\"service\":\"media_next_track\"") })
    #expect(sent.contains { $0.contains("\"service\":\"media_previous_track\"") })
}
@Test func mediaVolumeMuteAndSourceCarryTheirPayloads() async throws {
    let (conn, home) = try await authed()
    try await home.setMediaVolume("media_player.kitchen", percent: 40)
    try await home.setMediaMuted("media_player.kitchen", muted: true)
    try await home.selectMediaSource("media_player.kitchen", source: "TV")
    let sent = await conn.sentTexts()
    // Percent in, HA's own 0…1 `volume_level` out.
    #expect(sent.contains { $0.contains("\"service\":\"volume_set\"") && $0.contains("\"volume_level\":0.4") })
    #expect(sent.contains { $0.contains("\"service\":\"volume_mute\"") && $0.contains("\"is_volume_muted\":true") })
    #expect(sent.contains { $0.contains("\"service\":\"select_source\"") && $0.contains("\"source\":\"TV\"") })
}
@Test func mediaPowerIsTurnOnOffAndUsesTheEntityPrefixDomain() async throws {
    // The header toggle is power, never play/pause — and the domain comes from the entity id, so a
    // media player behind some other prefix could not be sent to `media_player.turn_off`.
    let (conn, home) = try await authed()
    try await home.setMediaPower("media_player.kitchen", on: false)
    #expect(await conn.sentTexts().contains { $0.contains("\"domain\":\"media_player\"") && $0.contains("\"service\":\"turn_off\"") })
}
@Test func setSwitchUsesEntityPrefixDomain() async throws {
    let (conn, home) = try await authed()
    try await home.setSwitch("input_boolean.guest", on: true)
    #expect(await conn.sentTexts().contains { $0.contains("\"domain\":\"input_boolean\"") })
}
