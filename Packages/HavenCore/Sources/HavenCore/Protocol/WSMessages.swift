import Foundation

public struct WSError: Sendable, Equatable, Error {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}

public enum ServerFrame: Sendable, Equatable {
    case authRequired, authOK
    case authInvalid(String)
    case result(id: Int, success: Bool, result: JSONValue?, error: WSError?)
    case event(id: Int, event: JSONValue)
    case pong(id: Int)

    public static func decode(_ text: String) throws -> ServerFrame {
        try decode(Data(text.utf8))
    }
    public static func decode(_ data: Data) throws -> ServerFrame {
        struct Raw: Decodable {
            let id: Int?; let type: String; let success: Bool?
            let result: JSONValue?; let event: JSONValue?
            struct E: Decodable { let code: String; let message: String }
            let error: E?
        }
        // NB: use a plain decoder (no snake_case) so nested attribute keys survive verbatim.
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        switch raw.type {
        case "auth_required": return .authRequired
        case "auth_ok": return .authOK
        case "auth_invalid": return .authInvalid(raw.error?.message ?? "invalid")
        case "pong": return .pong(id: raw.id ?? 0)
        case "event": return .event(id: raw.id ?? 0, event: raw.event ?? .null)
        case "result":
            return .result(id: raw.id ?? 0, success: raw.success ?? false, result: raw.result,
                           error: raw.error.map { WSError(code: $0.code, message: $0.message) })
        default: return .result(id: raw.id ?? 0, success: raw.success ?? false, result: raw.result, error: nil)
        }
    }
}

public struct StateChangedEvent: Sendable {
    public let entityId: String
    public let newState: EntityState?
    public init(eventPayload: JSONValue) throws {
        guard let data = eventPayload.asObject?["data"]?.asObject else {
            throw WSError(code: "bad_event", message: "missing data")
        }
        self.entityId = data["entity_id"]?.asString ?? ""
        self.newState = Self.parseState(data["new_state"])
    }
    static func parseState(_ v: JSONValue?) -> EntityState? {
        guard let o = v?.asObject, let eid = o["entity_id"]?.asString, let st = o["state"]?.asString
        else { return nil }
        let attrs = o["attributes"]?.asObject ?? [:]
        let date = o["last_updated"]?.asString.flatMap(ISO8601Helper.date(from:)) ?? Date()
        return EntityState(entityId: eid, state: st, attributes: attrs, lastUpdated: date)
    }
}

enum ISO8601Helper {
    nonisolated(unsafe) static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func date(from s: String) -> Date? { fmt.date(from: s) }
}

public enum WSCommand {
    private static func data(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }
    private static func plain(_ v: JSONValue) -> Any {
        switch v {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let a): return a.map(plain)
        case .object(let o): return o.mapValues(plain)
        case .null: return NSNull()
        }
    }
    public static func auth(token: String) -> Data { data(["type": "auth", "access_token": token]) }
    public static func ping(id: Int) -> Data { data(["id": id, "type": "ping"]) }
    public static func getStates(id: Int) -> Data { data(["id": id, "type": "get_states"]) }
    public static func registryList(id: Int, type: String) -> Data { data(["id": id, "type": type]) }
    public static func subscribeEvents(id: Int, eventType: String) -> Data {
        data(["id": id, "type": "subscribe_events", "event_type": eventType])
    }
    public static func callService(id: Int, domain: String, service: String, entityId: String) -> Data {
        data(["id": id, "type": "call_service", "domain": domain, "service": service,
              "target": ["entity_id": entityId]])
    }
    public static func callService(id: Int, domain: String, service: String, entityId: String,
                                   serviceData: [String: JSONValue]) -> Data {
        data(["id": id, "type": "call_service", "domain": domain, "service": service,
              "target": ["entity_id": entityId], "service_data": serviceData.mapValues(plain)])
    }
    public static func historyDuringPeriod(id: Int, entityId: String, startISO: String, endISO: String) -> Data {
        data(["id": id, "type": "history/history_during_period", "start_time": startISO, "end_time": endISO,
              "entity_ids": [entityId], "minimal_response": true, "no_attributes": true])
    }
    public static func statisticsDuringPeriod(id: Int, statisticId: String, startISO: String, endISO: String, period: String) -> Data {
        data(["id": id, "type": "recorder/statistics_during_period", "start_time": startISO, "end_time": endISO,
              "statistic_ids": [statisticId], "period": period, "types": ["mean", "min", "max"]])
    }
}
