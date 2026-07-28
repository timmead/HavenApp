import Foundation
import Network

/// One-shot, thread-safe wrapper so a `CheckedContinuation` can be captured in
/// Network.framework's `@Sendable` callbacks without risk of double-resume — **and** so task
/// cancellation can resolve that continuation in a race with a real result.
///
/// The box is created *before* the continuation exists, because `withTaskCancellationHandler`'s
/// `onCancel` can fire before (or during) the `withCheckedThrowingContinuation` body — including
/// immediately, when the calling task is already cancelled on entry. So cancellation that arrives
/// early is remembered and honoured by `install`.
///
/// **The invariant that matters:** every path through `install` either stores the continuation or
/// resumes it — never neither. Returning without doing one of the two is precisely the hang this
/// class exists to prevent, which is why the (unreachable) double-install case resumes with an
/// error rather than trapping: a crash in Debug for a case argued impossible is worse than a
/// diagnosis, and a silent drop is worse than both.
private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private enum State {
        case awaitingInstall                            // created, continuation not yet handed over
        case waiting(CheckedContinuation<T, Error>)     // live, resumable exactly once
        case cancelledBeforeInstall                     // onCancel won the race to get here first
        case done                                       // resumed; every later call is a no-op
    }
    private var state: State = .awaitingInstall
    private let lock = NSLock()

    /// Hands the continuation to the box. Called synchronously inside the
    /// `withCheckedThrowingContinuation` body, before any callback that could resume it is
    /// registered.
    func install(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        switch state {
        case .awaitingInstall:
            state = .waiting(c)
            lock.unlock()
        case .cancelledBeforeInstall:
            state = .done
            lock.unlock()
            c.resume(throwing: CancellationError())
        case .waiting, .done:
            lock.unlock()
            c.resume(throwing: WSError(code: "internal", message: "continuation installed twice"))
        }
    }

    func resume(returning value: T) { take()?.resume(returning: value) }
    func resume(throwing error: Error) { take()?.resume(throwing: error) }

    /// Resolves the continuation with `CancellationError` if it is still outstanding; if it hasn't
    /// been installed yet, records the cancellation so `install` resolves it the moment it arrives.
    func cancel() {
        lock.lock()
        switch state {
        case .awaitingInstall:
            state = .cancelledBeforeInstall
            lock.unlock()
        case .waiting(let c):
            state = .done
            lock.unlock()
            c.resume(throwing: CancellationError())
        case .cancelledBeforeInstall, .done:
            lock.unlock()
        }
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock(); defer { lock.unlock() }
        guard case .waiting(let c) = state else { return nil }
        state = .done
        return c
    }
}

/// A `WebSocketConnection` backed by `Network.framework` (`NWConnection`) rather than
/// `URLSessionWebSocketTask`. This avoids the iOS Simulator's `URLSession` WebSocket
/// breakage and talks to the socket directly, which is what Home Assistant expects.
@available(iOS 13, macOS 10.15, *)
public final class NWWebSocketConnection: PeerObservableConnection, @unchecked Sendable {
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
            let box = ContinuationBox<Void>()
            // The handler is *inside* `withDeadline`'s operation closure so it covers both ways
            // this can be cancelled: the caller's own task being cancelled (which propagates into
            // the task group's children), and `withDeadline`'s `group.cancelAll()`. It is not
            // reached on the success path — once the operation returns, the handler is uninstalled,
            // so the `defer { group.cancelAll() }` that follows a *successful* connect cannot
            // cancel the socket it just established.
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    box.install(c)
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
            } onCancel: {
                // A half-established socket nobody is waiting on any more is a leak: the only
                // callers that cancel a connect are tearing this connection down (`AppModel`'s
                // candidate loop, `HAWebSocketClient.disconnect`), and none of them go on to use it.
                self.connection.cancel()
                box.cancel()
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
        let box = ContinuationBox<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                box.install(c)
                connection.send(content: data, contentContext: context, isComplete: true,
                                completion: .contentProcessed { error in
                    if let error { box.resume(throwing: error) } else { box.resume(returning: ()) }
                })
            }
        } onCancel: {
            // Unlike `connect()`/`receive()`, this deliberately does **not** cancel the connection.
            // A frame handed to Network.framework may already be on the wire — cancelling the
            // awaiting task cannot un-send it — and the one caller that gets cancelled mid-send is
            // the auth handshake, whose own caller closes the socket itself. Killing an otherwise
            // healthy connection because a sender lost interest would be the larger harm.
            box.cancel()
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
    //
    // Being unbounded makes cancellation the *only* way out of this call short of the socket
    // resolving it, which is why it is honoured here rather than left to the close: before this,
    // `HAWebSocketClient.disconnect()` cancelling its receive loop did nothing until the socket
    // close happened to complete the outstanding `receiveMessage`, so a torn-down connection kept
    // a task parked in here. Harmless when there was only ever one socket; not now that
    // reconnection is routine and each round leaves another one behind.
    public func receive() async throws -> Data {
        let box = ContinuationBox<Data>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                box.install(c)
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
        } onCancel: {
            // Cancelling a read means abandoning the frame Network.framework may be about to hand
            // us, so the socket must not be left readable by anyone else: every caller that cancels
            // a receive (the client's receive loop, the auth handshake) is tearing this connection
            // down and closes it a moment later anyway. Doing it here makes "cancelled" and "closed"
            // the same thing rather than two states one frame apart.
            self.connection.cancel()
            box.cancel()
        }
    }

    public func close() { connection.cancel() }
}
