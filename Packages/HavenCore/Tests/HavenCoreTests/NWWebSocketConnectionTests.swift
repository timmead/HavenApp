import Testing
import Foundation
import Network
@testable import HavenCore

/// One-shot, thread-safe continuation holder so Network.framework's `@Sendable` state handlers can
/// resume exactly once. A test-local twin of the one inside `NWWebSocketConnection` (which is
/// `private` there, correctly — it is an implementation detail, not API).
private final class TestContinuationBox<T: Sendable>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Error>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<T, Error>) { cont = c }
    func resume(returning value: T) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(returning: value)
    }
    func resume(throwing error: Error) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(throwing: error)
    }
}

@Suite struct NWWebSocketConnectionTests {
    @Test func connectTimesOutAgainstAnUnreachableAddressInsteadOfHangingOnNetworkFrameworksDefault() async throws {
        // 192.0.2.0/24 is IANA's TEST-NET-1 — reserved for documentation, guaranteed to never
        // have a live host answering — a safe stand-in for "the LAN candidate when the phone is
        // away from home." Without NWWebSocketConnection's explicit deadline, Network.framework's
        // own default TCP connect timeout is tens of seconds; this is what proves AppModel's
        // candidate failover isn't starved waiting on that for a dead local address.
        //
        // Constructed with **no explicit deadline**, so it exercises the default — which is the
        // thing that changed (8s → 2s, C2 review finding I-1). Passing `.seconds(2)` here, as this
        // test used to, would have kept passing whatever the default became.
        let url = URL(string: "ws://192.0.2.1:8123/api/websocket")!
        let conn = NWWebSocketConnection(url: url)
        let start = Date()
        await #expect(throws: Error.self) {
            try await conn.connect()
        }
        // Generous upper bound: proves we bailed out near our own deadline, not near
        // Network.framework's much longer default. Kept well above 2s so a loaded machine doesn't
        // flake — the failure this guards against is an order of magnitude away.
        #expect(Date().timeIntervalSince(start) < 8)
    }

    @Test func aConnectionThatNeverBecameReadyReportsNoPeerAddressAndSoFailsClosed() async throws {
        let conn = NWWebSocketConnection(url: URL(string: "ws://192.0.2.1:8123/api/websocket")!)
        _ = try? await conn.connect()
        #expect(conn.observedPeerAddress == nil)
        #expect(ConnectionClass.observed(peerAddress: conn.observedPeerAddress, dialledRemoteCandidate: false) == .remote)
    }

    /// **The assumption Step 0 of the connection model rests on**, pinned by a test rather than a
    /// comment: `NWPath.remoteEndpoint` reports the peer's *resolved address*, not the name we
    /// dialled — even when the connection was created from a `.url(…)` endpoint, which is exactly
    /// how `NWWebSocketConnection` creates it, and even when the host is a name.
    ///
    /// If that were not so, `PeerEndpointAddress.address(of:)` would return `nil` for every
    /// connection, `ConnectionClass.observed` would fail closed to `.remote` every time,
    /// `DiscoveredCandidateURLs.validating` would adopt nothing ever, and the symptom would be
    /// "remote access never works" — with no error logged anywhere and every other test still
    /// green. That is the same silent shape as the `purgeDiscoveredURLs` trap one layer down, and
    /// it is why this is worth an in-process socket instead of a comment asserting the behaviour.
    ///
    /// Uses a plain-TCP `NWListener` on loopback in this process — plain TCP rather than WebSocket
    /// because the question is about address resolution, not framing. No Home Assistant, live or
    /// otherwise, is contacted; nothing leaves the machine.
    /// The other half of the same assumption, through **the real class**: `NWWebSocketConnection`
    /// reaching `.ready` against a name actually populates `observedPeerAddress`, with the
    /// WebSocket framer in the protocol stack rather than raw TCP.
    ///
    /// The test below proves Network.framework resolves names; the fail-closed test above proves
    /// the property is empty when the connection never becomes ready. This is the seam between
    /// them — `recordPeerAddress()` firing on the success path of the class the app really uses —
    /// and it is the link the trust decision rides on, so it should not be the one part left to
    /// inference.
    ///
    /// In-process loopback listener, WebSocket over TCP. No Home Assistant is contacted.
    @Test func aReadyWebSocketConnectionObservesItsPeerAddressAndClassifiesLocal() async throws {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }
        let queue = DispatchQueue(label: "test.ws-peer-address.listener")
        listener.newConnectionHandler = { $0.start(queue: queue) }
        let port: UInt16 = try await withCheckedThrowingContinuation { c in
            let box = TestContinuationBox(c)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): box.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }

        let conn = NWWebSocketConnection(url: URL(string: "ws://localhost:\(port)/api/websocket")!)
        defer { conn.close() }
        try await conn.connect()

        let address = conn.observedPeerAddress
        #expect(address == "127.0.0.1" || address == "::1")
        #expect(ConnectionClass.observed(peerAddress: address, dialledRemoteCandidate: false) == .local)
    }

    @Test func remoteEndpointReportsAResolvedAddressEvenWhenDialledByName() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        defer { listener.cancel() }
        let queue = DispatchQueue(label: "test.peer-address.listener")
        listener.newConnectionHandler = { $0.start(queue: queue) }
        let port: UInt16 = try await withCheckedThrowingContinuation { c in
            let box = TestContinuationBox(c)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error): box.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }

        // A `.url(…)` endpoint with a *name* host — the hardest case, and the one the app actually
        // uses (`AppModel.serverURLText` defaults to `http://homeassistant.local:8123`).
        let conn = NWConnection(to: .url(URL(string: "http://localhost:\(port)/api/websocket")!), using: .tcp)
        defer { conn.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let box = TestContinuationBox(c)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(returning: ())
                case .failed(let error): box.resume(throwing: error)
                default: break
                }
            }
            conn.start(queue: queue)
        }

        let address = PeerEndpointAddress.address(of: conn.currentPath?.remoteEndpoint)
        // Resolved to a literal, not left as the name "localhost".
        #expect(address != nil)
        #expect(address == "127.0.0.1" || address == "::1")
        // And it classifies the way the trust rule needs it to.
        #expect(ConnectionClass.observed(peerAddress: address, dialledRemoteCandidate: false) == .local)
    }
}
