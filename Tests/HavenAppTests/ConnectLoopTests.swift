import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// **The candidate loop, driven end to end for the first time.**
///
/// `connect()`'s own doc comment spent two rounds recording that nothing exercised it, and the
/// reason was one line: `NWWebSocketConnection` was constructed inline. Everything else the loop
/// touches was already injectable. With `makeConnection` and `http` passed in, the loop's actual
/// decisions — try candidates in order, spend the forced-refresh budget at most once per call,
/// and never act on a single candidate's word about ATS or `auth_invalid` — can be asserted
/// instead of read.
///
/// The rule these are written to defend is the one the code states and no test held it to: **a
/// single candidate is never trusted to end the session.** A rogue device answering on port 8123
/// of the LAN can return `auth_invalid` all day; if that alone signed the user out, it would have
/// stolen the session before the genuine remote candidate was ever dialled.
@Suite @MainActor struct ConnectLoopTests {
    // MARK: - Fakes

    /// How one candidate address behaves when dialled.
    enum Behaviour: Sendable {
        /// Authenticates and serves an empty-but-valid instance.
        case succeeds
        /// Answers `auth_invalid` every time, however fresh the token.
        case alwaysAuthInvalid
        /// Answers `auth_invalid` once, then accepts. Models a genuinely stale access token.
        case authInvalidThenSucceeds
        /// The socket never opens at all — unreachable address.
        case unreachable
    }

    /// Speaks just enough of Home Assistant's protocol for `authenticate` + `bootstrap` +
    /// `finishConnecting` to run to completion: the auth handshake, empty registries, and
    /// `unknown_command` for everything else (which is what a self-hosted instance without the
    /// `cloud` or `havenapp` components genuinely answers).
    ///
    /// Empty registries are deliberate. This suite is about *which address the loop settles on*,
    /// not about what came back over it — `HomeConnectionTests` covers the parsing. An empty home
    /// bootstraps successfully and keeps these tests to one subject.
    /// **One socket is one dial.** Whether this dial accepts the token is decided by the `Dialler`
    /// and handed over at construction, because the loop's whole retry-in-place behaviour is to
    /// *open a second socket to the same address* — so "reject the first attempt, accept the
    /// second" is a property of the host across dials, not of one connection. Counting attempts
    /// inside the socket looked right and made a genuinely-recoverable token look permanently dead,
    /// because every retry got a fresh counter.
    final actor FakeSocket: PeerObservableConnection {
        private let reachable: Bool
        private let acceptsAuth: Bool
        private var incoming: [Data] = []
        private var waiters: [CheckedContinuation<Data, Error>] = []

        init(reachable: Bool, acceptsAuth: Bool) {
            self.reachable = reachable
            self.acceptsAuth = acceptsAuth
        }

        /// Left at the protocol's fail-closed default of `nil`. These tests are about the loop, and
        /// a fake that claimed to know where its bytes were going would be reaching into the trust
        /// decision `AppModelTrustTests` owns.
        nonisolated func close() {}

        func connect() async throws {
            guard reachable else { throw URLError(.cannotConnectToHost) }
            enqueue(#"{"type":"auth_required"}"#)
        }

        func send(_ data: Data) async throws {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { return }
            if type == "auth" {
                enqueue(acceptsAuth ? #"{"type":"auth_ok"}"#
                                    : #"{"type":"auth_invalid","message":"bad"}"#)
                return
            }
            guard let id = obj["id"] as? Int else { return }
            switch type {
            case "config/floor_registry/list", "config/area_registry/list",
                 "config/device_registry/list", "config/entity_registry/list", "get_states":
                enqueue(#"{"id":\#(id),"type":"result","success":true,"result":[]}"#)
            case "subscribe_events", "ping":
                enqueue(#"{"id":\#(id),"type":"result","success":true,"result":null}"#)
            case "get_config":
                enqueue(#"{"id":\#(id),"type":"result","success":true,"result":{"components":[]}}"#)
            default:
                enqueue(#"{"id":\#(id),"type":"result","success":false,"error":{"code":"unknown_command","message":"no"}}"#)
            }
        }

        /// Parks forever once the script is exhausted rather than returning or throwing. A socket
        /// that ended its receive loop would look to `HomeStore` exactly like a dropped connection
        /// and fire `onDisconnected`, which reconnects — turning a finished test into a live loop.
        func receive() async throws -> Data {
            if !incoming.isEmpty { return incoming.removeFirst() }
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }

        private func enqueue(_ text: String) {
            let data = Data(text.utf8)
            if !waiters.isEmpty { waiters.removeFirst().resume(returning: data) } else { incoming.append(data) }
        }
    }

    /// Records which addresses were dialled, in order, and hands each the behaviour the test
    /// assigned it. The order is the assertion in half these tests.
    final class Dialler: @unchecked Sendable {
        private let lock = NSLock()
        private var behaviours: [String: Behaviour]
        private let fallback: Behaviour
        private var dialledHosts: [String] = []

        init(_ behaviours: [String: Behaviour], fallback: Behaviour = .unreachable) {
            self.behaviours = behaviours
            self.fallback = fallback
        }

        var dialled: [String] { lock.lock(); defer { lock.unlock() }; return dialledHosts }

        func connection(for url: URL) -> any PeerObservableConnection {
            lock.lock()
            let key = url.host() ?? ""
            // How many times this *host* has been dialled so far, which is what
            // `authInvalidThenSucceeds` turns on — see `FakeSocket`.
            let previousDials = dialledHosts.filter { $0 == key }.count
            dialledHosts.append(key)
            let behaviour = behaviours[key] ?? fallback
            lock.unlock()
            switch behaviour {
            case .succeeds:
                return FakeSocket(reachable: true, acceptsAuth: true)
            case .alwaysAuthInvalid:
                return FakeSocket(reachable: true, acceptsAuth: false)
            case .authInvalidThenSucceeds:
                return FakeSocket(reachable: true, acceptsAuth: previousDials >= 1)
            case .unreachable:
                return FakeSocket(reachable: false, acceptsAuth: false)
            }
        }
    }

    /// Answers token refreshes without a network. `atsBlocked` reproduces exactly what iOS raises
    /// when it refuses cleartext to a host it judges public — the error `TokenProvider` classifies
    /// into `insecureTransportBlocked`.
    final class FakeHTTP: HTTPPoster, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let atsBlocked: Bool

        init(atsBlocked: Bool = false) { self.atsBlocked = atsBlocked }

        var refreshCount: Int { lock.lock(); defer { lock.unlock() }; return count }

        func post(_ url: URL, form: [String: String]) async throws -> Data {
            // Scoped rather than bare `lock()`/`unlock()`: those are unavailable from an async
            // context, since a suspension while holding the lock would be a deadlock waiting to
            // happen. Nothing suspends inside here, and `withLock` is how you say that.
            lock.withLock { count += 1 }
            if atsBlocked { throw URLError(.appTransportSecurityRequiresSecureConnection) }
            return Data(#"{"access_token":"fresh","expires_in":1800}"#.utf8)
        }
    }

    // MARK: - Harness

    /// A model with a saved session, so `restoreIfPossible()` walks straight into the candidate
    /// loop — the only route into `connect()` from outside the type.
    ///
    /// `expired` controls whether the loop must refresh before it can dial: with a live token,
    /// `validAccessToken` returns it and no HTTP happens at all, which is what keeps the
    /// ordering tests free of refresh noise.
    private func model(_ name: String = #function,
                       dialler: Dialler,
                       http: FakeHTTP = FakeHTTP(),
                       expired: Bool = false) -> (AppModel, UserDefaults, FakeTokenStore) {
        let defaults = makeTestDefaults(name)
        defaults.set("http://ha.local:8123", forKey: "baseURL")
        let tokens = FakeTokenStore(tokens: HATokens(
            accessToken: "t", refreshToken: "r",
            expiresAt: Date().addingTimeInterval(expired ? -3600 : 3600)))
        let app = AppModel(defaults: defaults, tokens: tokens, http: http) { url in
            dialler.connection(for: url)
        }
        return (app, defaults, tokens)
    }

    private func isReady(_ app: AppModel) -> Bool {
        if case .ready = app.phase { return true }
        return false
    }

    private func errorMessage(_ app: AppModel) -> String? {
        if case .error(let message) = app.phase { return message }
        return nil
    }

    // MARK: - Ordering

    /// The loop tries candidates in order, moves on from one that fails, and stops at the first
    /// that works — and it is the *working* address that gets remembered, not the one the user
    /// typed.
    ///
    /// The unreachable address here is the **discovered internal** one, not the typed one, because
    /// that is the order `ConnectionPreference` actually produces: a learned LAN address outranks
    /// what the user entered. Written the other way round first, this test passed while proving
    /// nothing — the second candidate was never reached, because the first one already worked.
    @Test func aFailedCandidateIsFollowedByTheNextOneAndTheWinnerIsRemembered() async throws {
        let dialler = Dialler(["192.168.1.20": .unreachable, "ha.local": .succeeds])
        let (app, defaults, _) = model(dialler: dialler)
        // A discovered internal address, so the round has two candidates rather than one.
        defaults.set("http://192.168.1.20:8123", forKey: DiscoveredURLMigration.discoveredInternalURLKey)

        await app.restoreIfPossible()

        #expect(isReady(app))
        #expect(dialler.dialled == ["192.168.1.20", "ha.local"],
                "the failing candidate should be tried and abandoned, then the next one dialled")
        #expect(defaults.string(forKey: DiscoveredURLMigration.lastWorkingURLKey) == "http://ha.local:8123")
    }

    // MARK: - The forced-refresh budget

    /// One `auth_invalid` buys exactly one forced refresh, and the candidate is retried **in
    /// place** rather than abandoned — so a genuinely stale token recovers without the user
    /// noticing, and without the loop moving on to a worse address.
    @Test func oneAuthInvalidSpendsTheRefreshAndRetriesTheSameCandidate() async throws {
        let dialler = Dialler(["ha.local": .authInvalidThenSucceeds])
        let http = FakeHTTP()
        let (app, _, tokens) = model(dialler: dialler, http: http)

        await app.restoreIfPossible()

        #expect(isReady(app))
        #expect(http.refreshCount == 1, "the forced refresh should be spent exactly once")
        // Same host twice: retried in place, not abandoned for the next candidate.
        #expect(dialler.dialled == ["ha.local", "ha.local"])
        #expect(tokens.clearCount == 0, "a recoverable auth_invalid must not end the session")
    }

    /// A candidate that rejects the token is abandoned, not obeyed: the loop carries on to the
    /// next one and connects.
    ///
    /// Note the ordering — the rejecting candidate is the discovered internal address, so it is
    /// dialled **first**. With the two the other way round the good candidate wins immediately and
    /// the rejecting one is never reached, which is a test that passes without executing anything
    /// it claims to.
    @Test func aCandidateRejectingTheTokenIsAbandonedForTheNextOne() async throws {
        let dialler = Dialler(["192.168.1.20": .alwaysAuthInvalid, "ha.local": .succeeds])
        let (app, defaults, tokens) = model(dialler: dialler)
        defaults.set("http://192.168.1.20:8123", forKey: DiscoveredURLMigration.discoveredInternalURLKey)

        await app.restoreIfPossible()

        #expect(isReady(app), "the good candidate must still be reached")
        #expect(tokens.clearCount == 0, "one candidate's auth_invalid must not sign the user out")
    }

    /// **The rogue-responder case, and the reason the escalation is corroborated across the whole
    /// round.**
    ///
    /// One candidate insisting the token is dead proves nothing — anything can answer on port 8123
    /// of a LAN. Here that candidate is dialled first and the *only* other candidate is simply
    /// unreachable, so the round ends with nothing connected and one persistent `auth_invalid` on
    /// the tally. The session must survive that: back off and try again, never sign out.
    ///
    /// Asserted from outside the call rather than after it, because the correct behaviour is
    /// **not to terminate** — `connect()` backs off and rounds forever, which is the whole point.
    /// A test that awaited it would hang exactly when the code is right.
    @Test func aRoundWithOnlyOneCandidateRejectingTheTokenRetriesRatherThanSigningOut() async throws {
        let dialler = Dialler(["192.168.1.20": .alwaysAuthInvalid, "ha.local": .unreachable])
        let (app, defaults, tokens) = model(dialler: dialler)
        defaults.set("http://192.168.1.20:8123", forKey: DiscoveredURLMigration.discoveredInternalURLKey)

        let running = Task { await app.restoreIfPossible() }
        // Comfortably longer than a round against these fakes (no I/O at all) and comfortably
        // shorter than `ReconnectPolicy`'s 3s first backoff, so this lands inside the retry wait.
        try await Task.sleep(for: .milliseconds(400))

        #expect(tokens.clearCount == 0,
                "one candidate's word is not enough to end the session, whatever the others did")
        // `isReconnect: false` is the point as much as `.retrying` is: this session has never
        // reached `.ready`, so the screen must not tell the user their connection was *lost*. It
        // was never made. That sentence claims a fault in their setup that does not exist, and it
        // is the one the app used to show on every slow first connect.
        if case .retrying(_, let isReconnect) = app.phase {
            #expect(!isReconnect, "a first connect that has not landed yet is not a lost connection")
        } else {
            Issue.record("expected .retrying after a failed round, got \(app.phase)")
        }

        // Stop the loop before the suite moves on; it would otherwise round forever.
        running.cancel()
        await app.signOut()
    }

    /// …and when *every* candidate says it, it is no longer one device's word. Now the token
    /// really is dead, and the session ends — landing on the sign-in screen with the server
    /// address kept, which is what `requireReauthentication` is for.
    @Test func everyCandidateRejectingTheTokenDoesEndTheSession() async throws {
        let dialler = Dialler(["ha.local": .alwaysAuthInvalid, "192.168.1.20": .alwaysAuthInvalid])
        let (app, defaults, tokens) = model(dialler: dialler)
        defaults.set("http://192.168.1.20:8123", forKey: DiscoveredURLMigration.discoveredInternalURLKey)

        await app.restoreIfPossible()

        if case .loggedOut = app.phase {} else {
            Issue.record("expected .loggedOut, got \(app.phase)")
        }
        #expect(tokens.clearCount > 0)
        // Kept deliberately: the user re-authorizes, they do not retype their server.
        #expect(app.serverURLText.contains("ha.local"))
    }

    // MARK: - App Transport Security

    /// The one failure in the loop that must **not** back off and retry: it is deterministic and
    /// caused by configuration, so the thousandth attempt fails exactly like the first. Before it
    /// was classified, this was an opaque `URLError` retried forever behind "Connecting…".
    ///
    /// That it terminates at all is the assertion — a test that got this wrong would hang rather
    /// than fail, which is itself the bug being pinned.
    @Test func everyCandidateRefusedByATSStopsRatherThanRetryingForever() async throws {
        let dialler = Dialler([:], fallback: .succeeds)
        let http = FakeHTTP(atsBlocked: true)
        // Expired, so a refresh is required before any socket is opened — which is where ATS
        // refuses.
        let (app, _, tokens) = model(dialler: dialler, http: http, expired: true)

        await app.restoreIfPossible()

        let message = try #require(errorMessage(app), "expected a terminal .error phase")
        #expect(message.contains("ha.local"), "the message must name the address that was refused")
        // The grant is fine; the address isn't. Signing out would make the user re-authorize to
        // fix a problem re-authorizing cannot fix.
        #expect(tokens.clearCount == 0)
    }
}
