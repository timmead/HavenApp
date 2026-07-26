import Testing
import Foundation
@testable import HavenCore

@Test func webSocketURLDerivation() {
    let cfg = HAConfig(baseURL: URL(string: "https://ha.example:8123")!)
    #expect(cfg.webSocketURL.absoluteString == "wss://ha.example:8123/api/websocket")
    let local = HAConfig(baseURL: URL(string: "http://homeassistant.local:8123")!)
    #expect(local.webSocketURL.absoluteString == "ws://homeassistant.local:8123/api/websocket")
}

@Test func loadStructureParsesRegistries() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["id"] as? Int, let type = obj?["type"] as? String else { return }
        let payloads: [String: String] = [
            "config/floor_registry/list": #"[{"floor_id":"f1","name":"Ground","level":0}]"#,
            "config/area_registry/list": #"[{"area_id":"a1","name":"Kitchen","floor_id":"f1"}]"#,
            "config/device_registry/list": #"[{"id":"d1","area_id":"a1"}]"#,
            "config/entity_registry/list": #"[{"entity_id":"light.k","device_id":"d1"}]"#,
        ]
        if let body = payloads[type] {
            await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":\#(body)}"#)
        }
    }
    let home = HomeConnection(client: client)
    let structure = try await home.loadStructure()
    #expect(structure.floors.first?.areas.first?.entityIds == ["light.k"])
}

@Test func fetchInstanceConfigDecodesInternalAndExternalURLs() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["id"] as? Int, obj?["type"] as? String == "get_config" else { return }
        let body = #"{"internal_url":"http://192.168.1.42:8123","external_url":"https://abc123.ui.nabu.casa"}"#
        await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":\#(body)}"#)
    }
    let home = HomeConnection(client: client)
    let config = try await home.fetchInstanceConfig()
    #expect(config.internalURL == URL(string: "http://192.168.1.42:8123"))
    #expect(config.externalURL == URL(string: "https://abc123.ui.nabu.casa"))
}

@Test func fetchInstanceConfigToleratesMissingURLs() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["id"] as? Int, obj?["type"] as? String == "get_config" else { return }
        let body = #"{"internal_url":null,"external_url":null,"location_name":"Home"}"#
        await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":\#(body)}"#)
    }
    let home = HomeConnection(client: client)
    let config = try await home.fetchInstanceConfig()
    #expect(config.internalURL == nil)
    #expect(config.externalURL == nil)
}

@Test func homeConnectionDisconnectReachesTheUnderlyingClient() async throws {
    // Guards the sign-out-of-a-working-session leak: HomeConnection.disconnect() must actually
    // forward to HAWebSocketClient.disconnect(), which is what closes the underlying socket.
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    let home = HomeConnection(client: client)

    #expect(conn.closedFlag.closed == false)
    await home.disconnect()
    #expect(conn.closedFlag.closed == true)
}
