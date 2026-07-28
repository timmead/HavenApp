import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// **The step between the raw signals and the trust decision.**
///
/// `AppModelURLAdoptionTests` covers the write boundary *given* a `ConnectionClass`, and
/// HavenCore's `ObservedConnectionClassTests` covers `ConnectionClass.observed` given its three
/// inputs. Neither covers the join: that `AppModel` reads the peer address off the live socket,
/// carries the round's SSID match, remembers which slot the candidate came from, and hands all
/// three to `observed` **in their proper roles**. Every argument is individually verified and the
/// wiring between them was not.
///
/// That gap is the shape this project keeps hitting — the URL-adoption fix shipped twice with 107
/// green tests over a helper while the call site went unexercised. Swapping
/// `dialledRemoteCandidate: candidate.isRemote` for `false`, or passing `ssidMatch` into the wrong
/// parameter, breaks the security property while leaving every existing suite green.
///
/// Reachable at all only because lifting `connect()`'s candidate loop apart left
/// `finishConnecting` taking `peerAddress` as a plain parameter instead of reading it from an
/// inline `NWWebSocketConnection`. The transport is still unfakeable; this decision no longer needs
/// it to be.
@Suite @MainActor struct AppModelTrustTests {
    /// Answers `get_config` with both URLs and refuses everything else.
    ///
    /// Refusing rather than ignoring is the load-bearing part: `HAWebSocketClient.request` is a
    /// bare continuation with no deadline, so a command this socket declined to answer would hang
    /// the test forever rather than fail it. `finishConnecting` also drives the onboarding probe
    /// and `cloud/status`, and both are documented as best-effort — an `unknown_command` is the
    /// ordinary self-hosted user, not a failure, so this is a realistic instance as well as a
    /// terminating one.
    private actor ScriptedConfigSocket: WebSocketConnection {
        private var incoming: [Data] = []
        private var waiters: [CheckedContinuation<Data, Error>] = []

        func connect() async throws {}
        nonisolated func close() {}

        func send(_ data: Data) async throws {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? Int, let type = obj["type"] as? String else { return }
            if type == "get_config" {
                enqueue("""
                {"id":\(id),"type":"result","success":true,"result":\
                {"internal_url":"http://192.168.1.20:8123","external_url":"https://ha.example.com",\
                "components":["havenapp"]}}
                """)
            } else {
                enqueue(#"{"id":\#(id),"type":"result","success":false,"error":{"code":"unknown_command","message":"no"}}"#)
            }
        }

        func receive() async throws -> Data {
            if !incoming.isEmpty { return incoming.removeFirst() }
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }

        func enqueue(_ text: String) {
            let data = Data(text.utf8)
            if !waiters.isEmpty { waiters.removeFirst().resume(returning: data) } else { incoming.append(data) }
        }
    }

    private func connection() async throws -> HomeConnection {
        let socket = ScriptedConfigSocket()
        await socket.enqueue(#"{"type":"auth_required"}"#)
        await socket.enqueue(#"{"type":"auth_ok"}"#)
        let client = HAWebSocketClient(connection: socket)
        try await client.authenticate(token: "t")
        return HomeConnection(client: client)
    }

    private let internalKey = DiscoveredURLMigration.discoveredInternalURLKey
    private let externalKey = DiscoveredURLMigration.discoveredExternalURLKey

    /// Both slots, asserted together: this is "did the instance's self-reported addresses become
    /// future connection candidates", which is the whole question.
    private func adopted(_ defaults: UserDefaults) -> Bool {
        defaults.string(forKey: internalKey) != nil || defaults.string(forKey: externalKey) != nil
    }

    /// A private-IP peer address on a candidate we dialled locally is the ordinary "I am at home"
    /// case, and it is the one that must adopt — otherwise remote access never configures itself
    /// and this whole path is dead weight.
    @Test func aLocalPeerAddressOnALocallyDialledCandidateAdopts() async throws {
        let defaults = makeTestDefaults()
        let app = AppModel(defaults: defaults, tokens: FakeTokenStore())

        await app.finishConnecting(home: try await connection(),
                                   candidate: .local(URL(string: "http://192.168.1.20:8123")!),
                                   ssidMatch: nil,
                                   peerAddress: "192.168.1.20")

        #expect(defaults.string(forKey: internalKey) == "http://192.168.1.20:8123")
        #expect(defaults.string(forKey: externalKey) == "https://ha.example.com")
    }

    /// **The address a real device actually reports**, complete with the interface qualifier
    /// `NWPath.remoteEndpoint` appends to it.
    ///
    /// From the log that found this: `peer address 192.168.1.42%en0 … → classified remote`,
    /// followed by `no remote URL adopted`. The `%en0` defeated the strict IPv4 parser, so every
    /// local connection classified `.remote` and nothing was ever learned from one — no
    /// `internal_url`, no `external_url`, no Nabu Casa address. The app failed safe and, in doing
    /// so, permanently failed to configure the remote access it needs when away from home.
    ///
    /// Asserted here as well as in `ObservedConnectionClassTests` on purpose: that suite pins the
    /// classification, this one pins what the classification is *for*. The bug was only visible as
    /// the second thing.
    @Test func aLocalAddressWithAnInterfaceQualifierStillAdopts() async throws {
        let defaults = makeTestDefaults()
        let app = AppModel(defaults: defaults, tokens: FakeTokenStore())

        await app.finishConnecting(home: try await connection(),
                                   candidate: .local(URL(string: "http://192.168.1.20:8123")!),
                                   ssidMatch: nil,
                                   peerAddress: "192.168.1.20%en0")

        #expect(adopted(defaults), "a LAN address with a zone suffix is still a LAN address")
    }

    /// **Fail closed.** No peer address (the socket could not report one) and no SSID signal
    /// (Location Services not granted — the expected, common case) must resolve `.remote`, not
    /// "probably fine": the two mistakes cost wildly different amounts. Nothing is adopted.
    @Test func anUnknownPeerAddressAdoptsNothing() async throws {
        let defaults = makeTestDefaults()
        let app = AppModel(defaults: defaults, tokens: FakeTokenStore())

        await app.finishConnecting(home: try await connection(),
                                   candidate: .local(URL(string: "http://192.168.1.20:8123")!),
                                   ssidMatch: nil,
                                   peerAddress: nil)

        #expect(!adopted(defaults))
    }

    /// **The `dialledRemoteCandidate` wire, and the finding it came from (review I-1).** If we
    /// deliberately went out to the internet, nothing observed afterwards makes the connection
    /// local — not a private-looking peer address, not even a matching home SSID.
    ///
    /// This is the assertion that fails if `candidate.isRemote` is ever dropped from the call, and
    /// it is the one an attacker-shaped test cares about: a remote endpoint that answers from
    /// behind a tunnel can present an address that looks like a LAN address, and the app must not
    /// take its word for what network the bytes crossed.
    @Test func aRemotelyDialledCandidateAdoptsNothingWhateverItLooksLike() async throws {
        let defaults = makeTestDefaults()
        let app = AppModel(defaults: defaults, tokens: FakeTokenStore())

        await app.finishConnecting(home: try await connection(),
                                   candidate: .remote(URL(string: "https://abc.ui.nabu.casa")!),
                                   ssidMatch: true,
                                   peerAddress: "192.168.1.20")

        #expect(!adopted(defaults))
    }

    /// **The `ssidMatch` wire, and the gap it exists to close.** A home network on globally-routable
    /// IPv6 (SLAAC GUA) hands out addresses that are indistinguishable from an internet host's by
    /// address alone, so `ConnectionClass.observed` would fail closed on the address and this
    /// household could never adopt anything. A confirmed match with the captured home network is
    /// the second signal that resolves it — and it only counts because the candidate was dialled
    /// locally, which the test above pins.
    @Test func aConfirmedHomeSSIDRescuesAGloballyRoutableAddress() async throws {
        let defaults = makeTestDefaults()
        let app = AppModel(defaults: defaults, tokens: FakeTokenStore())

        await app.finishConnecting(home: try await connection(),
                                   candidate: .local(URL(string: "http://[2001:db8::1]:8123")!),
                                   ssidMatch: true,
                                   peerAddress: "2001:db8::1")

        #expect(adopted(defaults))
    }

    /// The mirror image, and the reason `ssidMatch` is a three-state `Bool?`: *unknown* is not
    /// *home*. A globally-routable address with no SSID signal at all stays `.remote`.
    @Test func aGloballyRoutableAddressWithNoSSIDSignalAdoptsNothing() async throws {
        let defaults = makeTestDefaults()
        let app = AppModel(defaults: defaults, tokens: FakeTokenStore())

        await app.finishConnecting(home: try await connection(),
                                   candidate: .local(URL(string: "http://[2001:db8::1]:8123")!),
                                   ssidMatch: nil,
                                   peerAddress: "2001:db8::1")

        #expect(!adopted(defaults))
    }
}
