import Foundation

/// One record from the `havenapp` integration's scoped configuration store.
///
/// This is Haven's own configuration layer, deliberately *not* a second copy of anything Home
/// Assistant owns: HA remains the source of truth for devices, entities, their readings and where
/// they live. What lives here is the thin dashboard definition on top — which of a room's several
/// temperature sensors is the room's, which tiles sit where, and so on.
///
/// Verified against the integration source (`hacs-havenapp/custom_components/havenapp/store.py`),
/// not assumed. `payload` is deliberately a raw `JSONValue`: the integration stores these blobs and
/// never parses them (subproject B design §Category B), so the schema — and every migration of it —
/// belongs to the client. Keeping it opaque here is what lets a dashboard change ship in an App
/// Store update alone, with no integration release and no Home Assistant restart.
public struct HavenConfigRecord: Sendable, Equatable {
    /// Increments by one on every successful write. Handed straight back as the next write's
    /// `baseVersion` — see `HomeConnection.saveConfig`.
    public let version: Int
    public let payload: JSONValue
    /// ISO-8601, as written by the integration. Carried through verbatim rather than parsed to a
    /// `Date`: nothing reads it yet, and a parse that silently fails would be worse than a string.
    public let updated: String
    /// The HA user id that last wrote this record, or nil.
    public let updatedBy: String?

    public init(version: Int, payload: JSONValue, updated: String, updatedBy: String?) {
        self.version = version
        self.payload = payload
        self.updated = updated
        self.updatedBy = updatedBy
    }

    /// Decodes one `havenapp/config/get` result. `nil` for a JSON `null`, which is how the
    /// integration reports "no such record" — an absence, not an error.
    public init?(_ value: JSONValue) {
        guard let o = value.asObject, let version = o["version"]?.asInt,
              let payload = o["payload"], let updated = o["updated"]?.asString else { return nil }
        self.init(version: version, payload: payload, updated: updated,
                  updatedBy: o["updated_by"]?.asString)
    }
}

/// The outcome of a `havenapp/config/set`.
///
/// A stale write is a `case`, not a thrown error, because that is literally what the integration
/// sends: a conflict is an *expected* outcome that carries data (the current record, so the client
/// can reapply and retry without a refetch), and HA's `send_error` cannot attach a payload. See
/// `ws_config_set`, which returns `{status: "version_conflict", current: {...}}` as a success
/// result for exactly this reason. Modelling it as an error here would throw that payload away and
/// force the refetch the integration went out of its way to avoid.
public enum HavenConfigWrite: Sendable, Equatable {
    case ok(version: Int)
    /// `current` is nil when the record was deleted between the read and the write.
    case versionConflict(current: HavenConfigRecord?)
}

/// The three scope forms the integration validates (`store.validate_scope`).
public enum HavenConfigScope {
    /// The curated household configuration everyone sees. Readable by any authenticated user;
    /// **writable by HA admins only** — the integration answers `not_authorized` otherwise, which
    /// is an expected steady state for a household member, not a fault. See `_authorize`.
    public static let shared = "shared"
    /// Per-HA-user. Nothing uses this yet.
    public static func user(_ userId: String) -> String { "user:\(userId)" }
    /// Per-install. Nothing uses this yet; named here so the planned local display preferences
    /// (units, and anything else that must *not* alter the shared dashboard) have an obvious home.
    public static func device(_ installationId: String) -> String { "device:\(installationId)" }
}

public extension WSError {
    /// The caller may not write this scope — in practice, a non-admin writing `shared`.
    /// Distinguishable on purpose: it is the difference between "this household member simply
    /// doesn't curate the dashboard" and "something is broken".
    static let notAuthorizedCode = "not_authorized"
    var isNotAuthorized: Bool { code == Self.notAuthorizedCode }
}
