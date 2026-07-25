import Foundation

public protocol WebSocketConnection: Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
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
