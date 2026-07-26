import Foundation

/// The decoded result of `havenapp/info` — ground truth verified against the integration source
/// (`hacs-havenapp/custom_components/havenapp/websocket_api.py`'s `ws_info`), not assumed.
///
/// `integrationVersion` is informational only — it is the literal string `"unknown"` when the
/// integration's own manifest lookup fails inside HA — and must never be gated on.
/// `HavenIntegrationDetector.classify` gates exclusively on `capabilities` and `schemaVersion`,
/// which is the entire reason those two fields exist: they let an older app degrade a feature
/// instead of hard-blocking against a newer integration.
public struct HavenIntegrationInfo: Sendable, Equatable, Decodable {
    public let integrationVersion: String
    public let schemaVersion: Int
    public let capabilities: [String]
    public let haUserIsAdmin: Bool

    // No explicit CodingKeys: unlike `HAInstanceConfig`, none of these snake_case wire keys
    // collide under `.convertFromSnakeCase` (see `HACoding.decoder`), so the default conversion
    // (`integration_version` -> `integrationVersion`, etc.) is safe to rely on here.

    public init(integrationVersion: String, schemaVersion: Int, capabilities: [String], haUserIsAdmin: Bool) {
        self.integrationVersion = integrationVersion
        self.schemaVersion = schemaVersion
        self.capabilities = capabilities
        self.haUserIsAdmin = haUserIsAdmin
    }
}

extension HomeConnection {
    /// Probes `havenapp/info`, the capability handshake `HavenIntegrationDetector.classify` gates
    /// on. Never throws: every failure mode — an HA-side error result (already a `WSError`), a
    /// transport failure, or a payload that fails to decode as `HavenIntegrationInfo` — is folded
    /// into `Result.failure(WSError)` here, so `classify` has exactly one failure shape to reason
    /// about regardless of where in the stack the failure actually originated. This is also why
    /// `classify` itself never inspects the error's `code`: an unregistered command surfaces as
    /// HA's own `unknown_command`, which is indistinguishable at the wire level from a genuine
    /// but broken `havenapp/info` handler, so the *only* trustworthy signal for "is havenapp
    /// loaded at all" is `get_config`'s `components` list, not this error.
    public func fetchIntegrationInfo() async -> Result<HavenIntegrationInfo, WSError> {
        do {
            let v = try await client.request { WSCommand.havenappInfo(id: $0) }
            let data = try JSONEncoder().encode(v)
            let info = try HACoding.decoder.decode(HavenIntegrationInfo.self, from: data)
            return .success(info)
        } catch {
            return .failure(Self.normalize(error))
        }
    }

    /// Passes an HA-originated `WSError` through unchanged (preserving its diagnostic `code`);
    /// anything else — a transport error, a `DecodingError` from a malformed payload — collapses
    /// to a single fixed code rather than a per-error-type guess, so callers never end up
    /// branching on an invented code that happens to look like one of the integration's real
    /// ones (`version_conflict`, `not_authorized`, `invalid_scope`, `not_found`).
    static func normalize(_ error: Error) -> WSError {
        (error as? WSError) ?? WSError(code: "probe_failed", message: String(describing: error))
    }
}
