import SwiftUI
import HavenCore

/// Drives `OnboardingView`. Deliberately thin: every decision it looks like it is making — which
/// step comes next, whether a step landed, whether a step needs confirming, what that confirmation
/// says — is answered by `HavenOnboardingFlow`/`HavenOnboardingStep` in HavenCore. This target has
/// no test bundle, so anything decided here would be a claim nothing exercises; see
/// `HavenIntegrationDetector`'s documentation for the same reasoning about the classifier.
///
/// What this type genuinely owns is the parts that can't be pure: holding the live connection,
/// running the (read-only) probe, performing a confirmed mutation, and the transient UI state
/// around both.
@MainActor @Observable
final class OnboardingModel {
    private(set) var flow = HavenOnboardingFlow()
    /// A probe or a mutating call is in flight.
    private(set) var isBusy = false
    /// The last mutating call's error, shown verbatim — a HACS failure ("repository already
    /// added", a GitHub rate limit) is usually more useful to the user than anything we'd
    /// paraphrase it into.
    private(set) var failureMessage: String?
    /// Whether the guidance sheet is on screen. Set once a probe finds something to guide, and
    /// cleared when the user dismisses — onboarding is surfaced over the dashboard rather than
    /// blocking it, since the rest of the app works without the integration.
    var isPresented = false

    /// The confirmation awaiting a yes/no, and the mutation it is gating. Both are set and cleared
    /// together; the mutation is never reachable without the confirmation it came packaged with.
    private(set) var pendingConfirmation: HavenOnboardingConfirmation?
    private var pendingMutation: HavenOnboardingMutation?

    /// The live session. Replaced on every reconnect (`attach`) rather than captured once: a
    /// restart deliberately kills the socket, and the `AppModel` connect loop hands us the new
    /// connection afterwards. The `flow` survives that, which is what lets "we restarted" still
    /// be known once Home Assistant comes back.
    private var connection: HomeConnection?

    /// Called after a restart has been issued, to ask `AppModel` to reconnect. Not optional
    /// politeness: `connect()` returns as soon as it reaches `.ready` and nothing in the app
    /// observes a socket drop afterwards, so without this the restart step would leave the user
    /// on "waiting for Home Assistant" forever with no way forward but a sign-out. `isAwaitingRestart`
    /// is only meaningful because something eventually clears it.
    var onNeedsReconnect: (() -> Void)?

    var presentation: HavenOnboardingPresentation {
        flow.step.presentation(didNotLand: flow.lastAttemptDidNotLand)
    }

    func attach(_ connection: HomeConnection) {
        self.connection = connection
    }

    /// Sign-out. Everything here is about one instance and one signed-in user — the flow's
    /// `completed` set in particular, which would otherwise carry "we already restarted this one"
    /// across to a different Home Assistant entirely.
    func reset() {
        flow = HavenOnboardingFlow()
        connection = nil
        cancelConfirmation()
        failureMessage = nil
        isBusy = false
        isPresented = false
    }

    /// Read-only. Safe to run automatically on every connect — nothing mutating ever happens
    /// without the user confirming it first.
    func probe() async {
        guard let connection else { return }
        isBusy = true
        failureMessage = nil
        let probe = await connection.probeHavenIntegration()
        flow.apply(probe)
        isBusy = false
        if flow.needsGuidance { isPresented = true }
    }

    /// The user tapped the step's primary button. Forwards the step's own declared intent; the
    /// view supplies `open` because opening a URL is the environment's job, not a model's.
    func performPrimaryAction(open: (URL) -> Void) {
        switch presentation.intent {
        case .confirmMutation(let mutation, let confirmation):
            pendingMutation = mutation
            pendingConfirmation = confirmation
        case .openLink(let url, let records):
            open(url)
            // Records only that we handed off — never that it worked. The next probe decides that.
            if let records { flow.recordAttempt(records) }
        case .reprobe:
            Task { await probe() }
        case .none:
            break
        }
    }

    func cancelConfirmation() {
        pendingMutation = nil
        pendingConfirmation = nil
    }

    /// Performs the confirmed mutation. The only path in the app that reaches
    /// `addHACSRepository`/`downloadHACSRepository`/`restartHomeAssistant`.
    func confirmPendingMutation() async {
        guard let connection, let mutation = pendingMutation else { return }
        let step = flow.step
        cancelConfirmation()
        isBusy = true
        failureMessage = nil

        let result: Result<Void, WSError>
        switch mutation {
        case .addRepositoryToHACS(let fullName, let category):
            result = await connection.addHACSRepository(fullName: fullName, category: category)
        case .downloadRepository(let repositoryID):
            result = await connection.downloadHACSRepository(repositoryID: repositoryID)
        case .restartHomeAssistant:
            result = await connection.restartHomeAssistant()
        }
        isBusy = false

        switch result {
        case .success:
            break
        case .failure(let error):
            // Home Assistant's shutdown can beat the call_service result frame back to us: HA
            // schedules the actual stop as a task and returns, so the common case *does* deliver
            // the result first, but it's a race, not a guarantee. If the socket simply closed
            // right after we asked for a restart, that closing is itself evidence the restart is
            // proceeding, not proof it failed — treating it as a real failure would strand the
            // user on a dead socket showing "server closed connection (closed)" for their single
            // most disruptive action, with no recorded attempt and so no reconnect ever
            // triggered (see `flow.isAwaitingRestart` below). Treat it as a probable success and
            // let the reconnect-then-probe cycle below establish the truth — it's the only honest
            // confirmation this design accepts even when the result frame *does* arrive on time.
            guard mutation == .restartHomeAssistant, error.code == "closed" else {
                failureMessage = "\(error.message) (\(error.code))"
                return
            }
        }
        if let action = step.recordedAction { flow.recordAttempt(action) }
        // A restart takes the socket down with it, so there is nothing to ask and nobody to ask
        // it of until the app has reconnected. Probing now would fail for reasons that have
        // nothing to do with the integration and land the user on an "we can't tell what's
        // installed" diagnostic at the exact moment it's all working. Hand off to `AppModel`,
        // which retries with backoff until Home Assistant answers again and then re-`attach`es
        // and re-probes — which is what clears `isAwaitingRestart` and moves the flow on.
        guard !flow.isAwaitingRestart else {
            // Drop our reference before handing off: the reconnect tears this exact
            // `HomeConnection` down, and a "Check again" tap racing that teardown would otherwise
            // ask a closing socket. With it nil, `probe()` correctly no-ops until `attach` hands
            // us the new one.
            self.connection = nil   // `self.`: the guard above shadows this with a `let` binding.
            onNeedsReconnect?()
            return
        }
        await probe()
    }
}
