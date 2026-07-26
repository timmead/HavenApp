import Foundation

/// One position in the guided-install flow — what onboarding is asking the user to do *right now*.
///
/// Every non-`ready` verdict from `HavenIntegrationDetector.classify` maps onto exactly one of
/// these (see `HavenOnboardingFlow.nextStep`), and each step carries its own user-facing copy,
/// deep link and confirmation via `presentation`. The whole point of the type existing is that
/// "after a successful download, the next step is the restart, and after that the config entry" is
/// something a test can assert rather than something a SwiftUI view implies.
///
/// `App/` has no test target, so nothing about *which* step comes next, what a step does, or what
/// its confirmation says may live there — see `HavenIntegrationDetector`'s documentation for the
/// same reasoning applied to the classification itself.
public enum HavenOnboardingStep: Sendable, Equatable, Hashable {
    /// Nothing has been probed yet (or a probe is in flight). Never a resting state.
    case probing

    /// The integration is installed, configured, capable enough, and this user can use it.
    case done

    /// HACS itself isn't installed. Not automatable from inside the app at all — HACS is
    /// installed by running a script on the Home Assistant host — so this links out to HACS's own
    /// documentation and says plainly that we can't do it for them.
    case installHACS

    /// HACS is present but has never heard of our repository. Registers it as a custom
    /// repository; the *files* are downloaded by the next step.
    case addRepository

    /// HACS knows our repository but hasn't downloaded it. Downloads it by HACS's own id — read
    /// back from `hacs/repositories/list`, never assumed. See `WSCommand.hacsRepositoryDownload`.
    case downloadRepository(repositoryID: String)

    /// The files are on disk but Home Assistant hasn't loaded them: a newly downloaded custom
    /// integration doesn't exist as far as the running process is concerned, so its config flow
    /// isn't offered until HA restarts. Sequenced *before* `addConfigEntry` for exactly that
    /// reason — sending the user to a `config_flow_start` link for an unloaded domain produces a
    /// dead end, which is the failure mode this whole flow exists to avoid.
    case restartHomeAssistant

    /// The files are installed and loaded, but there's no config entry — which is what actually
    /// registers the `havenapp/*` WebSocket commands. Handed off to Home Assistant's own UI via
    /// the My Home Assistant `config_flow_start` redirect; the config flow is never driven over
    /// the WebSocket API.
    case addConfigEntry

    /// The integration is older than this build requires. Updated through HACS's own UI.
    case updateIntegration(missingCapabilities: [String])

    /// The *app* is the old side. Deliberately says nothing about the integration — telling the
    /// user to update an already-newer integration would be actively wrong.
    case updateApp(schemaVersion: Int)

    /// An admin-only install step is blocked because this user isn't an admin. Names which step a
    /// household admin needs to perform, and — structurally, since this case has no link or
    /// action of its own — shows no instructions this user could try to follow themselves.
    case adminRequired(HavenIntegrationRemediation)

    /// Everything is installed and capable, but this user isn't an admin. A separate case from
    /// `adminRequired` on purpose: there is no blocked install step to name here, and no install
    /// instructions exist that would make sense to show. Collapsing the two would let install
    /// copy leak into a screen where nothing needs installing.
    case notAdmin

    /// Something we cannot honestly turn into a remediation. Shows what we actually observed and
    /// offers a retry, rather than guessing.
    case diagnostic(HavenOnboardingDiagnostic)
}

/// The two ways onboarding can end up with no trustworthy remediation to offer. Kept as data (not
/// as free-text copy assembled in a view) so `HavenOnboardingStep.presentation` can render an
/// honest diagnostic and the tests can assert we never dress one of these up as a fix.
public enum HavenOnboardingDiagnostic: Sendable, Equatable, Hashable {
    /// `get_config` came back without a usable `components` list — see
    /// `HavenIntegrationStatus.indeterminate`. This means *our decoding assumption* is wrong, not
    /// that anything is missing on the user's system, and the screen must say so.
    case indeterminateComponents
    /// `havenapp` is loaded but `havenapp/info` still failed — per the integration source this
    /// shouldn't happen, so the underlying error is surfaced as a diagnostic instead of a guess.
    case commandsUnregistered(WSError)
}

/// A privileged Home Assistant mutation a step performs over the WebSocket API. Modelled as data
/// so the "every mutating call is gated behind a confirmation" rule is a property of this type
/// that a test can check exhaustively, rather than a convention each call site has to remember.
public enum HavenOnboardingMutation: Sendable, Equatable, Hashable {
    case addRepositoryToHACS(fullName: String, category: String)
    case downloadRepository(repositoryID: String)
    case restartHomeAssistant
}

/// What the user did (or what we did on their behalf) at a given step. Recorded by
/// `HavenOnboardingFlow` because two different situations produce the *same*
/// `HavenIntegrationStatus` and can only be told apart by what has already happened this session
/// — most importantly `.needsConfigEntry`, which means "restart first" right after a download and
/// "add the config entry" otherwise.
public enum HavenOnboardingAction: Sendable, Equatable, Hashable {
    case addedRepositoryToHACS
    case downloadedRepository
    case restartedHomeAssistant
    /// The user was handed off to Home Assistant's config-flow UI. Says only that they were sent
    /// there — never that a config entry now exists; that is what the next probe is for.
    case openedConfigFlow
    case openedHACS
    case openedHACSDocs
}

/// What tapping a step's primary button should do. Returned from `presentation` so `App/` can
/// forward the user's intent without deciding anything: a view that had to work out for itself
/// whether a step opens a link or fires a mutation would be flow logic living in an untested
/// target.
public enum HavenOnboardingIntent: Sendable, Equatable {
    /// Ask for confirmation first, then perform the mutation. The confirmation is not optional
    /// and names exactly what will happen.
    case confirmMutation(HavenOnboardingMutation, HavenOnboardingConfirmation)
    /// Open a URL — a My Home Assistant deep link or documentation — and record that we did.
    /// Handing the privileged action to Home Assistant's own UI carries no automation risk, which
    /// is why these need no confirmation of their own.
    case openLink(URL, records: HavenOnboardingAction?)
    /// Nothing to do but look again.
    case reprobe
    /// Nothing this app can do at all (the user must update the app, or find an admin).
    case none
}

/// The wording shown before a mutating call runs. Lives in HavenCore rather than in the view so
/// "the restart warning tells the user their home goes offline" is an assertion, not a promise.
public struct HavenOnboardingConfirmation: Sendable, Equatable {
    public let title: String
    /// Names exactly what will happen, on whose system, in plain language.
    public let message: String
    public let confirmLabel: String
    /// Renders as a destructive action. True only for the restart — the one step with a
    /// user-visible consequence beyond this app.
    public let isDestructive: Bool

    public init(title: String, message: String, confirmLabel: String, isDestructive: Bool = false) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.isDestructive = isDestructive
    }
}

/// Everything `App/` needs to render a step. Deliberately a plain value: the view maps fields to
/// SwiftUI, and makes no decisions.
public struct HavenOnboardingPresentation: Sendable, Equatable {
    public let title: String
    /// Why the user is seeing this and what it will accomplish.
    public let explanation: String
    /// SF Symbol name for the header glyph.
    public let symbolName: String
    /// Label for the primary button, or `nil` when the step has no action the user can take here.
    public let actionLabel: String?
    public let intent: HavenOnboardingIntent
    /// Whether a "check again" affordance makes sense alongside the primary action — true
    /// wherever the user might go and do something outside the app.
    public let allowsRecheck: Bool
    /// Shown when a re-probe says the step the user just took didn't actually land. Never the
    /// only thing on screen; the step's own copy stays visible so they can try again.
    public let didNotLandHint: String?

    public init(
        title: String,
        explanation: String,
        symbolName: String,
        actionLabel: String?,
        intent: HavenOnboardingIntent,
        allowsRecheck: Bool,
        didNotLandHint: String?
    ) {
        self.title = title
        self.explanation = explanation
        self.symbolName = symbolName
        self.actionLabel = actionLabel
        self.intent = intent
        self.allowsRecheck = allowsRecheck
        self.didNotLandHint = didNotLandHint
    }
}

/// The fixed URLs onboarding hands off to. All are `https`; the My Home Assistant redirects are
/// the documented one-tap way to reach a specific page on *the user's own* instance without this
/// app needing to know its address, and carry no automation risk of their own.
public enum HavenOnboardingLinks {
    /// Starts the `havenapp` config flow in Home Assistant's own UI.
    public static let configFlowStart = URL(string: "https://my.home-assistant.io/redirect/config_flow_start/?domain=havenapp")!
    /// Opens our repository's page in the user's HACS panel.
    public static let hacsRepository = URL(string: "https://my.home-assistant.io/redirect/hacs_repository/?owner=timmead&repository=hacs-havenapp&category=integration")!
    /// HACS's own site. Deliberately the stable root rather than a deep documentation path — a
    /// 404 at the end of a "we can't do this for you" screen is worse than one extra click.
    public static let hacsDocs = URL(string: "https://hacs.xyz")!
}

public extension HavenOnboardingStep {
    /// The privileged mutation this step performs, if any. Every step for which this is non-`nil`
    /// must have a confirmation — enforced by `mutatingStepsAlwaysRequireConfirmation` rather
    /// than by convention.
    var mutation: HavenOnboardingMutation? {
        switch self {
        case .addRepository:
            return .addRepositoryToHACS(
                fullName: HavenIntegrationDetector.hacsRepositoryFullName,
                // HACS requires this lowercase.
                category: "integration"
            )
        case .downloadRepository(let repositoryID):
            return .downloadRepository(repositoryID: repositoryID)
        case .restartHomeAssistant:
            return .restartHomeAssistant
        case .probing, .done, .installHACS, .addConfigEntry, .updateIntegration,
             .updateApp, .adminRequired, .notAdmin, .diagnostic:
            return nil
        }
    }

    /// Whether the flow can still make progress from here. Terminal steps are the ones where the
    /// blocker is outside this session entirely — a newer app build, or another person's account.
    var isTerminal: Bool {
        switch self {
        case .updateApp, .notAdmin, .adminRequired: return true
        default: return false
        }
    }

    /// The action recorded when the user completes this step, so `HavenOnboardingFlow` can tell
    /// otherwise-identical verdicts apart afterwards. `nil` for steps that change nothing.
    ///
    /// Switched exhaustively, like `mutation` and `presentation` — a `default` here would let a
    /// future mutating step compile while silently recording nothing, and the flow would never
    /// learn it had happened.
    var recordedAction: HavenOnboardingAction? {
        switch self {
        case .addRepository: return .addedRepositoryToHACS
        case .downloadRepository: return .downloadedRepository
        case .restartHomeAssistant: return .restartedHomeAssistant
        case .addConfigEntry: return .openedConfigFlow
        case .installHACS: return .openedHACSDocs
        case .updateIntegration: return .openedHACS
        case .probing, .done, .updateApp, .adminRequired, .notAdmin, .diagnostic: return nil
        }
    }

    /// Copy, link and confirmation for this step.
    ///
    /// - Parameter didNotLand: whether the most recent re-probe found the user still on this exact
    ///   step after they'd already taken it. Only ever adds a hint — it never changes what the
    ///   step *is*, because "we checked and it isn't there yet" is information, not a new verdict.
    func presentation(didNotLand: Bool = false) -> HavenOnboardingPresentation {
        switch self {
        case .probing:
            return .init(
                title: "Checking your Home Assistant",
                explanation: "Looking for the Haven integration.",
                symbolName: "magnifyingglass",
                actionLabel: nil,
                intent: .none,
                allowsRecheck: false,
                didNotLandHint: nil
            )

        case .done:
            return .init(
                title: "Haven is set up",
                explanation: "The Haven integration is installed and responding.",
                symbolName: "checkmark.circle",
                actionLabel: nil,
                intent: .none,
                allowsRecheck: false,
                didNotLandHint: nil
            )

        case .installHACS:
            return .init(
                title: "HACS isn't installed",
                explanation: """
                Haven's integration is distributed through HACS, the Home Assistant Community Store. \
                HACS has to be installed on your Home Assistant server first, and that isn't something \
                Haven can do for you — it's a one-time setup step you run on the server itself.
                """,
                symbolName: "shippingbox",
                actionLabel: "Open HACS instructions",
                intent: .openLink(HavenOnboardingLinks.hacsDocs, records: .openedHACSDocs),
                allowsRecheck: true,
                didNotLandHint: didNotLand ? "Home Assistant still doesn't report HACS as installed. It may need a restart after installing HACS." : nil
            )

        case .addRepository:
            return .init(
                title: "Add Haven to HACS",
                explanation: """
                HACS hasn't heard of Haven's integration yet. Haven can register it as a custom \
                repository for you — this only tells HACS where to find it; nothing is downloaded yet.
                """,
                symbolName: "plus.square.on.square",
                actionLabel: "Add to HACS",
                intent: .confirmMutation(
                    .addRepositoryToHACS(fullName: HavenIntegrationDetector.hacsRepositoryFullName, category: "integration"),
                    .init(
                        title: "Add Haven to HACS?",
                        message: """
                        Haven will add \(HavenIntegrationDetector.hacsRepositoryFullName) to your Home Assistant's \
                        HACS as a custom integration repository. This changes HACS's own configuration. \
                        No files are downloaded by this step.
                        """,
                        confirmLabel: "Add repository"
                    )
                ),
                allowsRecheck: true,
                didNotLandHint: didNotLand ? "HACS still doesn't list the Haven repository. You can also add it by hand in HACS." : nil
            )

        case .downloadRepository(let repositoryID):
            return .init(
                title: "Download the Haven integration",
                explanation: """
                HACS knows about Haven's integration but hasn't downloaded it. Haven can ask HACS to \
                download it onto your Home Assistant server now.
                """,
                symbolName: "arrow.down.circle",
                actionLabel: "Download",
                intent: .confirmMutation(
                    // Spelled out rather than reusing `mutation` — an `??` fallback here would
                    // make a wrong refactor of that property silently resolve to the *restart*
                    // mutation behind a download confirmation.
                    .downloadRepository(repositoryID: repositoryID),
                    .init(
                        title: "Download the Haven integration?",
                        message: """
                        HACS will download the Haven integration's files onto your Home Assistant server. \
                        Home Assistant will need to restart afterwards before it can use them — Haven will \
                        ask you about that separately.
                        """,
                        confirmLabel: "Download"
                    )
                ),
                allowsRecheck: true,
                didNotLandHint: didNotLand ? "HACS still doesn't report the integration as downloaded. Opening HACS directly will show you why the download failed." : nil
            )

        case .restartHomeAssistant:
            return .init(
                title: "Restart Home Assistant",
                explanation: """
                The integration's files are on your server, but Home Assistant won't see them until it \
                restarts. After it comes back, there's one more step to finish setup.
                """,
                symbolName: "arrow.clockwise.circle",
                actionLabel: "Restart Home Assistant",
                intent: .confirmMutation(
                    .restartHomeAssistant,
                    .init(
                        title: "Restart Home Assistant?",
                        // The one confirmation whose consequence reaches outside this app: say so
                        // in the first sentence, not as a footnote.
                        message: """
                        This restarts Home Assistant, which will briefly take your home offline — \
                        automations, and anything else that depends on it, will stop until it comes back. \
                        It usually takes under a minute.
                        """,
                        confirmLabel: "Restart",
                        isDestructive: true
                    )
                ),
                allowsRecheck: true,
                didNotLandHint: didNotLand ? "Home Assistant hasn't come back with the integration loaded yet. Give it a moment and check again." : nil
            )

        case .addConfigEntry:
            return .init(
                title: "Finish setup in Home Assistant",
                explanation: """
                The integration is installed, but it isn't switched on until it's added under \
                Settings › Devices & Services. This opens that page on your own Home Assistant — \
                Haven never sets it up behind your back.
                """,
                symbolName: "gearshape",
                actionLabel: "Open Home Assistant",
                intent: .openLink(HavenOnboardingLinks.configFlowStart, records: .openedConfigFlow),
                allowsRecheck: true,
                didNotLandHint: didNotLand ? "Haven still can't reach the integration. Make sure you finished adding it in Home Assistant, then check again." : nil
            )

        case .updateIntegration(let missing):
            return .init(
                title: "Update the Haven integration",
                explanation: """
                The Haven integration on your server is older than this version of the app \
                (it's missing: \(missing.joined(separator: ", "))). Update it in HACS, then restart \
                Home Assistant.
                """,
                symbolName: "arrow.up.circle",
                actionLabel: "Open in HACS",
                intent: .openLink(HavenOnboardingLinks.hacsRepository, records: .openedHACS),
                allowsRecheck: true,
                didNotLandHint: didNotLand ? "The integration still reports the older version. It may need a Home Assistant restart after updating." : nil
            )

        case .updateApp(let schemaVersion):
            return .init(
                title: "Update Haven",
                explanation: """
                The Haven integration on your server speaks version \(schemaVersion), which this version \
                of the app doesn't understand yet. Update Haven from the App Store. Don't change anything \
                on your Home Assistant — it's already up to date.
                """,
                symbolName: "iphone.gen3",
                actionLabel: nil,
                intent: .none,
                allowsRecheck: true,
                didNotLandHint: nil
            )

        case .adminRequired(let remediation):
            // Names the blocked step but carries no link and no action — a non-admin cannot
            // perform any of these, so offering them a button would be offering a dead end.
            let what: String
            switch remediation {
            case .hacsMissing: what = "install HACS on your Home Assistant server"
            case .needsInstall: what = "install the Haven integration through HACS"
            case .needsConfigEntry: what = "add the Haven integration under Settings › Devices & Services"
            }
            return .init(
                title: "An administrator needs to finish this",
                explanation: """
                Haven isn't set up on this Home Assistant yet. Someone with an administrator account \
                needs to \(what). Your account doesn't have permission to do it, so there's nothing to \
                do here — ask whoever administers your home, then check again.
                """,
                symbolName: "person.badge.key",
                actionLabel: nil,
                intent: .none,
                allowsRecheck: true,
                didNotLandHint: nil
            )

        case .notAdmin:
            return .init(
                title: "Your account can't manage Haven",
                explanation: """
                The Haven integration is installed and working, but your Home Assistant account isn't an \
                administrator, so Haven can't save changes to your home's setup. Ask whoever administers \
                your home to grant your account administrator access.
                """,
                symbolName: "person.badge.key",
                actionLabel: nil,
                intent: .none,
                allowsRecheck: true,
                didNotLandHint: nil
            )

        case .diagnostic(let diagnostic):
            switch diagnostic {
            case .indeterminateComponents:
                return .init(
                    title: "Haven couldn't tell what's installed",
                    explanation: """
                    Your Home Assistant answered, but not in a shape Haven understands, so Haven can't \
                    tell whether the integration is installed — and won't guess. This is a problem with \
                    Haven, not with your setup, and nothing on your Home Assistant needs changing. \
                    Please report it, including your Home Assistant version.
                    """,
                    symbolName: "questionmark.circle",
                    actionLabel: nil,
                    intent: .reprobe,
                    allowsRecheck: true,
                    didNotLandHint: nil
                )
            case .commandsUnregistered(let error):
                return .init(
                    title: "The Haven integration didn't respond",
                    explanation: """
                    Home Assistant reports the Haven integration as loaded, but it didn't answer \
                    (\(error.code): \(error.message)). Restarting Home Assistant usually clears this. \
                    If it doesn't, please report it with the message above.
                    """,
                    symbolName: "exclamationmark.triangle",
                    actionLabel: nil,
                    intent: .reprobe,
                    allowsRecheck: true,
                    didNotLandHint: nil
                )
            }
        }
    }
}
