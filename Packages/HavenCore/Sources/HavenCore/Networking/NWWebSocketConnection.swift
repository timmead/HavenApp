import Foundation
import Network

/// One-shot, thread-safe wrapper so a `CheckedContinuation` can be captured in
/// Network.framework's `@Sendable` callbacks without risk of double-resume.
private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
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

/// A `WebSocketConnection` backed by `Network.framework` (`NWConnection`) rather than
/// `URLSessionWebSocketTask`. This avoids the iOS Simulator's `URLSession` WebSocket
/// breakage and talks to the socket directly, which is what Home Assistant expects.
@available(iOS 13, macOS 10.15, *)
public final class NWWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.haven.websocket")
    /// Bounds how long `connect()` can hang on an address that never answers — e.g. the LAN
    /// candidate when the phone is away from home. Network.framework's own default TCP connect
    /// timeout is much longer (tens of seconds), which would otherwise starve `AppModel`'s
    /// candidate failover of any real chance to fall back to the remote URL in a reasonable time.
    /// Deliberately *not* applied to `receive()` — see the note on that method.
    ///
    /// The default is **2 seconds**, down from 8. A LAN connect is sub-100ms, so 2s is already
    /// orders of magnitude of headroom for the case this bounds; 8s was C2 review finding I-1 and
    /// made the local candidate a dead spinner on any foreign Wi-Fi, which is precisely where the
    /// candidate list most needs to reach its remote entry. At 2s the worst case is a brief stall.
    private let deadline: Duration

    private let peerLock = NSLock()
    private var _observedPeerAddress: String?

    /// The peer's resolved IP literal, observed once this connection reached `.ready`, or `nil` if
    /// it never did (or the path reported no address).
    ///
    /// **This is a security input, not diagnostics.** It is what
    /// `ConnectionClass.observed(peerAddress:)` classifies, and therefore what decides whether
    /// `get_config`'s URLs may be adopted — see that function, and
    /// `DiscoveredCandidateURLs.validating`. It reads the *socket*, not the URL we dialled, which
    /// is the whole point: a hostname (and, on a hostile network, DNS) cannot answer "is this on my
    /// LAN", but the address the kernel is sending bytes to can.
    ///
    /// Deliberately **not** on the `WebSocketConnection` protocol: `URLSessionWebSocketConnection`
    /// cannot answer it, and a protocol requirement returning `nil` from one conformance is an
    /// invitation to read `nil` as "local by default" somewhere. `AppModel` holds the concrete type
    /// for exactly as long as it needs this.
    public var observedPeerAddress: String? {
        peerLock.lock(); defer { peerLock.unlock() }
        return _observedPeerAddress
    }

    public init(url: URL, deadline: Duration = .seconds(2)) {
        self.deadline = deadline
        let isTLS = (url.scheme?.lowercased() == "wss")
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let tcpOptions = NWProtocolTCP.Options()
        // Belt-and-suspenders alongside the manual `withDeadline` race below: this bounds the
        // underlying TCP handshake itself, not just how long we're willing to wait for it.
        tcpOptions.connectionTimeout = max(1, Int(deadline.components.seconds))
        let params: NWParameters = isTLS ? NWParameters(tls: .init(), tcp: tcpOptions)
                                          : NWParameters(tls: nil, tcp: tcpOptions)
        params.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        // The URL endpoint carries the path (/api/websocket) and Host for the WS handshake.
        self.connection = NWConnection(to: .url(url), using: params)
    }

    public func connect() async throws {
        try await withDeadline {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let box = ContinuationBox(c)
                // `[weak self]` deliberately: the handler is owned by `connection`, which this
                // object owns, so a strong capture would be a retain cycle — and `AppModel`'s retry
                // loop creates one of these per candidate per round, unbounded. It can't be nil
                // here in practice (the caller holds `self` for the whole of this await), so
                // nothing is lost by asking.
                self.connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        // Recorded BEFORE resuming: the awaiting task goes on to authenticate and
                        // then read `observedPeerAddress` to decide whether this connection may be
                        // trusted, so it must not be able to observe the property still empty and
                        // conclude "address unavailable".
                        self?.recordPeerAddress()
                        box.resume(returning: ())
                    case .failed(let e):    box.resume(throwing: e)
                    case .waiting(let e):   box.resume(throwing: e)
                    case .cancelled:        box.resume(throwing: WSError(code: "cancelled", message: "connection cancelled"))
                    default:                break
                    }
                }
                self.connection.start(queue: self.queue)
            }
        }
    }

    /// Reads the peer address off the *current path* rather than off `connection.endpoint`. The
    /// latter is what we asked for (`http://homeassistant.local:8123`, a name); the former is what
    /// we got (`192.168.1.10`, or `::1`) — see `PeerEndpointAddress`.
    private func recordPeerAddress() {
        let address = PeerEndpointAddress.address(of: connection.currentPath?.remoteEndpoint)
        peerLock.lock(); _observedPeerAddress = address; peerLock.unlock()
    }

    /// Races `operation` against `deadline`. On timeout, cancels the underlying `NWConnection` —
    /// which resolves whatever continuation `operation` is still waiting on (via
    /// `stateUpdateHandler`/the `receiveMessage` completion, both of which fire on cancellation)
    /// so nothing is left leaked — and throws a clear timeout error instead of `operation`'s
    /// eventual (and by then irrelevant) result.
    private func withDeadline<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { [deadline, connection] in
                try await Task.sleep(for: deadline)
                connection.cancel()
                throw WSError(code: "timeout", message: "connection attempt timed out")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    public func send(_ data: Data) async throws {
        // Home Assistant expects JSON text frames.
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [metadata])
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(c)
            connection.send(content: data, contentContext: context, isComplete: true,
                            completion: .contentProcessed { error in
                if let error { box.resume(throwing: error) } else { box.resume(returning: ()) }
            })
        }
    }

    // NB: deliberately *not* wrapped in `withDeadline` — `receive()` is shared between the initial
    // auth handshake (`HAWebSocketClient.authenticate()`, which reads exactly two frames) and the
    // long-lived event loop (`HAWebSocketClient.startReceiveLoop()`), which must be able to block
    // indefinitely between sparse server-pushed frames on an otherwise perfectly healthy
    // connection. Bounding it here would spuriously tear down idle-but-fine sessions. The
    // TCP-connect hang this feature actually needs to guard against — an unreachable LAN address
    // — is caught by `connect()`'s deadline above; if a socket completes its TCP handshake but
    // then the far end never sends `auth_required`, that's a rarer, different failure mode this
    // change doesn't bound.
    public func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            let box = ContinuationBox(c)
            connection.receiveMessage { data, context, _, error in
                if let error { box.resume(throwing: error); return }
                if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                   meta.opcode == .close {
                    box.resume(throwing: WSError(code: "closed", message: "server closed connection"))
                    return
                }
                if let data { box.resume(returning: data) }
                else { box.resume(throwing: WSError(code: "closed", message: "no data")) }
            }
        }
    }

    public func close() { connection.cancel() }
}
