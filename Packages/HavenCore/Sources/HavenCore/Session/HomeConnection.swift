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
    private let client: HAWebSocketClient
    public init(client: HAWebSocketClient) { self.client = client }

    private func decodeList<T: Decodable>(_ v: JSONValue, as: T.Type) throws -> [T] {
        let data = try JSONEncoder().encode(v)
        return try HACoding.decoder.decode([T].self, from: data)
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
}

extension JSONValue { public var asArray: [JSONValue]? { if case .array(let a) = self { return a }; return nil } }
