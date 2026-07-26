import SwiftUI
import HavenCore

/// UserDefaults keys for everything `AppModel` persists about how to reach the current HA
/// instance. None of this is a secret (unlike the tokens in `KeychainTokenStore`), so plain
/// `UserDefaults` is fine.
private enum DefaultsKeys {
    static let baseURL = "baseURL"
    /// No longer written or read (see `DiscoveredCandidateURLs`'s documentation for why
    /// `internal_url` is never adopted at all) — kept only as the name of a key a build prior to
    /// this fix may have already written, so `discoveredURLs()` can find and purge it.
    static let discoveredInternalURL = "discoveredInternalURL"
    /// Learned from `get_config`'s `external_url` — for a Nabu Casa subscriber, the
    /// `*.ui.nabu.casa` remote address, once cloud remote access is enabled.
    static let discoveredExternalURL = "discoveredExternalURL"
    /// The candidate URL that last completed a full connect (auth + bootstrap).
    static let lastWorkingURL = "lastWorkingURL"
}

@MainActor @Observable
final class AppModel {
    enum Phase { case loggedOut, connecting, retrying(attempt: Int), ready, error(String) }
    var phase: Phase = .loggedOut
    var serverURLText = "http://homeassistant.local:8123"
    let store = HomeStore()

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
    /// Re-probe policy (the exact cadence was left to my judgement — see
    /// `.superpowers/overnight/c2-remote-failover-report.md` for the reasoning, including a
    /// fix-round-1 correction to what's described here): `lastWorkingURL` is passed as
    /// `preferredFirst` on *every* round, including round 0 — i.e. every fresh app launch
    /// (`restoreIfPossible`) and every explicit sign-in, the only two callers. `preferredFirst`
    /// only *hoists* a candidate that's already in the list; it never removes any other
    /// candidate. So on a cold launch away from home with a remembered remote winner, the order
    /// becomes `[remote, local, …]` — remote is tried (and normally succeeds) first, but local is
    /// still probed immediately afterwards in that same round with no backoff in between, so
    /// "returning home returns to the fast path" is preserved without needing a separate
    /// staleness/timestamp mechanism.
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
            let candidates = ConnectionEndpoint.candidates(
                userEntered: base,
                // Deliberately always nil — see `DiscoveredCandidateURLs`'s documentation for why
                // a discovered `internal_url` is never adopted as a candidate at all.
                discoveredInternal: nil,
                discoveredExternal: discoveredExternalURL(),
                preferredFirst: lastWorkingURL()
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
                        rememberWorkingURL(candidate.url)
                        // The UI must become usable now, not after `fetchInstanceConfig` below:
                        // `receive()` (and so `request(_:)`, and so `get_config`) is deliberately
                        // unbounded — a server that authenticates and bootstraps fine but never
                        // answers `get_config` must not pin the connecting spinner forever over a
                        // socket that's otherwise perfectly live and usable.
                        phase = .ready
                        // Best-effort, fire-and-forget from here on: learning the instance's own
                        // internal/external URLs is a nice-to-have for the *next* connection,
                        // never a reason to hold up (or fail) this one. The `!Task.isCancelled`
                        // guards the `UserDefaults` write specifically — without it, a
                        // `connect()` call cancelled while this await was in flight (e.g. by a
                        // sign-out that started after `phase = .ready`) could still persist a
                        // discovered URL after the session it belongs to is already gone.
                        if let config = try? await home.fetchInstanceConfig(), !Task.isCancelled {
                            rememberDiscoveredURLs(config)
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

    /// SECURITY (read boundary — see `rememberDiscoveredURLs` for the write boundary and
    /// `DiscoveredCandidateURLs` for the full threat model, including why `internal_url` is
    /// dropped unconditionally, not merely "validated"): the write-boundary fix alone only stops
    /// a hostile value from being written *from now on*. It does nothing for a device that
    /// already ran an earlier, less careful build — `discoveredInternalURL` was never validated
    /// at all, and an early revision of the `external_url` fix validated on write but not on
    /// read — so either key may already hold an untrusted value from before. `AppModel` holds no
    /// validation logic of its own here: both raw stored strings are handed to
    /// `DiscoveredCandidateURLs.validating`, the same pure function the write boundary calls, and
    /// whatever it rejects is purged from `UserDefaults`, not merely skipped, so a stale hostile
    /// value doesn't keep silently failing this check (and logging about it) forever.
    private func discoveredExternalURL() -> URL? {
        let d = UserDefaults.standard
        // internal_url is never consumed as a candidate, period — see `DiscoveredCandidateURLs`.
        // Any value under this key can only be left over from a build that predates that
        // decision; purge it so it doesn't linger indefinitely for no purpose.
        if d.object(forKey: DefaultsKeys.discoveredInternalURL) != nil {
            d.removeObject(forKey: DefaultsKeys.discoveredInternalURL)
        }
        let rawExternal = d.string(forKey: DefaultsKeys.discoveredExternalURL).flatMap(URL.init(string:))
        // rawInternalURL is always nil here: this app never reads discoveredInternalURL back as
        // a candidate source, so there is nothing untrusted to hand `.validating` for it.
        let validated = DiscoveredCandidateURLs.validating(rawInternalURL: nil, rawExternalURL: rawExternal)
        if let rawExternal, validated.externalURL == nil {
            havenLog.error("stored discoveredExternalURL (host: \(rawExternal.host ?? "?", privacy: .public)) is not a *.ui.nabu.casa address — dropping it as untrusted (possibly left over from an earlier build)")
            d.removeObject(forKey: DefaultsKeys.discoveredExternalURL)
        }
        return validated.externalURL
    }

    /// SECURITY: also re-validated on read, same reasoning as `discoveredExternalURL()` above. A
    /// genuine remote candidate can, after the write-boundary fix, only ever be a Nabu Casa host
    /// — so requiring that here to trust `lastWorkingURL` as a preference costs nothing for the
    /// legitimate local case: a local candidate is already tried first by `ConnectionEndpoint`'s
    /// default ordering regardless of any `preferredFirst` hoist, so dropping a non-Nabu-Casa
    /// `lastWorkingURL` here never changes which candidate is actually tried, only (at most) a
    /// minor ordering nuance between two local candidates — never a security-relevant one.
    private func lastWorkingURL() -> URL? {
        guard let url = UserDefaults.standard.string(forKey: DefaultsKeys.lastWorkingURL).flatMap(URL.init(string:)) else {
            return nil
        }
        guard ConnectionEndpoint.isNabuCasaHost(url) else {
            // Not necessarily hostile — most of the time this is simply a perfectly legitimate
            // local address, which just doesn't need to be (and after this fix, never needs to
            // be) trusted here to still work correctly. Not logged as an error for that reason.
            return nil
        }
        return url
    }

    private func rememberWorkingURL(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: DefaultsKeys.lastWorkingURL)
    }

    /// SECURITY: `config` came straight off the wire (`get_config`'s result), and whatever we
    /// persist here becomes a future connection candidate that `TokenProvider.setBaseURL` will
    /// later POST the refresh token to (see `connect()`). The default server URL is cleartext
    /// `http://homeassistant.local:8123` and the app allows arbitrary cleartext loads, so a
    /// transient on-LAN attacker can MITM this exact response — `forcedHTTPS` on the candidate
    /// side is no defense, since they can simply serve a valid cert for a host they control.
    /// `config.internalURL` is never persisted at all (see `DiscoveredCandidateURLs`'s
    /// documentation for why — it isn't validated, it's dropped, because there's no way to
    /// validate it as "a private address" inside this exact MITM-on-the-LAN threat model, and it
    /// has no consumer this app needs anyway). `config.externalURL` is persisted only if
    /// `DiscoveredCandidateURLs.validating` — the same pure function the read boundary calls —
    /// says it's a genuine Nabu Casa host; anything else is rejected, not silently dropped —
    /// logged clearly so a real HA feature (e.g. a self-hosted reverse proxy `external_url`)
    /// failing to appear as a candidate doesn't look like a bug with no explanation. (A
    /// user-confirmed opt-in for non-Nabu-Casa remote URLs is a real, separate feature this does
    /// not implement.)
    private func rememberDiscoveredURLs(_ config: HAInstanceConfig) {
        let d = UserDefaults.standard
        let validated = DiscoveredCandidateURLs.validating(rawInternalURL: config.internalURL, rawExternalURL: config.externalURL)
        if let externalURL = validated.externalURL {
            d.set(externalURL.absoluteString, forKey: DefaultsKeys.discoveredExternalURL)
        } else if let rejected = config.externalURL {
            havenLog.error("get_config's external_url (host: \(rejected.host ?? "?", privacy: .public)) is not a *.ui.nabu.casa address — rejecting, not persisting; HavenApp only auto-adopts the user's own Nabu Casa remote address")
        }
        if config.internalURL == nil && config.externalURL == nil {
            // The wire shape here (get_config's internal_url/external_url fields) is assumed from
            // HA's documented behavior, not yet verified against a live instance — if that
            // assumption is wrong, this is how the feature would silently no-op with no error.
            havenLog.error("get_config returned neither internal_url nor external_url — nothing to remember for the next connection")
        }
    }

    private func forgetDiscoveredURLs() {
        let d = UserDefaults.standard
        d.removeObject(forKey: DefaultsKeys.discoveredInternalURL)
        d.removeObject(forKey: DefaultsKeys.discoveredExternalURL)
        d.removeObject(forKey: DefaultsKeys.lastWorkingURL)
    }
}
