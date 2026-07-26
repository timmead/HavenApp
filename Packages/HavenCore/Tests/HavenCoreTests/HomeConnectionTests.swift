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

@Test func fetchInstanceConfigDecodesComponentsWhenPresent() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["id"] as? Int, obj?["type"] as? String == "get_config" else { return }
        let body = #"{"internal_url":null,"external_url":null,"components":["hacs","havenapp","light"]}"#
        await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":\#(body)}"#)
    }
    let home = HomeConnection(client: client)
    let config = try await home.fetchInstanceConfig()
    #expect(config.components == ["hacs", "havenapp", "light"])
}

@Test func fetchInstanceConfigYieldsNilComponentsWhenTheKeyIsAbsent() async throws {
    // Guards both existing URL-only fixtures above (neither mentions "components" at all) and
    // any payload from before this field existed: it must decode to `nil`, never throw a
    // missing-key error — but also never silently become `[]`. A missing key and a genuinely
    // empty list are different facts (see `HAInstanceConfig.components`'s documentation): only
    // `nil` says "we don't know," which is exactly what `HavenIntegrationDetector.classify` needs
    // to tell apart from a real, populated components list before it can trust it at all.
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["id"] as? Int, obj?["type"] as? String == "get_config" else { return }
        let body = #"{"internal_url":null,"external_url":null}"#
        await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":\#(body)}"#)
    }
    let home = HomeConnection(client: client)
    let config = try await home.fetchInstanceConfig()
    #expect(config.components == nil)
}

@Test func fetchIntegrationInfoDecodesASuccessfulProbe() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["id"] as? Int, obj?["type"] as? String == "havenapp/info" else { return }
        let body = #"{"integration_version":"0.1.0","schema_version":1,"capabilities":["config.v1"],"ha_user_is_admin":true}"#
        await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":\#(body)}"#)
    }
    let home = HomeConnection(client: client)
    let result = await home.fetchIntegrationInfo()
    #expect(result == .success(HavenIntegrationInfo(
        integrationVersion: "0.1.0", schemaVersion: 1, capabilities: ["config.v1"], haUserIsAdmin: true
    )))
}

@Test func fetchIntegrationInfoPassesAnHAErrorThroughAsFailure() async throws {
    // The unregistered-command case: havenapp isn't loaded at all, so HA answers with its own
    // generic error rather than one of the integration's own error codes.
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["id"] as? Int, obj?["type"] as? String == "havenapp/info" else { return }
        let body = #"{"id":\#(id),"type":"result","success":false,"error":{"code":"unknown_command","message":"nope"}}"#
        await conn.enqueueIncoming(body)
    }
    let home = HomeConnection(client: client)
    let result = await home.fetchIntegrationInfo()
    #expect(result == .failure(WSError(code: "unknown_command", message: "nope")))
}

@Test func fetchIntegrationInfoNormalizesAMalformedPayloadToProbeFailed() async throws {
    // A real wire condition, not just a hypothetical: an older/broken integration answering
    // `havenapp/info` with a result that doesn't decode as `HavenIntegrationInfo` (here missing
    // `capabilities` and `ha_user_is_admin` entirely). This must not throw out of
    // `fetchIntegrationInfo`, and must not surface as some ad-hoc DecodingError-shaped code —
    // it collapses to the same fixed `probe_failed` code any other non-WSError failure gets.
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["id"] as? Int, obj?["type"] as? String == "havenapp/info" else { return }
        let body = #"{"schema_version":1}"#
        await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":\#(body)}"#)
    }
    let home = HomeConnection(client: client)
    let result = await home.fetchIntegrationInfo()
    guard case .failure(let error) = result else {
        Issue.record("expected a decode failure to surface as .failure, got \(result)")
        return
    }
    #expect(error.code == "probe_failed")
}

@Test func normalizeWrapsANonWSErrorInAFixedCode() {
    // A DecodingError (or any other transport-layer failure) must not leak its own shape into
    // `HavenIntegrationDetector.classify`, which only ever branches on the `commandsUnregistered`
    // case existing at all, never on a specific error code.
    struct SomeOtherError: Error {}
    let normalized = HomeConnection.normalize(SomeOtherError())
    #expect(normalized.code == "probe_failed")
}

@Test func normalizePassesAWSErrorThroughUnchanged() {
    let original = WSError(code: "version_conflict", message: "too new")
    #expect(HomeConnection.normalize(original) == original)
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
