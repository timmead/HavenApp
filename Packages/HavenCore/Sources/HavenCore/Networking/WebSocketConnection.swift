import Foundation

public protocol WebSocketConnection: Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

/// A connection that can report the address the kernel is actually sending bytes to.
///
/// Split out from `WebSocketConnection` rather than added to it because it is the input to a
/// *security* decision, not a transport capability: `ConnectionClass.observed` uses this — and
/// nothing derived from the URL, its hostname, or DNS — to decide whether a self-reported address
/// may be persisted as a future candidate that a refresh token will later be POSTed to. A
/// hostname cannot answer "is this on my LAN", and on a hostile network neither can the resolver.
///
/// **The default is `nil`, and that is the whole point.** An implementation that cannot observe
/// its peer — or whose author did not think about it — reports "unknown", which
/// `ConnectionClass.observed` treats as `.remote`, which adopts nothing. The two mistakes cost
/// wildly different amounts, so the one you get for free is the safe one. A conformer must go out
/// of its way to claim it knows where its bytes are going.
public protocol PeerObservableConnection: WebSocketConnection {
    var observedPeerAddress: String? { get }
}

public extension PeerObservableConnection {
    var observedPeerAddress: String? { nil }
}

@available(iOS 13, macOS 10.15, *)
public final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let url: URL
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    public init(url: URL, session: URLSession? = nil) {
        self.url = url
        if let session {
            self.session = session
        } else {
            // The iOS Simulator's URLSession has known networking bugs where protocol/HTTP3
            // state cached between app runs breaks later connections. An *ephemeral* session
            // avoids that cached state — the documented workaround (Apple DTS thread 777999).
            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = true
            config.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: config)
        }
        var request = URLRequest(url: url)
        #if targetEnvironment(simulator)
        // HTTP/3 negotiation is broken in the Simulator; force it off there.
        request.assumesHTTP3Capable = false
        #endif
        self.task = self.session.webSocketTask(with: request)
    }
    public func connect() async throws { task.resume() }
    public func send(_ data: Data) async throws { try await task.send(.data(data)) }
    public func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let d): return d
        case .string(let s): return Data(s.utf8)
        @unknown default: return Data()
        }
    }
    public func close() { task.cancel(with: .goingAway, reason: nil) }
}
