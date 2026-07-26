import SwiftUI
import HavenCore

/// UserDefaults keys for everything `AppModel` persists about how to reach the current HA
/// instance. None of this is a secret (unlike the tokens in `KeychainTokenStore`), so plain
/// `UserDefaults` is fine.
private enum DefaultsKeys {
    static let baseURL = "baseURL"
    /// `get_config`'s `internal_url`, adopted only when learned over a `.local` connection — see
    /// `DiscoveredCandidateURLs`. Name shared with `DiscoveredURLMigration` rather than
    /// redeclared, so the one-time migration and the read/write accessors can never drift apart.
    static let discoveredInternalURL = DiscoveredURLMigration.discoveredInternalURLKey
    /// `get_config`'s `external_url`, same rule — adopted only when learned over a `.local`
    /// connection, and always stored as `https`.
    static let discoveredExternalURL = DiscoveredURLMigration.discoveredExternalURLKey
    /// The candidate URL that last completed a full connect (auth + bootstrap). Feeds
    /// `ConnectionEndpoint.candidates`'s `preferredFirst` hoist.
    static let lastWorkingURL = DiscoveredURLMigration.lastWorkingURLKey
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

    /// Task 3's one-tap fix for a Nabu Casa subscriber who has switched remote access off. A
    /// sibling to `onboarding`, attached/reset the same way, for the reasons documented on
    /// `RemoteAccessOfferModel` itself.
    let remoteAccessOffer = RemoteAccessOfferModel()

    /// Layers 1 and 2 of the home-detection stack. Both are **accelerators**: they only ever change
    /// the *order* `ConnectionEndpoint`'s candidates are tried in, never which ones exist, so the
    /// app stays fully correct with the SSID layer permanently unavailable (Location Services
    /// denied — the expected choice, and never prompted for during onboarding). Neither holds any
    /// ordering logic; that lives in `ConnectionPreference`, in HavenCore, with tests.
    let pathObserver = NetworkPathObserver()
    let homeNetwork = HomeNetwork()

    /// What `cloud/status` last said about this instance's Nabu Casa remote access, or `nil` if
    /// we haven't asked yet (or have signed out). Purely a rendering input — the classification
    /// itself is `NabuCasaRemoteAccessDetector.classify`, in HavenCore with tests, and `App/` may
    /// only display what it produced. Read by `ConnectionSettingsView`: `.remoteDisabled` drives
    /// Task 3's offer, and the four outcomes that route to the custom-URL path render
    /// `NabuCasaRemoteAccess.customRemoteURLGuidance` above that field.
    ///
    /// Note this is set regardless of whether the connection was local or remote: it is honest to
    /// *say* remote access exists no matter where we heard it. What must not happen over a remote
    /// connection is *adopting* the URL, and that decision lives in `adoptableRemoteURL` below,
    /// not here.
    private(set) var remoteAccess: NabuCasaRemoteAccess?

    /// The user's own externally-reachable URL — Tailscale, a reverse proxy — or `nil` if they
    /// haven't set one. The second of the two supported remote paths, alongside Nabu Casa, and
    /// **independent of it**: it has its own storage slot precisely so that someone running both
    /// doesn't lose this one the next time `cloud/status` answers. See `CustomRemoteURLStore`.
    ///
    /// Mirrored here rather than read from the store on every access so the settings screen redraws
    /// when it changes; `customRemoteURLStore` remains the single writer, and this is only ever
    /// assigned from what the store returned.
    private(set) var customRemoteURL: URL?

    private let tokens: TokenStore = KeychainTokenStore()
    private let oauth = OAuthClient()
    private let http = URLSessionHTTP()
    private let web = WebAuthPresenter()
    private let policy = ReconnectPolicy()
    private let customRemoteURLStore = CustomRemoteURLStore()
    private var baseURL: URL?
    private var tokenProvider: TokenProvider?

    /// Loads images that live behind Home Assistant's authentication — media-player artwork and
    /// camera snapshots — for the current session. `nil` while signed out.
    ///
    /// Built alongside the `TokenProvider` (see `beginSession`) rather than once at launch,
    /// because its in-memory cache belongs to *one instance*: carried across a sign-in against a
    /// different Home Assistant it would serve the previous account's pictures for same-named
    /// entities, the same reason `HomeStore.reset` clears history.
    ///
    /// Within a session it never needs updating, and that is by construction: it holds no base URL
    /// and no token of its own, asking the `TokenProvider` for both at the moment each request is
    /// made. So a local↔remote failover — which changes the address mid-session — is picked up
    /// with nothing to notify. Views read it from here; there is deliberately no `EnvironmentKey`
    /// for it, since such a key needs a default value and a loader pointed at nothing is a
    /// blank-tile generator.
    private(set) var imageLoader: AuthenticatedImageLoader?
    /// The class of the connection `remoteAccess`/`remoteAccessOffer` were last computed over.
    /// Needed again when `remoteAccessOfferModel`'s own re-probe (after a successful enable) comes
    /// back, so that re-probe can go through the exact same adoption path
    /// (`rememberNabuCasaRemoteAccess`) as the original connect-time one rather than a second,
    /// undertested copy of it. Defaults to `.remote` if somehow read before ever being set — the
    /// same fail-closed stance `ConnectionClass.observed` takes when a signal is unavailable: worst
    /// case a URL goes un-adopted, never the reverse.
    private var currentConnectionClass: ConnectionClass?
    /// The active connect loop. Retrying is now unbounded, so this must be explicitly
    /// cancellable — otherwise a stale loop from a previous session could keep retrying in the
    /// background and later flip `phase` back to `.ready` after a `signOut()`.
    private var connectTask: Task<Void, Never>?

    init() {
        // Runs here — once per launch, gated to once per device by its own flag — and deliberately
        // NOT inside `connect()`. Its predecessor (`purgeDiscoveredURLs()`) was called at the top
        // of every iteration of `connect()`'s `while true` loop, which with adoption re-enabled
        // would delete the URL learned at the end of one round before the next round reads it:
        // "remote access never works", no error anywhere. See `DiscoveredURLMigration`.
        DiscoveredURLMigration.runIfNeeded(in: .standard)
        // Read once here rather than on every candidate round: the store is the only writer and
        // `saveCustomRemoteURL`/`clearCustomRemoteURL` keep this in step with it. Note the
        // migration above deliberately does not touch this key — see `CustomRemoteURLStore`.
        customRemoteURL = customRemoteURLStore.url
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
        // Task 3's re-probe after a successful `cloud/remote/connect`. Routed back through
        // `rememberNabuCasaRemoteAccess` rather than letting `RemoteAccessOfferModel` write
        // `UserDefaults` itself — see that method's documentation for why there is exactly one
        // adoption path. `currentConnectionClass` is whatever the live connection was last
        // classified as; nothing changes it between the original probe and this one, since both
        // run over the same socket.
        remoteAccessOffer.onReprobe = { [weak self] result in
            guard let self else { return }
            self.rememberNabuCasaRemoteAccess(result, learnedOver: self.currentConnectionClass ?? .remote)
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
        beginSession(at: url)
        await startConnecting()
    }

    /// Creates the per-session objects that depend on a `TokenProvider`, together.
    ///
    /// One function rather than a pair of assignments at each call site so the two cannot drift:
    /// an `imageLoader` left holding a *previous* session's provider would resolve every image
    /// against an address nothing else is using any more — and since it caches, would keep serving
    /// the old instance's pictures without a single failed request to show for it.
    private func beginSession(at url: URL) {
        let provider = TokenProvider(baseURL: url, store: tokens, oauth: oauth, http: http)
        tokenProvider = provider
        imageLoader = AuthenticatedImageLoader(credentials: provider)
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
        // Read before the write below replaces it, for the host comparison after
        // `forgetDiscoveredURLs()`.
        let previousBase = savedBaseURL()
        serverURLText = normalized
        baseURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: DefaultsKeys.baseURL)
        // Whatever was discovered/remembered belonged to whichever instance was previously
        // signed into (possibly a different host) — never let it leak into this instance's
        // candidate list.
        forgetDiscoveredURLs()
        // The custom remote URL is deliberately *not* in `forgetDiscoveredURLs()` — the user typed
        // it, and it must survive a plain re-authorization (see `signOut()`). But the sentence above
        // applies to it just as much as to the discovered ones, and this is the one path that can
        // reach a *different* instance without passing through `signOut()`:
        // `requireReauthentication()` keeps `serverURLText`, the user edits it to another host, and
        // signs in. Carrying the old instance's remote address into the new one's candidate list
        // would hand the new instance's access token to the old host — the C-1 shape. So: cleared on
        // a host change, kept when re-authorizing against the same host.
        if let previousBase, previousBase.host()?.lowercased() != url.host()?.lowercased() {
            clearCustomRemoteURL()
        }
        phase = .connecting
        havenLog.info("OAuth starting against \(url.absoluteString, privacy: .public)")
        do {
            let t = try await oauth.login(baseURL: url, web: web, http: http)
            havenLog.info("token exchange OK (hasRefresh=\(t.refreshToken != nil, privacy: .public))")
            try tokens.save(t)
            beginSession(at: url)
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
        // Cleared here and **not** in `forgetDiscoveredURLs()`, which `signIn()` also calls. The
        // user typed this address; it must not vanish because a refresh token expired, sent them
        // through `requireReauthentication()` (which deliberately keeps the server URL so they only
        // re-authorize) and back into `signIn()`. The two boundaries that *do* discard it are this
        // one and a sign-in against a different host — see `signIn()`; both mean the instance this
        // address describes is being left behind.
        clearCustomRemoteURL()
        baseURL = nil
        tokenProvider = nil
        // Dropped, not just cleared: these are pictures of the user's home, fetched with their
        // token, and nothing signed out has any business still holding them in memory.
        imageLoader = nil
        await store.reset()
        onboarding.reset()
        remoteAccessOffer.reset()
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
        imageLoader = nil
        await store.reset()
        onboarding.reset()
        remoteAccessOffer.reset()
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
    /// candidate in a round has failed. Which candidates exist is `ConnectionEndpoint.candidates`
    /// (`*.ui.nabu.casa` always remote, remote always `https`/`wss`, no duplicates); what order
    /// they are tried in is `ConnectionPreference.candidates`, from the SSID match and the network
    /// path class. Both are pure functions in HavenCore with tests — no ordering decision is made
    /// here, because `App/` has no test target and a decision made here is unverifiable.
    ///
    /// Discovered URLs are read fresh at the top of each round (rather than hoisted out of the
    /// loop) so that a URL learned by a *previous* round's successful-then-dropped connection is
    /// picked up on the next one. Nothing in this loop ever deletes them — see
    /// `DiscoveredURLMigration` for why that sentence is load-bearing.
    ///
    /// `lastWorkingURL` feeds `ConnectionPreference`'s hoist, which avoids re-probing a candidate
    /// that already lost when several of the same class are known. It needs no validation of its
    /// own: the hoist can only *reorder* a candidate already in the list, never introduce one, so
    /// the worst a bogus value can do is nothing at all — and it is deliberately not allowed to
    /// outrank the SSID/path signal, so a value written last night at home cannot drag the local
    /// candidate back to the front this morning on cellular.
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
            // Layer 1, re-read every round because the phone may have moved between rounds. Returns
            // `nil` — "unknown", behaving exactly as if this layer did not exist — whenever Location
            // Services is not authorized or no home network has been captured yet. That is the
            // common case and it must stay fully correct; see `HomeNetwork`.
            let ssidMatch = ConnectionPreference.homeSSIDMatch(
                current: await homeNetwork.currentSSID(),
                home: homeNetwork.homeSSID
            )
            let candidates = ConnectionPreference.candidates(
                userEntered: base,
                discoveredInternal: storedURL(DefaultsKeys.discoveredInternalURL),
                discoveredExternal: storedURL(DefaultsKeys.discoveredExternalURL),
                customRemote: customRemoteURL,
                lastWorking: storedURL(DefaultsKeys.lastWorkingURL),
                homeSSIDMatch: ssidMatch,
                pathClass: pathObserver.pathClass
            )
            // Only escalate to `requireReauthentication()` once *every* candidate this round has
            // hit the "already spent this call's one forced refresh, still auth_invalid" wall —
            // see the check after this round's candidate loop, and the comment at the guard below.
            var candidatesWithPersistentAuthInvalid = 0
            // Same shape, same reason: one candidate blocked by App Transport Security is not a
            // reason to stop. A user whose *typed* address is a FQDN that resolves to a LAN IP has
            // that candidate blocked (ATS judges the hostname, not the address it resolves to)
            // while their discovered `internal_url` — a private-IP literal, which
            // `NSAllowsLocalNetworking` permits — refreshes and connects perfectly. Only when
            // *every* candidate this round was refused is there nothing left to try.
            var candidatesBlockedByATS = 0
            var atsBlockedMessage: String?

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
                        UserDefaults.standard.set(candidate.url.absoluteString, forKey: DefaultsKeys.lastWorkingURL)
                        // The UI must become usable now, not after `fetchInstanceConfig` below:
                        // `request(_:)` (and so `get_config`) is deliberately unbounded — a server
                        // that authenticates and bootstraps fine but never answers `get_config`
                        // must not pin the connecting spinner forever over a socket that is
                        // otherwise perfectly live and usable.
                        phase = .ready
                        // Best-effort, fire-and-forget: learning the instance's own URLs is a
                        // nice-to-have for the *next* connection, never a reason to hold up (or
                        // fail) this one. The `!Task.isCancelled` guard covers the `UserDefaults`
                        // write specifically — without it, a `connect()` cancelled while this
                        // await was in flight (e.g. by a sign-out that started after
                        // `phase = .ready`) could still persist a URL for a session already gone.
                        // **The trust decision, and it is made from the socket — plus one more
                        // signal.** Not from the URL we dialled, not from its hostname, not from
                        // DNS — from the address the kernel is actually sending bytes to, read off
                        // this connection once it reached `.ready`. A hostname cannot answer "is
                        // this on my LAN", and on a hostile network neither can the resolver;
                        // `ha.example.com` looks exactly like a LAN address in every respect except
                        // the one that matters. Unavailable address ⇒ `.remote` ⇒ nothing adopted:
                        // fail closed, because the two mistakes cost wildly different amounts (see
                        // `ConnectionClass.observed`).
                        //
                        // `ssidMatch` (computed once per round, above) is passed straight through as
                        // the second signal rather than re-derived here: a globally-routable IPv6
                        // home network (SLAAC GUA) is otherwise indistinguishable from an internet
                        // host by address alone, and this is the one place that gap is closed. `nil`
                        // (permission absent / no home network captured yet) flows through unchanged
                        // as "unknown" — never as "home".
                        let peerAddress = conn.observedPeerAddress
                        // `dialledRemoteCandidate` is our own record of which slot this candidate
                        // came from, not a guess from its hostname (review finding I-1): if we
                        // deliberately went out to the internet, nothing observed afterwards makes
                        // the connection local — not the peer address, not the SSID.
                        let learnedOver = ConnectionClass.observed(
                            peerAddress: peerAddress,
                            onKnownHomeNetwork: ssidMatch,
                            dialledRemoteCandidate: candidate.isRemote
                        )
                        // Logged because "remote access never appeared" otherwise has several
                        // indistinguishable causes, and two of them are signals we simply couldn't
                        // read (address unavailable, SSID unknown).
                        havenLog.info("peer address \(peerAddress ?? "unavailable", privacy: .public), SSID match \(ssidMatch.map(String.init(describing:)) ?? "unknown", privacy: .public) → classified \(learnedOver == .local ? "local" : "remote", privacy: .public)")
                        // `do`/`catch` rather than `try?` (review M-2): a throw here costs the URL
                        // adoption *and* the `components` signal the onboarding probe falls back
                        // from, and `fetchInstanceConfig`'s own comment promises the wire-shape risk
                        // is "logged loudly at the earliest possible point". That promise only holds
                        // for a successful decode with empty components — a transport failure
                        // mid-`get_config`, or a payload that fails to decode at all, was swallowed
                        // here with no log anywhere. Silent, and this project's recurring shape.
                        do {
                            let config = try await home.fetchInstanceConfig()
                            if !Task.isCancelled {
                                rememberDiscoveredURLs(config, learnedOver: learnedOver)
                            }
                        } catch {
                            havenLog.error("get_config failed: \(error, privacy: .public) — no URLs learned from this connection, and the components signal is unavailable to the onboarding probe")
                        }
                        // Capture the home Wi-Fi network automatically, so the user never types an
                        // SSID for the common case — gated on `learnedOver`, which the SSID match
                        // itself now feeds. When it was the *peer address* that said local, this is
                        // positive independent evidence, so a café's SSID still can never be
                        // recorded as home that way. When it was the SSID match that said local
                        // (the GUA case), this simply re-records the same network already on file —
                        // `rememberCurrentNetworkAsHome` no-ops once the current SSID already equals
                        // `homeSSID`, so nothing new is captured either way. A no-op without
                        // Location Services; granting it later simply means the next local
                        // connection captures it.
                        if learnedOver == .local, !Task.isCancelled {
                            await homeNetwork.rememberCurrentNetworkAsHome()
                        }
                        // Same best-effort footing, and read-only: `probeHavenIntegration` only
                        // ever asks questions. Nothing that changes the user's Home Assistant can
                        // happen without them confirming it first (see
                        // `OnboardingModel.confirmPendingMutation`), so this is safe to run
                        // unattended on every connect — which is also what
                        // lets the flow pick itself back up after the restart step drops the
                        // socket.
                        if !Task.isCancelled {
                            onboarding.attach(home)
                            await onboarding.probe()
                        }
                        // Same live connection, for Task 3's offer — see `RemoteAccessOfferModel`.
                        remoteAccessOffer.attach(home)
                        // Nabu Casa bootstrap: ask the instance whether it has remote access and
                        // at what domain, so remote access needs zero configuration. Same
                        // best-effort footing as `get_config` above — `fetchCloudStatus` never
                        // throws, and an instance without the `cloud` component simply answers
                        // `unknown_command`, which is the ordinary self-hosted user rather than a
                        // failure. Deliberately runs on *every* connection, local or remote: the
                        // classification is safe to know either way, and gating the probe itself
                        // on the connection class would put a security decision here, in code with
                        // no test target, instead of in the one function that owns it.
                        //
                        // **Last, deliberately.** `HAWebSocketClient.request` has no deadline (see
                        // the `phase = .ready` comment above), so every unbounded call added here
                        // can starve the ones after it. An instance that authenticates, bootstraps
                        // and answers `get_config` but hangs on `cloud/status` must not be able to
                        // stop the guided-install probe from ever running — that would surface as
                        // "the havenapp setup flow never appears", with nothing logged. Nothing
                        // here depends on ordering except that it follow `rememberDiscoveredURLs`,
                        // which it still does, so `cloud/status` keeps precedence over
                        // `external_url` for the discovered-remote slot.
                        let cloudStatus = await home.fetchCloudStatus()
                        if !Task.isCancelled {
                            rememberNabuCasaRemoteAccess(cloudStatus, learnedOver: learnedOver)
                        }
                        return
                    } catch TokenProviderError.reauthenticationRequired {
                        await client?.disconnect()
                        if Task.isCancelled { return }
                        havenLog.error("token refresh requires reauthentication — signing out")
                        await requireReauthentication()
                        return
                    } catch TokenProviderError.insecureTransportBlocked(let host) {
                        await client?.disconnect()
                        if Task.isCancelled { return }
                        candidatesBlockedByATS += 1
                        // The message is HavenCore's, not assembled here — see
                        // `TokenProviderError.message`.
                        atsBlockedMessage = TokenProviderError.insecureTransportBlocked(host: host).message
                        // Logged by name, at error level, because the whole point of classifying
                        // this is that it stops being invisible: before, a blocked refresh arrived
                        // as an opaque URLError, was retried forever, and left the user on
                        // "connecting…" with nothing anywhere naming ATS.
                        havenLog.error("App Transport Security refused the token refresh to \(host, privacy: .public) — cleartext http:// to a host iOS judges public. This candidate cannot succeed until the address is https, or a local-network address; see the ATS comment in Info.plist.")
                        // Nothing is retried in place and the session is left intact (the grant is
                        // fine, the address isn't); the next candidate gets its turn.
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
            if !candidates.isEmpty, candidatesBlockedByATS == candidates.count, let atsBlockedMessage {
                // Terminal, and the one failure in this loop that must NOT back off and retry: it
                // is deterministic and caused by configuration, so the thousandth attempt fails
                // exactly like the first. Retrying it is the silent hang this classification
                // exists to remove. `.error` lands on `LoginView` with the address prefilled and
                // editable, which is precisely the remedy the message describes — and the tokens
                // are left alone, so a user who fixes the address doesn't have to sign in again if
                // the session is still good.
                havenLog.error("every candidate this round was refused by App Transport Security — stopping rather than retrying a failure that cannot resolve itself")
                phase = .error(atsBlockedMessage)
                return
            }
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

    /// A plain read of persisted state, with no validation — deliberately.
    ///
    /// Everything under these keys was written by `rememberDiscoveredURLs` below, which adopts
    /// only what `DiscoveredCandidateURLs.validating` returned for a `.local` connection. The
    /// trust decision therefore already happened, once, at the write boundary, in a pure function
    /// with tests. Re-deciding it here — where nothing can test it — is how the earlier rounds
    /// ended up with a read-side gate keyed on `isNabuCasaHost`: untested, and wrong in exactly
    /// the way the C-1 finding described. Values written by builds that predate the current rule
    /// are handled once by `DiscoveredURLMigration`, not re-litigated on every read.
    private func storedURL(_ key: String) -> URL? {
        UserDefaults.standard.string(forKey: key).flatMap(URL.init(string:))
    }

    /// The write boundary. `config` came straight off the wire, and whatever is persisted here
    /// becomes a future connection candidate that `TokenProvider.setBaseURL` will later POST the
    /// refresh token to — so the *only* thing that makes it safe is `learnedOver`: a `.local`
    /// connection means this response came from the user's own Home Assistant inside the trusted
    /// zone. Over a `.remote` connection `validating` adopts nothing, and this writes nothing;
    /// discovery only ever flows inward. `AppModel` holds no adoption logic of its own — it hands
    /// both raw values and the connection class to the pure function and stores the result.
    private func rememberDiscoveredURLs(_ config: HAInstanceConfig, learnedOver: ConnectionClass) {
        let d = UserDefaults.standard
        let validated = DiscoveredCandidateURLs.validating(
            rawInternalURL: config.internalURL,
            rawExternalURL: config.externalURL,
            learnedOver: learnedOver
        )
        if let internalURL = validated.internalURL {
            d.set(internalURL.absoluteString, forKey: DefaultsKeys.discoveredInternalURL)
        }
        if let externalURL = validated.externalURL {
            d.set(externalURL.absoluteString, forKey: DefaultsKeys.discoveredExternalURL)
        }
        // Logged, not silent: "remote access never appeared" has three quite different causes and
        // they are indistinguishable from the outside.
        if learnedOver == .remote, config.internalURL != nil || config.externalURL != nil {
            havenLog.info("get_config answered over a remote connection — not adopting its URLs; a remote address is only ever learned on the local network")
        } else if config.internalURL == nil && config.externalURL == nil {
            havenLog.error("get_config returned neither internal_url nor external_url — nothing to remember for the next connection")
        }
    }


    /// The Nabu Casa half of the write boundary, and the same shape as `rememberDiscoveredURLs`:
    /// hand the raw result and the observed connection class to pure functions, store what comes
    /// back. No branching on `logged_in`, `active_subscription`, `remote_enabled` or
    /// `remote_connected` happens here — every one of those decisions is
    /// `NabuCasaRemoteAccessDetector.classify`'s, in HavenCore, under test.
    ///
    /// The URL goes through `adoptableRemoteURL`, which is implemented *by calling*
    /// `DiscoveredCandidateURLs.validating` — the exact function `get_config`'s URLs already flow
    /// through. There is therefore one place in the codebase that decides whether a self-reported
    /// address may be remembered, not two that have to agree.
    ///
    /// It writes to the same `discoveredExternalURL` slot `get_config`'s `external_url` uses, and
    /// runs after it, so `cloud/status` wins when both answer. That is the right precedence for
    /// Nabu Casa — `remote_domain` is the cloud's own authority on its tunnel, whereas
    /// `external_url` is free text the user may have set to anything. A user running *both* Nabu
    /// Casa and their own reverse proxy keeps the latter regardless: it lives in its own slot
    /// (`CustomRemoteURLStore`) and is a separate candidate, ordered after this one.
    ///
    /// It can also *clear* that slot, when `storedRemoteURLIsSuperseded` says a stored Nabu Casa URL
    /// has outlived its subscription — see below and review finding M-4.
    private func rememberNabuCasaRemoteAccess(
        _ status: Result<HACloudStatus, WSError>,
        learnedOver: ConnectionClass
    ) {
        let outcome = NabuCasaRemoteAccessDetector.classify(status)
        remoteAccess = outcome
        currentConnectionClass = learnedOver
        // Task 3's offer, from the same result — never re-probed separately, so it can never
        // disagree with `outcome` above about what `cloud/status` actually said.
        remoteAccessOffer.update(NabuCasaRemoteAccessDetector.offer(from: status, over: learnedOver))
        // The one thing that removes a stored remote URL outside sign-in/sign-out, and it removes
        // only a *dead* one: a `*.ui.nabu.casa` address whose subscription has lapsed, established
        // over a local connection. The predicate is HavenCore's — including the reason it must not
        // fire on `.indeterminate` (a transport blip) or on a self-hosted `external_url` sharing the
        // slot. Without it a lapsed tunnel stays ahead of the user's own remote address forever.
        if NabuCasaRemoteAccessDetector.storedRemoteURLIsSuperseded(
            storedURL(DefaultsKeys.discoveredExternalURL), by: outcome, learnedOver: learnedOver
        ) {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.discoveredExternalURL)
            havenLog.info("cloud/status → \(String(describing: outcome), privacy: .public); the stored Nabu Casa remote URL no longer works and was removed")
        }
        guard let url = NabuCasaRemoteAccessDetector.adoptableRemoteURL(
            from: outcome, learnedOver: learnedOver
        ) else {
            // Logged, not silent: "remote access never appeared" has several quite different
            // causes and they are indistinguishable from the outside — no cloud component, no
            // subscription, remote switched off, or a perfectly good answer we declined to adopt
            // because we heard it over the internet.
            havenLog.info("cloud/status → \(String(describing: outcome), privacy: .public); no remote URL adopted (connection classified \(learnedOver == .local ? "local" : "remote", privacy: .public))")
            return
        }
        UserDefaults.standard.set(url.absoluteString, forKey: DefaultsKeys.discoveredExternalURL)
        havenLog.info("cloud/status → Nabu Casa remote access at \(url.absoluteString, privacy: .public), adopted")
    }

    /// Settings' "save" for the custom remote URL. Pure forwarding: every decision — HTTPS required,
    /// `http://` refused rather than upgraded, what the refusal *says*, and whether anything is
    /// written at all — belongs to `CustomRemoteURLStore`/`CustomRemoteURL` in HavenCore, where it
    /// is tested. The view renders the returned error's `message` verbatim.
    @discardableResult
    func saveCustomRemoteURL(_ raw: String) -> Result<URL, CustomRemoteURLError> {
        let result = customRemoteURLStore.save(raw)
        // Only on success, so a rejected entry leaves the working address in place both in storage
        // and on screen.
        if case .success(let url) = result { customRemoteURL = url }
        return result
    }

    func clearCustomRemoteURL() {
        customRemoteURLStore.clear()
        customRemoteURL = nil
    }

    private func forgetDiscoveredURLs() {
        let d = UserDefaults.standard
        // Describes the previous instance's cloud account, not this one's — carrying it across
        // would render a stale (and possibly contradictory) remote-access state for a home it
        // says nothing about.
        remoteAccess = nil
        currentConnectionClass = nil
        remoteAccessOffer.update(nil)
        d.removeObject(forKey: DefaultsKeys.discoveredInternalURL)
        d.removeObject(forKey: DefaultsKeys.discoveredExternalURL)
        d.removeObject(forKey: DefaultsKeys.lastWorkingURL)
        // The captured home SSID describes the network *this* instance was reached on. Carried
        // into a different instance it would be a confidently wrong "you are home" signal.
        homeNetwork.forgetHomeNetwork()
    }
}
