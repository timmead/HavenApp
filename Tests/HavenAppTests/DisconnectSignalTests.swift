import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// **`onDisconnected` must mean the socket died, and nothing else.**
///
/// `AppModel` wires that callback to a full reconnect, which cancels whatever connect loop is
/// currently running and starts a new one. So a spurious fire does not merely waste work — it
/// aborts an attempt that may have been about to succeed and sends the app back to the start,
/// which from the outside looks exactly like "connecting takes a few tries".
///
/// The subscription task ends for three different reasons and only one of them is a disconnection:
/// the stream finished because the socket's receive loop ended (real), `reset()` tore it down
/// (deliberate, and guarded by `isResetting`), or the task was cancelled by `attach()` replacing it
/// (also deliberate, and guarded by nothing at all until these tests).
@Suite @MainActor struct DisconnectSignalTests {
    /// Speaks enough of the protocol for `bootstrap()` to complete, then parks so the subscription
    /// stays open — the state a live session is actually in.
    private actor BootstrapSocket: WebSocketConnection {
        private var incoming: [Data] = []
        private var waiters: [CheckedContinuation<Data, Error>] = []

        func connect() async throws {}
        nonisolated func close() {}

        func send(_ data: Data) async throws {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { return }
            if type == "auth" { enqueue(#"{"type":"auth_ok"}"#); return }
            guard let id = obj["id"] as? Int else { return }
            switch type {
            case "config/floor_registry/list", "config/area_registry/list",
                 "config/device_registry/list", "config/entity_registry/list", "get_states":
                enqueue(#"{"id":\#(id),"type":"result","success":true,"result":[]}"#)
            case "subscribe_events":
                enqueue(#"{"id":\#(id),"type":"result","success":true,"result":null}"#)
            default:
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
        let socket = BootstrapSocket()
        await socket.enqueue(#"{"type":"auth_required"}"#)
        let client = HAWebSocketClient(connection: socket)
        try await client.authenticate(token: "t")
        return HomeConnection(client: client)
    }

    /// A live store, bootstrapped, with its subscription running.
    private func liveStore() async throws -> HomeStore {
        let store = HomeStore()
        store.attach(try await connection())
        try await store.bootstrap()
        return store
    }

    /// **Re-attaching must not look like a disconnection.**
    ///
    /// `attemptCandidate` calls `attach` on every candidate it tries, and `attach` cancels whatever
    /// subscription was running. If that cancellation reports itself as a dropped socket, the
    /// reconnect it triggers cancels the very connect loop that is mid-attempt.
    @Test func replacingTheConnectionDoesNotReportADisconnection() async throws {
        let store = try await liveStore()
        var fired = false
        store.onDisconnected = { fired = true }

        store.attach(try await connection())
        // Generously longer than the cancelled task needs to be scheduled and run to completion.
        try await Task.sleep(for: .milliseconds(200))

        #expect(!fired, "replacing the connection was reported as the socket dropping")
    }

    /// The same for a deliberate teardown. `reset()` guards this with `isResetting`, but that guard
    /// depends on the cancelled task resuming *before* `reset()` finishes — so it is worth an
    /// assertion rather than an argument.
    @Test func resettingDoesNotReportADisconnection() async throws {
        let store = try await liveStore()
        var fired = false
        store.onDisconnected = { fired = true }

        await store.reset()
        try await Task.sleep(for: .milliseconds(200))

        #expect(!fired, "tearing the session down deliberately was reported as the socket dropping")
    }

    /// The positive case, without which the two above could be satisfied by never firing at all —
    /// which would break the reconnect this callback exists to drive. The socket's receive loop
    /// ending is a genuine drop and must be reported.
    @Test func aSocketThatActuallyDiesDoesReportADisconnection() async throws {
        let store = HomeStore()
        let socket = BootstrapSocket()
        await socket.enqueue(#"{"type":"auth_required"}"#)
        let client = HAWebSocketClient(connection: socket)
        try await client.authenticate(token: "t")
        store.attach(HomeConnection(client: client))
        try await store.bootstrap()

        var fired = false
        store.onDisconnected = { fired = true }

        // Ending the client's receive loop is what a dropped socket looks like from up here.
        await client.disconnect()
        try await Task.sleep(for: .milliseconds(200))

        #expect(fired, "a genuinely dropped socket must still trigger the reconnect")
    }
}
