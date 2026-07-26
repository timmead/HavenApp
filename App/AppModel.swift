import SwiftUI
import HavenCore

/// UserDefaults keys for everything `AppModel` persists about how to reach the current HA
/// instance. None of this is a secret (unlike the tokens in `KeychainTokenStore`), so plain
/// `UserDefaults` is fine.
private enum DefaultsKeys {
    static let baseURL = "baseURL"
    /// No longer written or read — see `DiscoveredCandidateURLs`'s documentation for the full
    /// incident: neither `internal_url` nor `external_url` from `get_config` is ever adopted as a
    /// connection candidate, because a `*.ui.nabu.casa` suffix proves a host is *a* Nabu Casa
    /// instance, never that it is *this user's*. Kept only as the name of a key a build prior to
    /// that fix may have already written, so `purgeDiscoveredURLs()` can find and remove it.
    static let discoveredInternalURL = "discoveredInternalURL"
    /// No longer written or read — same reasoning as `discoveredInternalURL` above. Two earlier
    /// fix rounds *did* persist this (gated on `isNabuCasaHost`, which — see that function's
    /// documentation — was the identity-vs-category mistake itself), so this key may already hold
    /// an attacker-supplied value on an upgrading device; kept only so `purgeDiscoveredURLs()` can
    /// find and remove it.
    static let discoveredExternalURL = "discoveredExternalURL"
    /// Legacy. No longer written or read — it fed the `preferredFirst` candidate hoist, which is
    /// vestigial now that `userEntered` is the only candidate source (see `connect()`). Kept only
    /// so the reset path can find and remove it: on a device that ran an earlier build tonight it
    /// may hold a URL that *was* discovered from `get_config` at the time it was written, back
    /// when discovery still fed candidates.
    static let lastWorkingURL = "lastWorkingURL"
}

@MainActor @Observable
final class AppModel {
    enum Phase { case loggedOut, connecting, retrying(attempt: Int), ready, error(String) }
    var phase: Phase = .loggedOut
    var serverURLText = "http://homeassistant.local:8123"
    let store = HomeStore()
    /// Guided setup for the `havenapp` integration. Created once and re-`attach`ed on every
    /// reconnect rather than rebuilt: the restart step deliberately kills the socket, and what
    /// the flow already knows ("we downloaded it", "we restarted it") has to survive the
    /// reconnection that follows, or Home Assistant coming back would look like a fresh arrival
    /// with no history.
    let onboarding = OnboardingModel()

    private let tokens: TokenStore = KeychainTokenStore()
    private let oauth = OAuthClient()
    private let http = URLSessionHTTP()
    private let web = WebAuthPresenter()
    private let policy = ReconnectPolicy()
    private var baseURL: URL?
    private var tokenProvider: TokenProvider?
    /// The active connect loop. Retrying is now unbounded, so this must be explicitly
    /// cancellable — otherwise a stale loop from a previous session could keep retrying in the
    /// background and later flip `phase` back to `.ready` after a `signOut()`.
    private var connectTask: Task<Void, Never>?

    init() {
        // The onboarding flow can deliberately take Home Assistant down (its restart step), and
        // `connect()` returns for good once it reaches `.ready` — nothing else in the app watches
        // for a socket drop afterwards. So the restart has to be able to ask for a reconnect, or
        // it would strand the user on "waiting for Home Assistant to come back" indefinitely.
        onboarding.onNeedsReconnect = { [weak self] in
            Task { await self?.reconnectAfterConnectionLoss() }
        }
        // Generalizes the exact same reconnect to *any* drop, not just a restart — see
        // `HomeStore.onDisconnected`'s documentation for why this was missing and what it broke.
        // If both fire for the same underlying drop (a restart *is* a drop — HA's shutdown kills
        // the socket same as a lost Wi-Fi connection would), the second call is a harmless no-op:
        // `store.reset()` is safe to run again on an already-nil connection, and
        // `startConnecting()` already cancels/replaces any connect loop already in flight.
        store.onDisconnected = { [weak self] in
            Task { await self?.reconnectAfterConnectionLoss() }
        }
    }

    /// Re-runs the connect loop over the existing credentials after the live connection was lost
    /// — whether that's onboarding's restart step deliberately taking Home Assistant down, or the
    /// socket simply dropping on its own (Wi-Fi lost, HA restarted some other way, anything else;
    /// see `HomeStore.onDisconnected`). Reuses the ordinary candidate/backoff machinery rather
    /// than inventing a special-case wait: HA is simply unreachable for a while, which is exactly
    /// the case that loop already handles — and the user sees the familiar retry UI (and, away
    /// from home, C2's local/remote failover) instead of a dashboard frozen on stale state with
    /// no indication anything is wrong. On success, `connect()`'s own tail re-`attach`es the
    /// onboarding model and re-probes, which is what clears `isAwaitingRestart` when this was a
    /// restart.
    private func reconnectAfterConnectionLoss() async {
        guard baseURL != nil, tokenProvider != nil else { return }
        // Closes the now-dead socket (and its heartbeat) before a new one replaces it — the same
        // leak `HomeStore.reset` exists to prevent on sign-out. Also a no-op if another trigger
        // already got here first (see this function's documentation).
        await store.reset()
        await startConnecting()
    }

    func restoreIfPossible() async {
        guard tokens.load() != nil, let url = savedBaseURL() else { return }
        baseURL = url
        // So `requireReauthentication()`'s "re-authorize, don't retype the host" holds even on a
        // cold launch — LoginView binds to `serverURLText`, not `baseURL`.
        serverURLText = url.absoluteString
        tokenProvider = TokenProvider(baseURL: url, store: tokens, oauth: oauth, http: http)
        await startConnecting()
    }

    func signIn() async {
        let raw = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate a missing scheme (users often type just "homeassistant.local:8123").
        let hasScheme = raw.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil
        let normalized = hasScheme ? raw : "http://\(raw)"
        guard !raw.isEmpty,
              let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else {
            phase = .error("Enter a valid URL like http://homeassistant.local:8123"); return
        }
        serverURLText = normalized
        baseURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: DefaultsKeys.baseURL)
        // Whatever was discovered/remembered belonged to whichever instance was previously
        // signed into (possibly a different host) — never let it leak into this instance's
        // candidate list.
        forgetDiscoveredURLs()
        phase = .connecting
        havenLog.info("OAuth starting against \(url.absoluteString, privacy: .public)")
        do {
            let t = try await oauth.login(baseURL: url, web: web, http: http)
            havenLog.info("token exchange OK (hasRefresh=\(t.refreshToken != nil, privacy: .public))")
            try tokens.save(t)
            tokenProvider = TokenProvider(baseURL: url, store: tokens, oauth: oauth, http: http)
            await startConnecting()
        } catch {
            havenLog.error("sign-in failed at OAuth/token stage: \(error, privacy: .public)")
            phase = .error("Sign-in failed: \(error.localizedDescription)")
        }
    }

    /// Clear the saved session and return to the login screen (also used to change server).
    func signOut() async {
        connectTask?.cancel(); connectTask = nil
        // Must happen before dropping the reference: an in-flight refresh on the old
        // TokenProvider shares this same TokenStore, and would otherwise be able to write a
        // stale token back after we've already moved on (see TokenProvider.invalidate()).
        await tokenProvider?.invalidate()
        tokens.clear()
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.baseURL)
        forgetDiscoveredURLs()
        baseURL = nil
        tokenProvider = nil
        await store.reset()
        onboarding.reset()
        phase = .loggedOut
    }

    /// The stored session can no longer produce a usable token — either the refresh grant was
    /// itself invalid/revoked, or Home Assistant rejected the (freshly refreshed) token outright.
    /// Unlike `signOut()`, this keeps the server URL around so the user only has to re-authorize,
    /// not retype the host.
    private func requireReauthentication() async {
        connectTask?.cancel(); connectTask = nil
        await tokenProvider?.invalidate()
        tokens.clear()
        tokenProvider = nil
        await store.reset()
        onboarding.reset()
        phase = .loggedOut
    }

    /// Runs `connect()` in a cancellable task. Retrying is unbounded, so a stale loop from a
    /// previous session must be stoppable — otherwise it could keep retrying in the background
    /// and later flip `phase` back to `.ready` after a `signOut()`/`requireReauthentication()`.
    private func startConnecting() async {
        connectTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.connect()
        }
        connectTask = task
        await task.value
    }

    /// Tries local and remote candidates in order each round, only backing off once every
    /// candidate in a round has failed. See `ConnectionEndpoint.candidates` for the ordering
    /// rules (local before remote, `*.ui.nabu.casa` always remote, remote always `https`/`wss`,
    /// no duplicates).
    ///
    /// Re-probe policy: there is nothing left to re-probe. Since `get_config`'s URLs are no
    /// longer adopted (see below), `userEntered` is the *only* source of candidates, so a round
    /// contains exactly one candidate and there is no ordering left to optimise. The
    /// `lastWorkingURL` / `preferredFirst` machinery that earlier rounds of this file built —
    /// to avoid paying a local connection timeout on every retry while away from home — is
    /// therefore vestigial here, and is deliberately not used: `preferredFirst` can only *hoist*
    /// a candidate already in the list, never introduce one, so with a single candidate it is a
    /// no-op by construction.
    ///
    /// It is removed rather than left in place because its read-side gate had become actively
    /// misleading: it admitted a stored URL only when `isNabuCasaHost` passed — i.e. exactly the
    /// class the C-1 finding showed cannot be trusted as proof of *whose* instance it is — while
    /// rejecting the user's own (typically local, non-Nabu-Casa) address. Harmless while the
    /// hoist is a no-op, but it would silently become a real hole the moment anyone adds a second
    /// candidate source. `ConnectionEndpoint.candidates` keeps its `preferredFirst` parameter and
    /// tests: the ordering logic is correct and worth keeping for when there is again more than
    /// one candidate to order.
    private func connect() async {
        guard let base = baseURL, let tokenProvider else { return }
        phase = .connecting
        var attempt = 0
        // Home Assistant can reject a token TokenProvider believed was still valid (revoked out
        // of band, or clock skew) — allow exactly one forced refresh to recover from that before
        // treating a further rejection as terminal. Reset once we get past authentication again,
        // so two `auth_invalid`s separated by hours of otherwise-ordinary retrying each still get
        // their own forced-refresh chance instead of the second one being terminal by accident.
        // Shared across every candidate/round in this `connect()` call: an auth_invalid is a
        // property of the token, not of which URL we used to reach the instance. BUT a single
        // candidate's auth_invalid is not trusted as proof the token itself is bad — see
        // `candidatesWithPersistentAuthInvalid` below — since a rogue device answering on one
        // candidate's address could return auth_invalid purely to bait a sign-out before the
        // genuine remaining candidates (e.g. the real remote/Nabu Casa one) are ever tried.
        var didForceRefreshAfterAuthInvalid = false
        while true {
            if Task.isCancelled { return }
            // Purges any `discoveredInternalURL`/`discoveredExternalURL` an earlier, less careful
            // build may have already written to `UserDefaults` — see `purgeDiscoveredURLs()`.
            purgeDiscoveredURLs()
            let candidates = ConnectionEndpoint.candidates(
                userEntered: base,
                // Deliberately always nil — see `DiscoveredCandidateURLs`'s documentation for the
                // full incident: `get_config`'s `internal_url`/`external_url` are never adopted as
                // connection candidates at all, from either the wire or persisted storage.
                discoveredInternal: nil,
                discoveredExternal: nil,
                // Vestigial with a single candidate source — see this method's documentation.
                preferredFirst: nil
            )
            // Only escalate to `requireReauthentication()` once *every* candidate this round has
            // hit the "already spent this call's one forced refresh, still auth_invalid" wall —
            // see the check after this round's candidate loop, and the comment at the guard below.
            var candidatesWithPersistentAuthInvalid = 0

            for candidate in candidates {
                if Task.isCancelled { return }
                let wsURL = HAConfig(baseURL: candidate.url).webSocketURL
                // Retried at most once in place (after a forced token refresh) without moving on
                // to the next candidate or counting as a backoff attempt.
                var retryThisCandidate = true
                candidateAttempt: while retryThisCandidate {
                    retryThisCandidate = false
                    // Declared fresh each iteration: whichever client this attempt creates must
                    // be torn down on every non-success exit (every catch below, and every
                    // cancellation check), or the abandoned socket + its 10s heartbeat loop leak
                    // for as long as the app runs.
                    var client: HAWebSocketClient?
                    do {
                        // Must happen before `validAccessToken`: a refresh triggered for this
                        // candidate has to POST to *this* candidate's host, not whichever one a
                        // previous candidate (or the last app launch) left the provider pointed
                        // at — otherwise a refresh needed on a cold launch away from home would
                        // try to reach the now-unreachable local address even while attempting
                        // the remote candidate, defeating failover before a socket is ever opened.
                        await tokenProvider.setBaseURL(candidate.url)
                        let token = try await tokenProvider.validAccessToken(now: Date())
                        if Task.isCancelled { return }
                        havenLog.info("WS connecting to \(wsURL.absoluteString, privacy: .public) (round \(attempt + 1, privacy: .public), \(candidate.isRemote ? "remote" : "local", privacy: .public))")
                        let conn = NWWebSocketConnection(url: wsURL)
                        let c = HAWebSocketClient(connection: conn)
                        client = c
                        try await c.authenticate(token: token)
                        if Task.isCancelled { await c.disconnect(); return }
                        havenLog.info("WS auth_ok")
                        didForceRefreshAfterAuthInvalid = false
                        await c.startHeartbeat()
                        if Task.isCancelled { await c.disconnect(); return }
                        let home = HomeConnection(client: c)
                        store.attach(home)
                        try await store.bootstrap()
                        if Task.isCancelled { await c.disconnect(); return }
                        havenLog.info("bootstrap OK — \(self.store.home.floors.count, privacy: .public) floors, \(self.store.states.count, privacy: .public) entities")
                        phase = .ready
                        // Read-only: `probeHavenIntegration` only ever asks questions. Nothing
                        // that changes the user's Home Assistant can happen without them
                        // confirming it first (see `OnboardingModel.confirmPendingMutation`), so
                        // this is safe to run unattended on every connect — which is also what
                        // lets the flow pick itself back up after the restart step drops the
                        // socket.
                        if !Task.isCancelled {
                            onboarding.attach(home)
                            await onboarding.probe()
                        }
                        return
                    } catch TokenProviderError.reauthenticationRequired {
                        await client?.disconnect()
                        if Task.isCancelled { return }
                        havenLog.error("token refresh requires reauthentication — signing out")
                        await requireReauthentication()
                        return
                    } catch let wsError as WSError where wsError.isAuthInvalid {
                        await client?.disconnect()
                        if Task.isCancelled { return }
                        guard !didForceRefreshAfterAuthInvalid else {
                            // A second auth_invalid after this call's one forced refresh is
                            // already spent could mean the token really is dead — or it could be
                            // a rogue device answering on *this* candidate's address (e.g. port
                            // 8123 on the LAN) returning auth_invalid to induce a sign-out before
                            // the genuine remaining candidates are ever tried. Don't trust a
                            // single candidate's word for it: fail just this candidate, and only
                            // actually sign out once every candidate this round has said the same
                            // thing (checked right after the candidate loop below).
                            candidatesWithPersistentAuthInvalid += 1
                            havenLog.error("token still invalid after a forced refresh — treating the \(candidate.isRemote ? "remote" : "local", privacy: .public) candidate as failed, not signing out yet")
                            break candidateAttempt
                        }
                        didForceRefreshAfterAuthInvalid = true
                        havenLog.error("Home Assistant rejected the access token as invalid — forcing a refresh")
                        do {
                            _ = try await tokenProvider.forceRefresh()
                            if Task.isCancelled { return }
                            // Retry immediately with the fresh token; doesn't count as a backoff
                            // attempt or advance to the next candidate.
                            retryThisCandidate = true
                            continue candidateAttempt
                        } catch TokenProviderError.reauthenticationRequired {
                            if Task.isCancelled { return }
                            havenLog.error("forced refresh requires reauthentication — signing out")
                            await requireReauthentication()
                            return
                        } catch {
                            if Task.isCancelled { return }
                            havenLog.error("forced refresh failed: \(error, privacy: .public)")
                            // This candidate is done for; move on to the next one (or, if this
                            // was the last, the round-level backoff below).
                        }
                    } catch {
                        await client?.disconnect()
                        if Task.isCancelled { return }
                        havenLog.error("candidate \(wsURL.absoluteString, privacy: .public) failed: \(error, privacy: .public)")
                        // Move on to the next candidate (or, if this was the last, the
                        // round-level backoff below) — not a per-candidate backoff.
                    }
                }
            }

            if Task.isCancelled { return }
            if !candidates.isEmpty, candidatesWithPersistentAuthInvalid == candidates.count {
                // Every candidate this round said the same thing after its own forced-refresh
                // chance: this is corroborated across the whole instance, not just one rogue
                // responder — now it's safe to trust as a real, terminal token problem.
                havenLog.error("token rejected as invalid by every candidate this round — signing out")
                await requireReauthentication()
                return
            }
            attempt += 1
            havenLog.error("all candidates failed this round — backing off (attempt \(attempt, privacy: .public))")
            phase = .retrying(attempt: attempt)
            try? await Task.sleep(for: policy.delay(forAttempt: attempt))
        }
    }

    private func savedBaseURL() -> URL? {
        UserDefaults.standard.string(forKey: DefaultsKeys.baseURL).flatMap(URL.init(string:))
    }

    /// SECURITY (see `DiscoveredCandidateURLs`'s documentation for the full incident):
    /// `get_config`'s `internal_url`/`external_url` are never adopted as connection candidates —
    /// a `*.ui.nabu.casa` suffix proves a host is *a* Nabu Casa instance, never that it is *this
    /// user's*, so two earlier fix rounds' write-boundary checks (rejecting/requiring that suffix
    /// before persisting) stopped nothing: an attacker who legitimately owns their own Nabu Casa
    /// subscription sailed straight through. Both keys may already hold a value one of those
    /// builds wrote on a device that's since upgraded, so — rather than merely stop writing to
    /// them — this purges both unconditionally, every round, treating anything already on disk as
    /// exactly as untrusted as a fresh value fresh off the wire would be.
    private func purgeDiscoveredURLs() {
        let d = UserDefaults.standard
        if d.object(forKey: DefaultsKeys.discoveredInternalURL) != nil {
            d.removeObject(forKey: DefaultsKeys.discoveredInternalURL)
        }
        if d.object(forKey: DefaultsKeys.discoveredExternalURL) != nil {
            d.removeObject(forKey: DefaultsKeys.discoveredExternalURL)
        }
        // Same reasoning: on a device that ran an earlier build tonight this could hold a URL that
        // *was* a discovered candidate when it was written. Nothing reads it any more, so this is
        // belt-and-braces rather than load-bearing — but leaving a known-untrustworthy value on
        // disk purely because today's code happens not to read it is how it comes back.
        if d.object(forKey: DefaultsKeys.lastWorkingURL) != nil {
            d.removeObject(forKey: DefaultsKeys.lastWorkingURL)
        }
    }


    private func forgetDiscoveredURLs() {
        let d = UserDefaults.standard
        d.removeObject(forKey: DefaultsKeys.discoveredInternalURL)
        d.removeObject(forKey: DefaultsKeys.discoveredExternalURL)
        d.removeObject(forKey: DefaultsKeys.lastWorkingURL)
    }
}
