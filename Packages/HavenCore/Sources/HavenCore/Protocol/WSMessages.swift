import Foundation

/// `Hashable` so it can ride inside `HavenOnboardingStep` (which is itself `Hashable` for use as a
/// SwiftUI identity/`Set` element); both stored properties are `String`, so the synthesis is free.
public struct WSError: Sendable, Hashable, Error {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }

    /// The token endpoint rejected the request with a 400/401 body shaped like RFC 6749's
    /// `invalid_grant` — a clear signal the refresh (or authorization) grant is invalid/revoked,
    /// as opposed to a transient network/server failure.
    public static let invalidGrantCode = "invalid_grant"
    public var isInvalidGrant: Bool { code == Self.invalidGrantCode }

    /// Home Assistant's WebSocket layer rejected the access token outright during the auth
    /// handshake.
    public static let authInvalidCode = "auth_invalid"
    public var isAuthInvalid: Bool { code == Self.authInvalidCode }

    /// Home Assistant's own `ERR_UNKNOWN_COMMAND` (`components/websocket_api/const.py`) — the
    /// answer to any command type that isn't registered, because the component providing it isn't
    /// loaded.
    ///
    /// Read as an *answer*, not a failure, in exactly one place:
    /// `NabuCasaRemoteAccessDetector.classify` treats it on `cloud/status` as "the `cloud`
    /// component isn't loaded", i.e. an ordinary self-hosted user. Note the corollary — a
    /// misspelled command name is indistinguishable from a missing component at the wire level, so
    /// every command string this app sends must be verified against its source and asserted in
    /// tests, or "cloud isn't loaded" is what a typo looks like to every Nabu Casa subscriber.
    /// `HavenIntegrationDetector.classify` deliberately does *not* branch on it (see
    /// `HavenIntegrationStatus.commandsUnregistered`), because there `get_config`'s `components`
    /// list is the stronger signal.
    public static let unknownCommandCode = "unknown_command"
    public var isUnknownCommand: Bool { code == Self.unknownCommandCode }
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
    /// Home Assistant's own advertised config, including `internal_url`/`external_url` — how the
    /// instance itself thinks it can be reached, which is how HavenApp discovers a remote/Nabu
    /// Casa address without the user having to type it in. See `HAInstanceConfig`.
    public static func getConfig(id: Int) -> Data { data(["id": id, "type": "get_config"]) }
    /// The `havenapp` integration's capability handshake — only registered once a config entry
    /// for it exists (installing the files via HACS alone does not register it). Onboarding
    /// probes this to detect the integration; see `HavenIntegrationDetector`.
    public static func havenappInfo(id: Int) -> Data { data(["id": id, "type": "havenapp/info"]) }
    /// Home Assistant's own "who am I" command — answerable by *any* authenticated user, whether
    /// or not `havenapp` is installed. Onboarding needs `is_admin` from it to avoid walking a
    /// non-admin through an admin-only HACS/HA step in the branches where `havenapp/info` (and so
    /// its `ha_user_is_admin`) never ran at all. See `HavenIntegrationDetector.classify`'s
    /// `isAdmin` parameter.
    public static func currentUser(id: Int) -> Data { data(["id": id, "type": "auth/current_user"]) }

    /// Home Assistant Cloud's (Nabu Casa's) account/remote-access status — how HavenApp discovers
    /// a remote URL with zero user configuration. Verified against `home-assistant/core`'s
    /// `components/cloud/http_api.py` (`websocket_cloud_status`); the fields consumed are
    /// documented on `HACloudStatus`.
    ///
    /// An instance without the `cloud` component loaded answers this with HA's `unknown_command`
    /// — the self-hosted user, not an error. Which is also why the literal string below is
    /// asserted in `CloudStatusTests`: a typo here would answer `unknown_command` for *everyone*,
    /// and be indistinguishable from a genuinely cloud-less instance.
    public static func cloudStatus(id: Int) -> Data { data(["id": id, "type": "cloud/status"]) }

    /// Turns on Nabu Casa remote access. **MUTATING** — see
    /// `HomeConnection.enableNabuCasaRemoteAccess`, the only call site, and
    /// `NabuCasaRemoteAccessOffer.confirmation`, the only way to reach it: `nil` unless the user has
    /// explicitly confirmed exactly this change. Verified against `home-assistant/core`'s
    /// `components/cloud/http_api.py` (`websocket_remote_connect`). Same corollary as `cloudStatus`
    /// above: a typo here answers `unknown_command`, indistinguishable at the wire level from "the
    /// cloud component isn't loaded", so the literal string is asserted in `CloudStatusTests`.
    public static func cloudRemoteConnect(id: Int) -> Data { data(["id": id, "type": "cloud/remote/connect"]) }

    // MARK: - HACS
    //
    // The three command names below were verified against HACS's own source
    // (`custom_components/hacs/websocket/`), not inferred — note the singular/plural split:
    // `hacs/repositories/…` for list and add, `hacs/repository/…` (singular) for download. HA
    // answers an unknown command with a `unknown_command` error rather than doing anything, so
    // getting one of these wrong is a silent no-op for the user and an easy bug to ship. The
    // exact strings each of these emits are asserted in `HACSRepositoryTests`.

    /// Every repository HACS knows about — *not* only the downloaded ones. Each item carries an
    /// `installed` flag; see `HACSRepository` for why the two lists must never be conflated.
    /// `categories` is optional and narrows the answer (we only ever care about `"integration"`).
    public static func hacsRepositoriesList(id: Int, categories: [String]? = nil) -> Data {
        var body: [String: Any] = ["id": id, "type": "hacs/repositories/list"]
        if let categories { body["categories"] = categories }
        return data(body)
    }

    /// Registers a repository with HACS as a custom repository. `repository` is the GitHub
    /// `owner/repo` string here — unlike `hacsRepositoryDownload`, which takes HACS's own id.
    /// `category` must be lowercase (`"integration"`).
    public static func hacsRepositoriesAdd(id: Int, repository: String, category: String) -> Data {
        data(["id": id, "type": "hacs/repositories/add", "repository": repository, "category": category])
    }

    /// Downloads a repository HACS already knows about. `repository` is HACS's own **id**, not
    /// the `owner/repo` full name (`hacs/repository/info` names the same parameter
    /// `repository_id`, which is what confirms ids are the currency here). Always read the id
    /// back from `hacsRepositoriesList` rather than assuming it — see
    /// `HACSRepositoryIndex.match(fullName:in:)`.
    public static func hacsRepositoryDownload(id: Int, repository: String, version: String? = nil) -> Data {
        var body: [String: Any] = ["id": id, "type": "hacs/repository/download", "repository": repository]
        if let version { body["version"] = version }
        return data(body)
    }

    /// Restarts Home Assistant. Briefly takes the user's whole home offline, so this must only
    /// ever be sent behind an explicit confirmation that says so — see
    /// `HavenOnboardingStep.restartHomeAssistant`'s presentation, whose confirmation copy is
    /// asserted in `HavenOnboardingFlowTests`.
    public static func restartHomeAssistant(id: Int) -> Data {
        data(["id": id, "type": "call_service", "domain": "homeassistant", "service": "restart"])
    }

    /// Asks Home Assistant to start a stream for a camera and hand back a playlist URL.
    ///
    /// Verified against `home-assistant/core`'s `components/camera/__init__.py`
    /// (`ws_camera_stream`): the command is `camera/stream`, it takes `entity_id` and an optional
    /// `format` defaulting to HLS, and it answers `{"url": "/api/hls/…/master_playlist.m3u8"}` —
    /// a **root-relative, already-signed** path, which is what makes it playable by an `AVPlayer`
    /// that cannot carry an `Authorization` header.
    ///
    /// Same corollary as `cloudStatus`: HA answers any unregistered command with
    /// `unknown_command`, so a typo in the literal below would be indistinguishable from a camera
    /// integration that doesn't support streaming — and would silently demote *every* camera to
    /// the still-image fallback. The exact string is asserted in `CameraStreamTests`.
    public static func cameraStream(id: Int, entityId: String, format: String = "hls") -> Data {
        data(["id": id, "type": "camera/stream", "entity_id": entityId, "format": format])
    }

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
              "statistic_ids": [statisticId], "period": period, "types": ["mean", "min", "max", "state", "sum"]])
    }
}
