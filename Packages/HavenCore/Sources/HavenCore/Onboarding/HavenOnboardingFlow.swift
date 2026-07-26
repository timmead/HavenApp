import Foundation

/// Everything one round of onboarding's read-only probing learned, in the exact shape
/// `HavenIntegrationDetector.classify` needs. Kept as a value with a computed `status` so the
/// "raw answers in, verdict out" step stays pure and testable, separate from the I/O that
/// gathered it (`HomeConnection.probeHavenIntegration`).
public struct HavenOnboardingProbe: Sendable, Equatable {
    /// `get_config`'s `components`, or `nil` if the call failed or the key was absent.
    public let components: [String]?
    public let info: Result<HavenIntegrationInfo, WSError>
    /// Everything HACS knows about — installed or not. `nil` means HACS was never asked (the
    /// happy path doesn't ask) or couldn't answer.
    public let hacsRepositories: [HACSRepository]?
    public let isAdmin: Bool?
    /// Whether `components` is `nil` because the `get_config` request itself never completed —
    /// see `HavenIntegrationDetector.classify`'s `transportFailed` parameter, which this feeds
    /// directly. Distinguishes "the socket was down" from "we got an answer we didn't expect."
    public let transportFailed: Bool

    public init(
        components: [String]?,
        info: Result<HavenIntegrationInfo, WSError>,
        hacsRepositories: [HACSRepository]? = nil,
        isAdmin: Bool? = nil,
        transportFailed: Bool = false
    ) {
        self.components = components
        self.info = info
        self.hacsRepositories = hacsRepositories
        self.isAdmin = isAdmin
        self.transportFailed = transportFailed
    }

    /// Our repository's HACS entry, installed or not. This is what the download step reads its id
    /// from — deliberately *not* filtered on `installed`, since a not-yet-downloaded entry is
    /// exactly the one that needs downloading.
    public var ourRepository: HACSRepository? {
        hacsRepositories.flatMap {
            HACSRepositoryIndex.match(fullName: HavenIntegrationDetector.hacsRepositoryFullName, in: $0)
        }
    }

    /// The verdict. Note what is handed to `classify`: only the **downloaded** repositories'
    /// names. `classify`'s `hacsRepositories` parameter means "downloaded" and does a plain
    /// membership test with no `installed` check of its own, so passing the raw list would make
    /// every repository HACS merely *knows about* look downloaded — and the instant
    /// `hacs/repositories/add` succeeded, onboarding would jump straight to `.needsConfigEntry`
    /// and send the user to a config-flow link for files that don't exist yet.
    public var status: HavenIntegrationStatus {
        HavenIntegrationDetector.classify(
            components: components,
            infoResult: info,
            hacsRepositories: hacsRepositories.map(HACSRepositoryIndex.downloadedFullNames(in:)),
            isAdmin: isAdmin,
            transportFailed: transportFailed
        )
    }
}

/// The guided-install state machine: which step onboarding is on, what has already been done, and
/// whether the last thing the user did actually landed.
///
/// Two design points worth stating because they're what the type is for:
///
/// 1. **Nothing advances on faith.** A step only moves on when a *fresh probe* says the world
///    changed. `apply(_:)` is the only way `step` changes, and it takes a probe.
/// 2. **Some verdicts need history to interpret.** `.needsConfigEntry` means "restart Home
///    Assistant" immediately after a download (the files exist but the running process hasn't
///    loaded them) and "add the config entry" otherwise — same verdict, different step. That's
///    what `completed` is for; it cannot be derived from the wire.
///
/// A value type with no I/O, for the same reason `HavenIntegrationDetector` is: `App/` has no test
/// target, so a state machine living in a view model would be an untested claim.
public struct HavenOnboardingFlow: Sendable, Equatable {
    public private(set) var step: HavenOnboardingStep = .probing
    public private(set) var completed: Set<HavenOnboardingAction> = []

    /// True when the most recent probe left us on the exact step the user had just taken — i.e.
    /// they said they'd done it (or we made the call) and Home Assistant disagrees. Drives a hint,
    /// never a different verdict.
    public private(set) var lastAttemptDidNotLand = false

    /// True between issuing a restart and the next probe of any kind. Restarting drops the
    /// WebSocket, so anything asked of Home Assistant in that window fails for reasons that have
    /// nothing to do with the integration — and a failed `get_config` yields `.indeterminate`,
    /// which would put an "we can't tell what's installed" diagnostic on screen at the exact
    /// moment everything is going *right*. Callers must not probe while this is true; they wait
    /// until the app has reconnected, which is also the only honest confirmation available that
    /// the restart happened at all (a `.success` from the service call only means HA accepted it).
    public private(set) var isAwaitingRestart = false

    /// The step an action was last taken for, cleared once the flow moves past it.
    private var attemptedStep: HavenOnboardingStep?

    /// Whether a config-flow handoff has been *contradicted by a probe* — not merely started. The
    /// distinction matters because the escalation it feeds is a restart, and a restart takes the
    /// user's home offline: someone who taps "Open Home Assistant", gets bounced out of the app,
    /// comes back and hits "Check again" before finishing the wizard has an unfinished form, not a
    /// Home Assistant that needs restarting. Set from `apply` *after* the step for that probe is
    /// decided, so the first contradicting probe still shows "did you finish it?" and only a
    /// second one escalates.
    private var configFlowHandoffFailed = false

    public init() {}

    /// Whether onboarding has anything to say. False while probing and once everything is set up,
    /// so `App/` never has to decide for itself whether to put the flow on screen.
    public var needsGuidance: Bool {
        switch step {
        case .probing, .done: return false
        default: return true
        }
    }

    /// Records that the current step was carried out — the mutating call succeeded, or the user
    /// was handed off to Home Assistant's own UI. Says nothing about whether it *worked*; that is
    /// what the next `apply(_:)` decides.
    public mutating func recordAttempt(_ action: HavenOnboardingAction) {
        completed.insert(action)
        attemptedStep = step
        if action == .restartedHomeAssistant { isAwaitingRestart = true }
    }

    /// Folds a fresh probe in and recomputes the current step.
    public mutating func apply(_ probe: HavenOnboardingProbe) {
        isAwaitingRestart = false
        let next = Self.nextStep(
            status: probe.status,
            ourRepository: probe.ourRepository,
            completed: completed,
            configFlowHandoffFailed: configFlowHandoffFailed
        )
        // "Didn't land" is exactly "we took an action for this step and the world still puts us on
        // it." Note the escalations in `nextStep` deliberately move to a *different* step in the
        // cases where we know a better next thing to try, so they read as progress, not failure.
        lastAttemptDidNotLand = (attemptedStep == next)
        // Recorded only now, so this probe's own step was already decided without it — see the
        // property's documentation for why the first contradicting probe must not escalate.
        if attemptedStep == .addConfigEntry, case .needsConfigEntry = probe.status {
            configFlowHandoffFailed = true
        }
        if !lastAttemptDidNotLand { attemptedStep = nil }
        step = next
    }

    /// The pure verdict-to-step mapping. Every `HavenIntegrationStatus` case is handled here and
    /// nowhere else.
    ///
    /// - Parameters:
    ///   - status: this round's verdict.
    ///   - ourRepository: our repository's HACS entry (installed or not), used only to read the
    ///     id the download step needs. `nil` means HACS has never heard of it — or couldn't be
    ///     asked, which is treated the same way: offering to add a repository HACS already has
    ///     fails visibly with HACS's own error, whereas offering to download an id we guessed
    ///     would fail silently.
    ///   - completed: what has already been done this session. Only consulted where the verdict
    ///     genuinely underdetermines the step.
    ///   - configFlowHandoffFailed: whether a config-flow handoff has already been contradicted by
    ///     a probe. Deliberately not derivable from `completed`, which only records that the user
    ///     was *sent* to the config flow — see `HavenOnboardingFlow.configFlowHandoffFailed`.
    public static func nextStep(
        status: HavenIntegrationStatus,
        ourRepository: HACSRepository?,
        completed: Set<HavenOnboardingAction>,
        configFlowHandoffFailed: Bool
    ) -> HavenOnboardingStep {
        switch status {
        case .ready:
            return .done

        case .needsUpdate(let missing):
            return .updateIntegration(missingCapabilities: missing)

        case .appTooOld(let schemaVersion):
            return .updateApp(schemaVersion: schemaVersion)

        case .notAdmin:
            return .notAdmin

        case .blockedByNonAdmin(let remediation):
            return .adminRequired(remediation)

        case .commandsUnregistered(let error):
            return .diagnostic(.commandsUnregistered(error))

        case .indeterminate:
            return .diagnostic(.indeterminateComponents)

        case .disconnected:
            return .diagnostic(.disconnected)

        case .hacsMissing:
            return .installHACS

        case .needsInstall:
            // HACS is present and our repository is not downloaded. If HACS already knows the
            // repository we can go straight to the download, using the id it gave us; otherwise
            // it has to be registered as a custom repository first.
            if let ourRepository {
                return .downloadRepository(repositoryID: ourRepository.id)
            }
            return .addRepository

        case .needsConfigEntry:
            // The files are downloaded. Two different things can be missing, and the verdict alone
            // can't distinguish them — a custom integration is absent from `components` both when
            // Home Assistant has never loaded its files and when it has loaded them but no config
            // entry exists.
            //
            // We just downloaded it: Home Assistant is certainly still running the process that
            // started before those files existed, so its config flow isn't offered yet. Restart
            // first — sending the user to `config_flow_start` for a domain HA hasn't loaded is a
            // dead end.
            if completed.contains(.downloadedRepository), !completed.contains(.restartedHomeAssistant) {
                return .restartHomeAssistant
            }
            // Or: we sent them to the config flow, a probe has already contradicted it once, and
            // we're still here. Most likely the same cause — files present from an earlier
            // session, Home Assistant never restarted since — so escalate to the restart instead
            // of looping them on a link that cannot work. Gated on the handoff having actually
            // *failed*, not merely happened: escalating on the first probe after the tap would put
            // a home-goes-offline prompt in front of someone who simply hasn't finished the form
            // yet.
            if configFlowHandoffFailed, !completed.contains(.restartedHomeAssistant) {
                return .restartHomeAssistant
            }
            return .addConfigEntry
        }
    }
}

extension HomeConnection {
    /// One full, **read-only** onboarding probe. Nothing here mutates anything on the user's Home
    /// Assistant — this is safe to run automatically on connect, which is the whole reason the
    /// mutating steps are separate, individually-confirmed calls.
    ///
    /// Runs its own `get_config` — this has to work identically for a manual "check again" from
    /// the onboarding screen, where there is no connect in progress to borrow a result from. A
    /// second `get_config` is cheap.
    ///
    /// The two follow-up queries are conditional on purpose. HACS is only asked when the probe
    /// failed *and* `hacs` is actually loaded — a fully working instance should never see
    /// onboarding touch HACS at all — and `auth/current_user` is only asked when the probe failed,
    /// because `classify` ignores `isAdmin` entirely once `havenapp/info` has answered (its own
    /// `ha_user_is_admin` is the authority there).
    ///
    /// `get_config`'s failure mode is captured explicitly, not folded into a plain `nil` via
    /// `try?`: if the socket is simply dead (walked out of Wi-Fi range with the onboarding sheet
    /// on screen, or the restart step's own socket drop beating this probe to it), that is not
    /// evidence of anything about `havenapp`/HACS, and must not be shown to the user as
    /// `.indeterminate`'s "this is a problem with Haven… please report it" — that copy asserts,
    /// with total confidence, a wire-shape mistake that a dropped Wi-Fi connection has nothing to
    /// do with. A `DecodingError` is the one specific case that *is* a wire-shape surprise (the
    /// request completed; the response just didn't parse as expected); anything else thrown here
    /// means the request never completed at all, which is `.disconnected`'s territory instead —
    /// see `HavenIntegrationDetector.classify`'s `transportFailed` parameter.
    public func probeHavenIntegration() async -> HavenOnboardingProbe {
        var components: [String]?
        var transportFailed = false
        do {
            components = try await fetchInstanceConfig().components
        } catch is DecodingError {
            components = nil
        } catch {
            components = nil
            transportFailed = true
        }
        let info = await fetchIntegrationInfo()
        guard case .failure = info else {
            return HavenOnboardingProbe(components: components, info: info, transportFailed: transportFailed)
        }
        let repositories: [HACSRepository]?
        if components?.contains("hacs") == true {
            repositories = try? await fetchHACSRepositories().get()
        } else {
            repositories = nil
        }
        let isAdmin = await fetchCurrentUserIsAdmin()
        return HavenOnboardingProbe(
            components: components,
            info: info,
            hacsRepositories: repositories,
            isAdmin: isAdmin,
            transportFailed: transportFailed
        )
    }
}
