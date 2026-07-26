import SwiftUI
import HavenCore

/// UserDefaults keys for everything `AppModel` persists about how to reach the current HA
/// instance. None of this is a secret (unlike the tokens in `KeychainTokenStore`), so plain
/// `UserDefaults` is fine.
private enum DefaultsKeys {
    static let baseURL = "baseURL"
    /// Learned from `get_config`'s `internal_url` after a successful connection.
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
    /// `.superpowers/overnight/c2-remote-failover-report.md` for the reasoning): round 0 of
    /// every `connect()` call — i.e. every fresh app launch (`restoreIfPossible`) and every
    /// explicit sign-in, the only two callers — always uses the default local-first ordering, so
    /// returning home always re-probes the fast path on the very next launch. Only once a whole
    /// round has failed and we're backing off does a later round prefer whatever URL last
    /// completed a full connect, so a phone that's genuinely away from home doesn't pay a local
    /// connection-timeout on every single backoff retry.
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
        // property of the token, not of which URL we used to reach the instance.
        var didForceRefreshAfterAuthInvalid = false
        while true {
            if Task.isCancelled { return }
            let discovered = discoveredURLs()
            let preferredFirst = attempt == 0 ? nil : lastWorkingURL()
            let candidates = ConnectionEndpoint.candidates(
                userEntered: base,
                discoveredInternal: discovered.internal,
                discoveredExternal: discovered.external,
                preferredFirst: preferredFirst
            )

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
                        // Best-effort: learning the instance's own internal/external URLs is a
                        // nice-to-have for the *next* connection, never a reason to fail this one.
                        if let config = try? await home.fetchInstanceConfig() {
                            rememberDiscoveredURLs(config)
                        }
                        if Task.isCancelled { await c.disconnect(); return }
                        phase = .ready
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
                            havenLog.error("token still invalid after a forced refresh — signing out")
                            await requireReauthentication()
                            return
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
            attempt += 1
            havenLog.error("all candidates failed this round — backing off (attempt \(attempt, privacy: .public))")
            phase = .retrying(attempt: attempt)
            try? await Task.sleep(for: policy.delay(forAttempt: attempt))
        }
    }

    private func savedBaseURL() -> URL? {
        UserDefaults.standard.string(forKey: DefaultsKeys.baseURL).flatMap(URL.init(string:))
    }

    private func discoveredURLs() -> (internal: URL?, external: URL?) {
        let d = UserDefaults.standard
        let internalURL = d.string(forKey: DefaultsKeys.discoveredInternalURL).flatMap(URL.init(string:))
        let externalURL = d.string(forKey: DefaultsKeys.discoveredExternalURL).flatMap(URL.init(string:))
        return (internalURL, externalURL)
    }

    private func lastWorkingURL() -> URL? {
        UserDefaults.standard.string(forKey: DefaultsKeys.lastWorkingURL).flatMap(URL.init(string:))
    }

    private func rememberWorkingURL(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: DefaultsKeys.lastWorkingURL)
    }

    private func rememberDiscoveredURLs(_ config: HAInstanceConfig) {
        let d = UserDefaults.standard
        if let internalURL = config.internalURL {
            d.set(internalURL.absoluteString, forKey: DefaultsKeys.discoveredInternalURL)
        }
        if let externalURL = config.externalURL {
            d.set(externalURL.absoluteString, forKey: DefaultsKeys.discoveredExternalURL)
        }
    }

    private func forgetDiscoveredURLs() {
        let d = UserDefaults.standard
        d.removeObject(forKey: DefaultsKeys.discoveredInternalURL)
        d.removeObject(forKey: DefaultsKeys.discoveredExternalURL)
        d.removeObject(forKey: DefaultsKeys.lastWorkingURL)
    }
}
