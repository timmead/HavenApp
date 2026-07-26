import SwiftUI
import HavenCore

/// Drives the one-tap "turn on remote access" offer for a Nabu Casa subscriber who has switched it
/// off (`NabuCasaRemoteAccess.remoteDisabled`).
///
/// A sibling to `OnboardingModel`, not a member of it. `OnboardingModel`'s state — `flow`,
/// `isAwaitingRestart`, the HACS bookkeeping in `HavenOnboardingFlow` — is keyed on
/// `HavenIntegrationDetector.classify`, which knows nothing about Nabu Casa; folding this
/// unrelated mutation into its `confirmPendingMutation()` switch would make that state machine
/// respond to something it has no way to interpret. What *is* reused, deliberately, is the shape
/// `OnboardingModel` established: a `pendingConfirmation` that gates the mutating call, cleared
/// together with it, and a `confirmPendingMutation()` that is the only path in the app to the
/// mutation. See `OnboardingModel` for the pattern this mirrors, and
/// `NabuCasaRemoteAccessOffer`/`RemoteAccessEnableOutcome` in HavenCore for every actual decision —
/// nothing below decides anything; `App/` has no test target.
@MainActor @Observable
final class RemoteAccessOfferModel {
    /// What `cloud/status` last said there is to offer, or `nil` if there's nothing (subscription
    /// fine, not signed in, cloud not loaded, or nothing probed yet). Set only by `AppModel`, from
    /// the same write boundary that updates `remoteAccess` — see
    /// `AppModel.rememberNabuCasaRemoteAccess`.
    private(set) var offer: NabuCasaRemoteAccessOffer?
    /// A mutating call or its re-probe is in flight.
    private(set) var isBusy = false
    /// The last mutating call's error, or the plain "it didn't take" message from a re-probe that
    /// still doesn't show remote access as available — shown verbatim either way, same reasoning as
    /// `OnboardingModel.failureMessage`.
    private(set) var failureMessage: String?
    /// The confirmation awaiting a yes/no. Set only once the user taps the offer's button; the
    /// mutation is never reachable without it.
    private(set) var pendingConfirmation: HavenOnboardingConfirmation?

    /// Called with every fresh `cloud/status` result, success or failure — including the one this
    /// model's own re-probe produces after a successful enable. Lets `AppModel` re-run the one
    /// adoption path (`rememberNabuCasaRemoteAccess`) rather than this model duplicating a
    /// `UserDefaults` write of its own; see that method's documentation for why there is exactly
    /// one place in the codebase that decides whether a self-reported address may be remembered.
    var onReprobe: ((Result<HACloudStatus, WSError>) -> Void)?

    /// The live session. Replaced on every reconnect, same as `OnboardingModel.connection`.
    private var connection: HomeConnection?

    func attach(_ connection: HomeConnection) {
        self.connection = connection
    }

    /// Called by `AppModel` whenever a fresh `cloud/status` comes back. A new offer always replaces
    /// whatever was showing — a fresh probe is always more current than a stale one — and a `nil`
    /// offer clears any leftover confirmation along with it, since there is nothing left to confirm.
    ///
    /// Deliberately does **not** clear `failureMessage` here. The re-probe that follows a failed
    /// enable attempt is exactly the case where `offer` is likely to become `nil` — a transport
    /// blip right after `cloud/remote/connect` reclassifies as `.indeterminate`, not
    /// `.remoteDisabled` — and clearing the message in the same call that reports that failure
    /// would erase it before the view ever draws it. `confirmPendingMutation` clears it at the
    /// start of its own next attempt, and `reset()` covers sign-out; nothing else needs to.
    func update(_ offer: NabuCasaRemoteAccessOffer?) {
        self.offer = offer
        if offer == nil {
            pendingConfirmation = nil
        }
    }

    /// Sign-out / server change. Drops the connection reference and every piece of transient state
    /// — this describes the previous instance's cloud account, same reasoning as
    /// `AppModel.forgetDiscoveredURLs`'s `remoteAccess = nil`.
    func reset() {
        offer = nil
        connection = nil
        pendingConfirmation = nil
        failureMessage = nil
        isBusy = false
    }

    /// The user tapped "Turn on remote access". `offer?.confirmation` is `nil` only when Home
    /// Assistant would refuse the call outright (`remote_allow_remote_enable == false`, checked by
    /// `NabuCasaRemoteAccessDetector.canEnableRemoteAccess`) — which should never happen in
    /// practice, since this offer is only ever shown from a local connection — and in that case
    /// there is nothing to confirm because there is nothing this button can do.
    func requestConfirmation() {
        pendingConfirmation = offer?.confirmation
    }

    func cancelConfirmation() {
        pendingConfirmation = nil
    }

    /// Performs the confirmed mutation. The only path in the app that reaches
    /// `HomeConnection.enableNabuCasaRemoteAccess`.
    func confirmPendingMutation() async {
        guard let connection, pendingConfirmation != nil else { return }
        pendingConfirmation = nil
        isBusy = true
        failureMessage = nil

        let result = await connection.enableNabuCasaRemoteAccess()
        guard case .success = result else {
            isBusy = false
            if case .failure(let error) = result {
                failureMessage = "\(error.message) (\(error.code))"
            }
            return
        }

        // A `.success` above means only that Home Assistant accepted the request, not that the
        // tunnel came up — the same discipline `OnboardingModel` applies to the restart step. The
        // only honest confirmation is a fresh `cloud/status`, re-classified.
        let reprobe = await connection.fetchCloudStatus()
        // Lets `AppModel` re-run its one adoption path and call `update(_:)` back with whatever the
        // re-probe now says, before this reads `offer` again below.
        onReprobe?(reprobe)
        isBusy = false
        if case .didNotTakeEffect(let message) = NabuCasaRemoteAccessDetector.evaluateEnableAttempt(reprobe: reprobe) {
            failureMessage = message
        }
    }
}
