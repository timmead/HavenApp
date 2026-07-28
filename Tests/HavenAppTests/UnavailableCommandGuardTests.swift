import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// `HomeStore.toggleLock`/`openCloseCover` against an `unavailable` vs an `unknown` entity.
///
/// The bug this pins: Home Assistant does not throw `call_service` for an entity it cannot reach
/// — the integration fails quietly — and an `unavailable` entity pushes no state update to correct
/// a wrong guess either. So a guard keyed on `EntityState.isUnavailable` catching the optimistic
/// write but not the command (or vice versa) would still leave a false claim standing, or would
/// needlessly refuse a device that can still be commanded. Both `toggleLock` and `openCloseCover`
/// must, for `unavailable`: change no local state *and* send no command. For `unknown` — reachable,
/// simply unreported — both must still act normally, since a tap is the one thing that might
/// resolve the unknown.
@Suite @MainActor struct UnavailableCommandGuardTests {
    /// Records every `call_service` frame sent and answers each one successfully. Asserting the
    /// frame count directly (not just the resulting `states` entry) matters here specifically: a
    /// guard that skips the optimistic write but still fires the command would pass a state-only
    /// test while still bothering an unreachable device with a command nobody asked to send.
    private actor ScriptedCommandSocket: WebSocketConnection {
        private var incoming: [Data] = []
        private var waiters: [CheckedContinuation<Data, Error>] = []
        private(set) var callServiceFrames: [[String: Any]] = []

        func connect() async throws {}
        nonisolated func close() {}

        func send(_ data: Data) async throws {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? Int, let type = obj["type"] as? String else { return }
            if type == "call_service" { callServiceFrames.append(obj) }
            enqueue(#"{"id":\#(id),"type":"result","success":true,"result":null}"#)
        }

        func receive() async throws -> Data {
            if !incoming.isEmpty { return incoming.removeFirst() }
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }

        func enqueue(_ text: String) {
            let data = Data(text.utf8)
            if !waiters.isEmpty { waiters.removeFirst().resume(returning: data) } else { incoming.append(data) }
        }

        var commandCount: Int { callServiceFrames.count }
    }

    /// Authenticates a client against a fresh scripted socket and attaches it to a fresh
    /// `HomeStore` — no `bootstrap()`, mirroring `BulkActionRunTests`: these tests only need
    /// `toggleLock`/`openCloseCover` and drive `states` directly.
    private func makeStore() async throws -> (HomeStore, ScriptedCommandSocket) {
        let socket = ScriptedCommandSocket()
        await socket.enqueue(#"{"type":"auth_required"}"#)
        await socket.enqueue(#"{"type":"auth_ok"}"#)
        let client = HAWebSocketClient(connection: socket)
        try await client.authenticate(token: "t")
        let store = HomeStore()
        store.attach(HomeConnection(client: client))
        return (store, socket)
    }

    private func set(_ store: HomeStore, _ id: String, _ state: String) {
        store.states[id] = EntityState(entityId: id, state: state, attributes: [:],
                                       lastUpdated: Date(timeIntervalSince1970: 0))
    }

    // MARK: - toggleLock

    @Test func anUnavailableLockTapChangesNoStateAndSendsNoCommand() async throws {
        let (store, socket) = try await makeStore()
        set(store, "lock.front", "unavailable")

        store.toggleLock("lock.front")
        // Give any (incorrectly) fired Task a chance to run before asserting nothing happened.
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.states["lock.front"]?.state == "unavailable")
        #expect(await socket.commandCount == 0)
    }

    @Test func anUnknownLockTapStillLocksItAndSendsTheCommand() async throws {
        let (store, socket) = try await makeStore()
        set(store, "lock.front", "unknown")

        store.toggleLock("lock.front")
        // The optimistic flip happens synchronously, before any network round-trip.
        #expect(store.states["lock.front"]?.state == "locked")

        try await Task.sleep(for: .milliseconds(50))
        #expect(await socket.commandCount == 1)
    }

    // MARK: - openCloseCover

    @Test func anUnavailableCoverTapChangesNoStateAndSendsNoCommand() async throws {
        let (store, socket) = try await makeStore()
        set(store, "cover.blinds", "unavailable")

        store.openCloseCover("cover.blinds")
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.states["cover.blinds"]?.state == "unavailable")
        #expect(await socket.commandCount == 0)
    }

    @Test func anUnknownCoverTapStillOpensItAndSendsTheCommand() async throws {
        let (store, socket) = try await makeStore()
        set(store, "cover.blinds", "unknown")

        store.openCloseCover("cover.blinds")
        #expect(store.states["cover.blinds"]?.state == "open")

        try await Task.sleep(for: .milliseconds(50))
        #expect(await socket.commandCount == 1)
    }
}
