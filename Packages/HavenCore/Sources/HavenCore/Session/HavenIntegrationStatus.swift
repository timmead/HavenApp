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
    /// configure anything, in HACS or HA itself. Only reachable once `havenapp/info` has already
    /// succeeded (its `ha_user_is_admin` is the authority here); see `blockedByNonAdmin` for the
    /// equivalent check in the branches below, where `havenapp/info` never ran at all.
    case notAdmin

    /// A non-admin (per `auth/current_user`, independent of `havenapp/info`) hit a branch whose
    /// remediation — `needsInstall`, `needsConfigEntry`, or `hacsMissing` — is an admin-only HACS
    /// or HA operation. Distinct from `notAdmin`: it fires *before* `havenapp/info` ever ran, in
    /// exactly the branches that can't consult `ha_user_is_admin` because `havenapp` isn't loaded
    /// at all. Without this case a non-admin would be walked through install steps they cannot
    /// complete — the same "confusing failure instead of something sensible" `ha_user_is_admin`
    /// exists to prevent, just relocated from a write failure to an install failure. The
    /// associated `HavenIntegrationRemediation` says which of the three steps was blocked, so the
    /// UI can still explain *what* needs doing (by a household admin) rather than just that it
    /// can't be done.
    case blockedByNonAdmin(HavenIntegrationRemediation)

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
    /// Requires admin — if the caller is known not to be one, `blockedByNonAdmin(.needsConfigEntry)`
    /// is returned instead.
    case needsConfigEntry

    /// `havenapp` is not loaded, HACS is, and HACS does not confirm our repository as downloaded
    /// (or we have no answer from HACS at all — see `HavenIntegrationDetector.classify`'s
    /// documentation for why that is treated the same as "not downloaded"). Guided HACS install
    /// (a separate task) is the remediation. Requires admin — if the caller is known not to be
    /// one, `blockedByNonAdmin(.needsInstall)` is returned instead.
    case needsInstall

    /// Neither `havenapp` nor `hacs` is loaded. This cannot be automated from inside the app —
    /// HACS itself must be installed first, a separate manual step — so onboarding links out to
    /// HACS's own installation docs instead. Requires admin — if the caller is known not to be
    /// one, `blockedByNonAdmin(.hacsMissing)` is returned instead.
    case hacsMissing

    /// `havenapp/info` failed to answer, *and* `get_config`'s `components` list was either absent
    /// entirely or decoded to an empty array — neither of which HA is expected to genuinely
    /// report (some component is always loaded; a real empty list here would mean this app's
    /// assumption about `get_config`'s wire shape, see `HAInstanceConfig.components`, is wrong).
    /// Onboarding cannot determine what, if anything, is installed from this data — not "nothing
    /// is," which is the confident (and confidently *wrong*, for anyone actually fully set up)
    /// claim `.hacsMissing`/`.needsInstall`/`.needsConfigEntry` would otherwise make. This case
    /// exists specifically so a broken wire-shape assumption fails visibly as a diagnostic
    /// instead of silently as a wrong remediation instruction shown to a correctly-configured
    /// user. Never produced when `havenapp/info` itself succeeded — see `classify`'s
    /// documentation for why a successful probe is trusted outright regardless of `components`.
    case indeterminate
}

/// Which of `HavenIntegrationStatus`'s admin-only remediation steps `blockedByNonAdmin` is
/// reporting on. A separate, closed type rather than nesting a full `HavenIntegrationStatus`
/// inside `blockedByNonAdmin` — only these three cases are ever admin-gated pre-`havenapp/info`,
/// so this keeps the association exhaustive and avoids an `indirect` recursive case for a
/// relationship that's really just "one of these three, tagged."
public enum HavenIntegrationRemediation: Sendable, Equatable {
    case needsConfigEntry
    case needsInstall
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
    ///   - components: `get_config`'s `components` list (`HAInstanceConfig.components`), or `nil`
    ///     if that field was missing/unparseable in the response this ran against. Only consulted
    ///     when `infoResult` is a *failure* — see `infoResult`'s documentation for why a
    ///     successful probe doesn't need it at all — and even then, only if it's non-`nil` and
    ///     non-empty: HA reporting zero loaded components is not a real outcome, so a `nil` or
    ///     empty list here means the wire-shape assumption behind it may be wrong, not "nothing is
    ///     loaded," and yields `.indeterminate` rather than a confident remediation. When it *is*
    ///     trustworthy, it's the detector for whether `havenapp` (and, to disambiguate, `hacs`) is
    ///     loaded at all — a custom integration only appears here once a config entry has set it
    ///     up, which is exactly why "files downloaded, no config entry" cannot be told apart from
    ///     "not downloaded" by this list alone.
    ///   - infoResult: The result of probing `havenapp/info` (`HomeConnection.fetchIntegrationInfo`).
    ///     Checked *first*, ahead of `components`: a successful probe is direct, positive proof
    ///     `havenapp` is loaded and responding, strictly stronger evidence than an indirect
    ///     `components` listing, so every gate below runs unconditionally on success regardless of
    ///     what (or whether) `components` said. Only on failure does this function fall back to
    ///     `components` to work out *why* — an unregistered command legitimately answers with HA's
    ///     own generic `unknown_command`, which carries no information this function would trust
    ///     (see the `commandsUnregistered` case's documentation), so the error's `code` itself is
    ///     never pattern-matched on for a "maybe it's actually fine" shortcut.
    ///   - hacsRepositories: HACS's own list of downloaded repositories (its `hacs/repositories`
    ///     command), consulted only to disambiguate "not downloaded" from "downloaded, no config
    ///     entry" when `havenapp` is absent but `hacs` is present. `nil` means the caller has no
    ///     answer from HACS (e.g. the query itself failed, or was skipped) — treated identically
    ///     to "our repository isn't in the list," which is the conservative choice: guiding the
    ///     user through the full install flow is always correct even if they'd already downloaded
    ///     it (HACS's own UI will simply show it as already present), whereas the reverse mistake
    ///     — claiming "just add the config entry" when the files were never downloaded at all —
    ///     sends the user to a deep link that can't work.
    ///   - isAdmin: The signed-in HA user's admin status from `auth/current_user` — a stock HA
    ///     command answerable by *any* authenticated user, independent of whether `havenapp` is
    ///     installed at all. This is what lets the `havenapp`-absent branches (which never run
    ///     `havenapp/info`, so have no `ha_user_is_admin` of their own) still avoid walking a
    ///     non-admin through an admin-only HACS/HA step. `nil` means the caller doesn't know (the
    ///     query wasn't made, or failed) and must never *withhold* a remediation on that account —
    ///     failing toward showing the steps (today's behavior) is strictly safer than failing
    ///     toward silently hiding them from someone who could actually act on them. Ignored
    ///     entirely once `havenapp/info` has succeeded: `info.haUserIsAdmin` is the authority
    ///     there (see `notAdmin`), since it reflects the same request that produced every other
    ///     field being gated on.
    public static func classify(
        components: [String]?,
        infoResult: Result<HavenIntegrationInfo, WSError>,
        hacsRepositories: [String]? = nil,
        isAdmin: Bool? = nil
    ) -> HavenIntegrationStatus {
        switch infoResult {
        case .success(let info):
            // A successful probe outranks everything else here — see this parameter's
            // documentation. Precedence among these gates, most fundamental first: a schema the
            // app can't understand at all, then missing capabilities, then permissions. Each
            // earlier check's remediation subsumes the ones after it (there's no point telling a
            // non-admin about capabilities the app can't even parse yet), so the first match wins.
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

        case .failure(let error):
            // The probe failed. Only a `components` list that actually decoded to something
            // non-empty is trustworthy enough to explain *why* — see `indeterminate`'s and this
            // function's `components` documentation for why `nil`/`[]` cannot be read as "nothing
            // is loaded."
            guard let components, !components.isEmpty else {
                return .indeterminate
            }
            guard components.contains("havenapp") else {
                guard components.contains("hacs") else {
                    return isAdmin == false ? .blockedByNonAdmin(.hacsMissing) : .hacsMissing
                }
                let ourRepoIsDownloaded = hacsRepositories?.contains {
                    $0.caseInsensitiveCompare(hacsRepositoryFullName) == .orderedSame
                } ?? false
                let remediation: HavenIntegrationRemediation = ourRepoIsDownloaded ? .needsConfigEntry : .needsInstall
                if isAdmin == false { return .blockedByNonAdmin(remediation) }
                return ourRepoIsDownloaded ? .needsConfigEntry : .needsInstall
            }
            // components confirms havenapp is loaded, yet the probe still failed — the
            // "shouldn't happen" case; see `commandsUnregistered`'s documentation.
            return .commandsUnregistered(error)
        }
    }
}
