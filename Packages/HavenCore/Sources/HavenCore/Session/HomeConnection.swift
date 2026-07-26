import Foundation

public struct HAConfig: Sendable {
    public let baseURL: URL
    public init(baseURL: URL) { self.baseURL = baseURL }
    public var webSocketURL: URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.scheme = (baseURL.scheme == "https") ? "wss" : "ws"
        c.path = "/api/websocket"
        return c.url!
    }
}

public actor HomeConnection {
    let client: HAWebSocketClient
    public init(client: HAWebSocketClient) { self.client = client }

    private func decodeList<T: Decodable>(_ v: JSONValue, as: T.Type) throws -> [T] {
        let data = try JSONEncoder().encode(v)
        return try HACoding.decoder.decode([T].self, from: data)
    }

    /// Asks the instance for its own advertised `internal_url`/`external_url` via `get_config`.
    /// `AppModel` calls this once after a successful connection and persists whatever it learns,
    /// so a later cold launch away from home can go straight to the remote URL instead of
    /// waiting on a local connection attempt to fail first.
    ///
    /// Deliberately uses a plain `JSONDecoder`, *not* `HACoding.decoder` — that decoder's
    /// `.convertFromSnakeCase` strategy rewrites `internal_url` to `internalUrl` before matching
    /// against `CodingKeys`, which would silently defeat `HAInstanceConfig`'s explicit
    /// `internal_url`/`external_url` keys and decode both URLs as `nil`.
    public func fetchInstanceConfig() async throws -> HAInstanceConfig {
        let v = try await client.request { WSCommand.getConfig(id: $0) }
        let data = try JSONEncoder().encode(v)
        let config = try JSONDecoder().decode(HAInstanceConfig.self, from: data)
        // Same discipline as `AppModel.rememberDiscoveredURLs`'s both-URLs-nil warning: this
        // wire shape (get_config's `components` field) has never been verified against a live
        // response, so if the assumption is wrong, this is how it would otherwise silently
        // degrade `HavenIntegrationDetector.classify` into confidently telling a fully-configured
        // user to go install HACS (see `HavenIntegrationStatus.indeterminate`). A `nil` or empty
        // list here is exactly the condition that produces that case, so it's logged loudly at
        // the earliest possible point — this decode — rather than left to surface only once
        // onboarding acts on it.
        if config.components?.isEmpty ?? true {
            havenCoreLog.error("get_config's components list was missing or empty — havenapp/HACS presence cannot be determined from this response alone; onboarding will fall back to the havenapp/info probe result")
        }
        return config
    }

    public func loadStructure() async throws -> ResolvedHome {
        async let floorsV = client.request { WSCommand.registryList(id: $0, type: "config/floor_registry/list") }
        async let areasV  = client.request { WSCommand.registryList(id: $0, type: "config/area_registry/list") }
        async let devsV   = client.request { WSCommand.registryList(id: $0, type: "config/device_registry/list") }
        async let entsV   = client.request { WSCommand.registryList(id: $0, type: "config/entity_registry/list") }
        let floors = try await decodeList(floorsV, as: FloorRegistryEntry.self)
        let areas  = try await decodeList(areasV, as: AreaRegistryEntry.self)
        let devices = try await decodeList(devsV, as: DeviceRegistryEntry.self)
        let entities = try await decodeList(entsV, as: EntityRegistryEntry.self)
        return RegistryResolver.resolve(floors: floors, areas: areas, devices: devices, entities: entities)
    }

    public func loadStates() async throws -> [EntityState] {
        let v = try await client.request { WSCommand.getStates(id: $0) }
        return (v.asArray ?? []).compactMap { StateChangedEvent.parseState($0) }
    }

    public func subscribeStateChanges() async throws -> AsyncStream<EntityState> {
        _ = try await client.request { WSCommand.subscribeEvents(id: $0, eventType: "state_changed") }
        let events = await client.events
        return AsyncStream { cont in
            let task = Task {
                for await frame in events {
                    if case let .event(_, payload) = frame,
                       let sc = try? StateChangedEvent(eventPayload: payload),
                       let st = sc.newState {
                        cont.yield(st)
                    }
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    public func toggleLight(entityId: String) async throws {
        _ = try await client.request { WSCommand.callService(id: $0, domain: "light", service: "toggle", entityId: entityId) }
    }

    /// Tears down the underlying WebSocket client — cancels its heartbeat/receive loops and
    /// closes the socket. Must be called before a `HomeConnection` for a session that reached
    /// `.ready` is dropped (e.g. on sign-out), or the client — and its 10s heartbeat timer —
    /// leaks for as long as the process runs, since nothing else retains or disconnects it once
    /// this actor's reference goes away.
    public func disconnect() async {
        await client.disconnect()
    }
}

extension JSONValue { public var asArray: [JSONValue]? { if case .array(let a) = self { return a }; return nil } }
