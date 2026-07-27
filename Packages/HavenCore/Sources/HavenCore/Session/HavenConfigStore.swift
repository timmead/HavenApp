import Foundation

/// The client half of the `havenapp` integration's scoped configuration store.
///
/// Its own file rather than more of `HomeConnection.swift`: this talks to *Haven's* integration
/// about Haven's own configuration, whereas everything in `HomeConnection` talks to Home Assistant
/// about the home. Two different contracts, versioned independently, and the file was already long.
public extension HomeConnection {
    /// Reads one config record, or `nil` when there is none.
    ///
    /// `nil` and a throw mean genuinely different things here and callers depend on the difference:
    /// `nil` is "this home has no dashboard configured yet", which is the ordinary first-run state
    /// and the cue to propose one. A throw is "we could not find out", which must never be
    /// mistaken for the former — proposing over an unread document would overwrite it.
    func loadConfig(scope: String, key: String) async throws -> HavenConfigRecord? {
        let v = try await client.request { WSCommand.havenappConfigGet(id: $0, scope: scope, key: key) }
        return HavenConfigRecord(v)
    }

    /// Writes one config record under optimistic concurrency.
    ///
    /// `baseVersion` is the version this write is based on, or 0 for a first write (see
    /// `WSCommand.havenappConfigSet`). Throws only for genuine failures — a version conflict comes
    /// back as `.versionConflict`, carrying the current record so the caller can reapply its change
    /// and retry without a refetch.
    ///
    /// Writing `HavenConfigScope.shared` requires an HA admin; anyone else gets a `WSError` whose
    /// code is `not_authorized` (`WSError.isNotAuthorized`). That is an expected outcome for a
    /// household member rather than a fault, so it is left as a distinguishable error for the
    /// caller to shrug off rather than being folded into a generic failure here.
    func saveConfig(scope: String, key: String, baseVersion: Int,
                    payload: JSONValue) async throws -> HavenConfigWrite {
        let v = try await client.request {
            WSCommand.havenappConfigSet(id: $0, scope: scope, key: key,
                                        baseVersion: baseVersion, payload: payload)
        }
        guard let o = v.asObject else {
            throw WSError(code: "malformed_result", message: "havenapp/config/set returned \(v)")
        }
        if o["status"]?.asString == "version_conflict" {
            // `current` is present but JSON-null when the record was deleted mid-flight, so an
            // absent record and a nulled one both land on `nil` — the caller retries from 0 either
            // way, which is the correct base version for a record that no longer exists.
            return .versionConflict(current: o["current"].flatMap(HavenConfigRecord.init))
        }
        guard let version = o["version"]?.asInt else {
            throw WSError(code: "malformed_result", message: "havenapp/config/set returned \(v)")
        }
        return .ok(version: version)
    }
}
