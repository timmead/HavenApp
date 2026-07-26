import Foundation

/// Onboarding's verdict on whether the `havenapp` Home Assistant integration is installed,
/// configured, and capable enough for this build of the app to use. The integration is a hard
/// dependency — Haven's dashboard configuration lives there and there is no cloud fallback — so
/// every non-`ready` case exists to let onboarding show the user something actionable instead of
/// a generic connection failure. Produced only by `HavenIntegrationDetector.classify`, the single
/// pure function this whole decision lives in (see that type's documentation for why).
public enum HavenIntegrationStatus: Sendable, Equatable {
    /// `havenapp` is loaded, answered `havenapp/info`, and every required capability is present
    /// at a schema version this build understands. Onboarding can proceed.
    case ready(HavenIntegrationInfo)

    /// `havenapp` is loaded and answered, but doesn't yet advertise every capability this build
    /// requires — an *older* integration than the app expects. Update the integration (HACS
    /// update, or a manual pull); the app itself is fine.
    case needsUpdate(missingCapabilities: [String])

    /// `havenapp/info` reports a `schema_version` newer than this build understands — the
    /// opposite of `needsUpdate`: here the *app* is the old side. Kept as a distinct case (rather
    /// than folded into `needsUpdate`) because the remediation and the message are the opposite
    /// of each other — telling the user to update an already-up-to-date integration would be
    /// actively wrong.
    case appTooOld(schemaVersion: Int)

    /// Every gate above passed, but the signed-in HA user is not an admin. Shown instead of the
    /// confusing write failure a non-admin would otherwise hit — non-admins cannot install or
    /// configure anything, in HACS or HA itself. (This case can only be reached once
    /// `havenapp/info` has already succeeded: while `havenapp` isn't loaded at all, admin status
    /// is simply unknowable, so those branches below cannot special-case a non-admin either — see
    /// `needsInstall`/`needsConfigEntry`/`hacsMissing`.)
    case notAdmin

    /// `havenapp` is loaded (present in `get_config`'s `components`) but `havenapp/info` itself
    /// failed. Per the integration source this "shouldn't happen" — a loaded component always
    /// registers its commands — so onboarding shows a generic error with diagnostics (the
    /// underlying `WSError`) rather than a specific remediation path. The error's `code` is
    /// carried for diagnostics only; `classify` never branches on it (see its documentation).
    case commandsUnregistered(WSError)

    /// `havenapp` is not loaded, but HACS confirms our repository *is* downloaded. The files are
    /// present with no config entry yet — installing via HACS does not create one. Guide the user
    /// to Settings > Devices & Services (the My Home Assistant `config_flow_start` deep link is
    /// a one-tap way to do that); never attempt to drive the config flow over the WebSocket API.
    case needsConfigEntry

    /// `havenapp` is not loaded, HACS is, and HACS does not confirm our repository as downloaded
    /// (or we have no answer from HACS at all — see `HavenIntegrationDetector.classify`'s
    /// documentation for why that is treated the same as "not downloaded"). Guided HACS install
    /// (a separate task) is the remediation.
    case needsInstall

    /// Neither `havenapp` nor `hacs` is loaded. This cannot be automated from inside the app —
    /// HACS itself must be installed first, a separate manual step — so onboarding links out to
    /// HACS's own installation docs instead.
    case hacsMissing
}

/// The single place onboarding's `havenapp` detection and capability requirements are declared,
/// and the pure classifier that turns a probe's raw results into a `HavenIntegrationStatus`.
///
/// Kept entirely free of I/O and actor state by design: there is no App-layer test target in
/// HavenApp, so any decision that lived only in `AppModel` would be an unverified claim about
/// behavior nobody actually exercises (this is exactly how an earlier security fix shipped
/// incomplete). Every test in `HavenIntegrationDetectorTests` exercises `classify` directly;
/// `App/` may only call it and render the result.
public enum HavenIntegrationDetector {
    /// This build's capability requirement. Gate on this list — exact string membership — never
    /// on `integrationVersion`, which is informational only and can literally be `"unknown"`.
    /// An integration advertising *extra*, unrecognized capabilities alongside these must still
    /// pass: forward compatibility (an app understanding fewer capabilities than a newer
    /// integration offers) is the entire reason `capabilities` is a list rather than a single
    /// version number.
    public static let requiredCapabilities: [String] = ["config.v1"]

    /// This build's minimum understood `schema_version`. `havenapp/info` reporting anything
    /// *higher* means the app itself needs updating (`.appTooOld`) — the integration has moved on
    /// to a schema shape this build was never written to understand.
    public static let minSchemaVersion = 1

    /// The GitHub `owner/repo` HACS would list our repository under once downloaded (see
    /// `hacs-havenapp`'s `manifest.json` `documentation` URL / `hacs.json`). Compared
    /// case-insensitively against `hacsRepositories` in `classify` — GitHub's `owner/repo` is
    /// itself case-insensitive, and the codebase already normalizes host comparisons this way
    /// (`ConnectionEndpoint.isNabuCasaHost`).
    public static let hacsRepositoryFullName = "timmead/hacs-havenapp"

    /// Classifies onboarding's `havenapp` detection state. Pure and synchronous: no I/O, no actor
    /// isolation, so every input this depends on must be handed in explicitly.
    ///
    /// - Parameters:
    ///   - components: `get_config`'s `components` list (`HAInstanceConfig.components`) — the
    ///     detector for whether `havenapp` (and, to disambiguate, `hacs`) is loaded at all. A
    ///     custom integration only appears here once a config entry has set it up, which is
    ///     exactly why "files downloaded, no config entry" cannot be told apart from "not
    ///     downloaded" by this list alone.
    ///   - infoResult: The result of probing `havenapp/info` (`HomeConnection.fetchIntegrationInfo`).
    ///     Only consulted when `components` says `havenapp` is loaded — while it isn't, an
    ///     unregistered command legitimately answers with HA's own generic `unknown_command`
    ///     error, which carries no information this function would trust anyway (see the
    ///     `commandsUnregistered` case's documentation), so this parameter is ignored in that
    ///     branch rather than pattern-matched on for a "maybe it's actually fine" shortcut.
    ///   - hacsRepositories: HACS's own list of downloaded repositories (its `hacs/repositories`
    ///     command), consulted only to disambiguate "not downloaded" from "downloaded, no config
    ///     entry" when `havenapp` is absent but `hacs` is present. `nil` means the caller has no
    ///     answer from HACS (e.g. the query itself failed, or was skipped) — treated identically
    ///     to "our repository isn't in the list," which is the conservative choice: guiding the
    ///     user through the full install flow is always correct even if they'd already downloaded
    ///     it (HACS's own UI will simply show it as already present), whereas the reverse mistake
    ///     — claiming "just add the config entry" when the files were never downloaded at all —
    ///     sends the user to a deep link that can't work.
    public static func classify(
        components: [String],
        infoResult: Result<HavenIntegrationInfo, WSError>,
        hacsRepositories: [String]? = nil
    ) -> HavenIntegrationStatus {
        guard components.contains("havenapp") else {
            guard components.contains("hacs") else { return .hacsMissing }
            let ourRepoIsDownloaded = hacsRepositories?.contains {
                $0.caseInsensitiveCompare(hacsRepositoryFullName) == .orderedSame
            } ?? false
            return ourRepoIsDownloaded ? .needsConfigEntry : .needsInstall
        }

        switch infoResult {
        case .failure(let error):
            return .commandsUnregistered(error)

        case .success(let info):
            // Precedence, most fundamental first: a schema the app can't understand at all, then
            // missing capabilities, then permissions. Each earlier check's remediation subsumes
            // the ones after it (there's no point telling a non-admin about capabilities the app
            // can't even parse yet), so the first match wins.
            guard info.schemaVersion <= minSchemaVersion else {
                return .appTooOld(schemaVersion: info.schemaVersion)
            }
            let missing = requiredCapabilities.filter { !info.capabilities.contains($0) }
            guard missing.isEmpty else {
                return .needsUpdate(missingCapabilities: missing)
            }
            guard info.haUserIsAdmin else {
                return .notAdmin
            }
            return .ready(info)
        }
    }
}
