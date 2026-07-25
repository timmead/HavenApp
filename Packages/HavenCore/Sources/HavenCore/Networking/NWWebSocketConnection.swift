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

    public init(url: URL) {
        let isTLS = (url.scheme?.lowercased() == "wss")
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let params: NWParameters = isTLS ? .tls : .tcp
        params.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        // The URL endpoint carries the path (/api/websocket) and Host for the WS handshake.
        self.connection = NWConnection(to: .url(url), using: params)
    }

    public func connect() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(c)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:            box.resume(returning: ())
                case .failed(let e):    box.resume(throwing: e)
                case .waiting(let e):   box.resume(throwing: e)
                case .cancelled:        box.resume(throwing: WSError(code: "cancelled", message: "connection cancelled"))
                default:                break
                }
            }
            connection.start(queue: queue)
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
