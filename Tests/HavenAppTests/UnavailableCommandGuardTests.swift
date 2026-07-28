import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// `HomeStore.toggleLock`/`openCloseCover`/`toggle` against an `unavailable` vs an `unknown` entity.
///
/// The bug this pins: Home Assistant does not throw `call_service` for an entity it cannot reach
/// — the integration fails quietly — and an `unavailable` entity pushes no state update to correct
/// a wrong guess either. So a guard keyed on `EntityState.isUnavailable` catching the optimistic
/// write but not the command (or vice versa) would still leave a false claim standing, or would
/// needlessly refuse a device that can still be commanded. `toggleLock`, `openCloseCover`, and now
/// `toggle` (via the `optimistic(_:on:_:)` primitive it delegates to, shared by lights, switches,
/// and input booleans) must, for `unavailable`: change no local state *and* send no command. For
/// `unknown` — reachable, simply unreported — all three must still act normally, since a tap is the
/// one thing that might resolve the unknown.
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

    // MARK: - toggle (light) — the `optimistic(_:on:_:)` primitive

    /// This is the defect the user actually hit: `optimistic(_:on:_:)` used to write
    /// `states[id].state = "on"`/`"off"` unconditionally, so tapping an unreachable light made
    /// `isUnavailable` read `false` and the tile render as a working, switched-on device — while
    /// still sending the command to a device that cannot act on it.
    @Test func anUnavailableLightTapChangesNoStateAndSendsNoCommand() async throws {
        let (store, socket) = try await makeStore()
        set(store, "light.kitchen", "unavailable")

        store.toggle("light.kitchen")
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.states["light.kitchen"]?.state == "unavailable")
        #expect(await socket.commandCount == 0)
    }

    @Test func anUnknownLightTapStillTurnsItOnAndSendsTheCommand() async throws {
        let (store, socket) = try await makeStore()
        set(store, "light.kitchen", "unknown")

        store.toggle("light.kitchen")
        // The optimistic flip happens synchronously, before any network round-trip.
        #expect(store.states["light.kitchen"]?.state == "on")

        try await Task.sleep(for: .milliseconds(50))
        #expect(await socket.commandCount == 1)
    }

    // MARK: - The fire-and-forget group

    /// One command that writes no optimistic state and only has to be *withheld* from an
    /// unreachable entity.
    private struct FireAndForget {
        let name: String
        let entityId: String
        let send: @MainActor (HomeStore) -> Void
    }

    /// Every fire-and-forget command on `HomeStore`, as of this commit.
    ///
    /// The three tests above cover the commands that also write optimistic state; these ten were
    /// covered by nothing. Each carried its own hand-written copy of the same
    /// `guard let connection, states[id]?.state != "unavailable" else { return }` line, which is
    /// ten independent chances to write the eleventh without it — and the one defect of this exact
    /// shape that did ship (`optimistic(_:on:_:)`, pinned above) reached a user. Listed as a table
    /// rather than twenty near-identical test functions so that adding a command and forgetting to
    /// cover it is a one-line omission in an obvious place.
    private var fireAndForgetCommands: [FireAndForget] {
        [
            .init(name: "run", entityId: "scene.movie") { $0.run("scene.movie") },
            .init(name: "setColorTemp", entityId: "light.kitchen") { $0.setColorTemp("light.kitchen", kelvin: 3000) },
            .init(name: "setClimateMode", entityId: "climate.hall") { $0.setClimateMode("climate.hall", mode: "heat") },
            .init(name: "setClimateTemp", entityId: "climate.hall") { $0.setClimateTemp("climate.hall", temp: 21) },
            .init(name: "setFanMode", entityId: "climate.hall") { $0.setFanMode("climate.hall", mode: "auto") },
            .init(name: "openCover", entityId: "cover.blinds") { $0.openCover("cover.blinds") },
            .init(name: "stopCover", entityId: "cover.blinds") { $0.stopCover("cover.blinds") },
            .init(name: "closeCover", entityId: "cover.blinds") { $0.closeCover("cover.blinds") },
            .init(name: "mediaNextTrack", entityId: "media_player.tv") { $0.mediaNextTrack("media_player.tv") },
            .init(name: "mediaPreviousTrack", entityId: "media_player.tv") { $0.mediaPreviousTrack("media_player.tv") },
        ]
    }

    /// Nothing goes out to a device Home Assistant cannot reach.
    ///
    /// Asserted on the frames actually sent, not on `states`: these commands write no optimistic
    /// state at all, so a missing guard leaves `states` untouched and looking perfectly correct
    /// while the command still goes out. The wire is the only place the bug is visible.
    @Test func noFireAndForgetCommandReachesAnUnavailableEntity() async throws {
        for command in fireAndForgetCommands {
            let (store, socket) = try await makeStore()
            set(store, command.entityId, "unavailable")

            command.send(store)
            // Give any (incorrectly) fired Task a chance to run before asserting nothing happened.
            try await Task.sleep(for: .milliseconds(50))

            #expect(await socket.commandCount == 0,
                    "\(command.name) sent a command to an unavailable entity")
            #expect(store.states[command.entityId]?.state == "unavailable",
                    "\(command.name) changed the state of an unavailable entity")
        }
    }

    /// …and `unknown` is still commanded, for the reason the guards are keyed on the `state` string
    /// rather than on `EntityState.isUnavailable`: an `unknown` entity is reachable and has simply
    /// not reported, so the command is the one thing that might resolve it. A guard widened to
    /// `isUnavailable` would pass the test above and fail this one.
    @Test func everyFireAndForgetCommandStillReachesAnUnknownEntity() async throws {
        for command in fireAndForgetCommands {
            let (store, socket) = try await makeStore()
            set(store, command.entityId, "unknown")

            command.send(store)
            try await Task.sleep(for: .milliseconds(50))

            #expect(await socket.commandCount == 1,
                    "\(command.name) refused an unknown — but reachable — entity")
        }
    }
}
