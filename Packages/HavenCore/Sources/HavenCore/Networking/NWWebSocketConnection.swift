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
    private let deadline: Duration

    public init(url: URL, deadline: Duration = .seconds(8)) {
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
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:            box.resume(returning: ())
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
