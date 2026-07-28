import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// A bulk action that half-fails currently reverts the failed rows and says nothing — the user
/// sees three of five lights flick back on with no explanation. The count is what the roll-up row
/// renders.
@Suite @MainActor struct BulkActionTests {
    private func store(lightsOn ids: [String]) -> HomeStore {
        let s = HomeStore()
        for id in ids {
            s.states[id] = EntityState(entityId: id, state: "on", attributes: [:],
                                       lastUpdated: Date(timeIntervalSince1970: 0))
        }
        return s
    }

    @Test func aFreshStoreReportsNoFailures() {
        #expect(store(lightsOn: []).bulkFailureCount(for: .lights, in: "living") == 0)
    }

    /// Recorded per room *and* kind, so a failed "All off" in one room does not put a count on
    /// another room's row of the same kind, and does not put a count on this room's Shades row.
    @Test func failuresAreRecordedPerRoomAndKind() {
        let s = store(lightsOn: [])
        s.recordBulkFailures(2, for: .lights, in: "living")
        #expect(s.bulkFailureCount(for: .lights, in: "living") == 2)
        #expect(s.bulkFailureCount(for: .covers, in: "living") == 0)
        #expect(s.bulkFailureCount(for: .lights, in: "kitchen") == 0)
    }

    /// A later successful run must clear the previous complaint, or the row keeps accusing the
    /// user of a failure that has since been fixed.
    @Test func recordingZeroClearsAPreviousFailure() {
        let s = store(lightsOn: [])
        s.recordBulkFailures(3, for: .lights, in: "living")
        s.recordBulkFailures(0, for: .lights, in: "living")
        #expect(s.bulkFailureCount(for: .lights, in: "living") == 0)
    }
}

/// **`runBulk` end to end**, against a real `HAWebSocketClient` and a scripted socket — the three
/// tests review found missing from the brief. Nothing above exercises the bound, the tallying, the
/// up-front flip or the per-entity rollback; these do, by actually running `allOff` over a fake
/// Home Assistant that can be told which entities to fail and how many `call_service` calls are
/// outstanding at once.
@Suite @MainActor struct BulkActionRunTests {
    /// Answers `call_service` with success or failure per entity id, and counts how many
    /// `call_service` requests are sent but not yet answered — the number `runBulk`'s batching is
    /// supposed to cap at `bulkConcurrency` (6).
    ///
    /// The count only means anything because responses are deliberately delayed: without the
    /// sleep, a response could be enqueued before every concurrent sender in a batch has even
    /// reached `send`, and `maxOutstanding` would under-report.
    private actor ScriptedBulkSocket: WebSocketConnection {
        private var incoming: [Data] = []
        private var waiters: [CheckedContinuation<Data, Error>] = []
        private let failing: Set<String>
        /// Answered so far — what tests poll on. Deliberately *not* incremented until the response
        /// is actually enqueued: incrementing at `send`-time would let a test proceed the instant
        /// every request has been fired, before any of them has been answered, resolved by the
        /// client's receive loop, or acted on by `runBulk` — i.e. before there is anything to
        /// assert about.
        private(set) var answered = 0
        private(set) var maxOutstanding = 0
        private var outstanding = 0

        init(failing: Set<String> = []) { self.failing = failing }

        func connect() async throws {}
        nonisolated func close() {}

        /// **The latency is in the response, not in the write** — and this fake used to put it in
        /// the write, which measured the wrong thing.
        ///
        /// A real `send` completes when Network.framework has taken the frame, in microseconds; it
        /// does not wait for Home Assistant. Sleeping inside `send` therefore modelled a socket
        /// nobody has, and `maxOutstanding` counted *concurrent writes* rather than concurrent
        /// in-flight commands. That distinction did not matter until `HAWebSocketClient` began
        /// serialising its writes to keep command ids in increasing order — at which point this
        /// test failed, reporting a peak of 1, while the thing it exists to check (that a bulk
        /// action overlaps its round trips, six at a time) was entirely unaffected.
        ///
        /// So the reply is now scheduled off the send path. `outstanding` spans send → reply,
        /// which is what "outstanding command" means.
        func send(_ data: Data) async throws {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? Int, let type = obj["type"] as? String,
                  type == "call_service" else { return }
            outstanding += 1
            maxOutstanding = max(maxOutstanding, outstanding)
            let entityId = ((obj["target"] as? [String: Any])?["entity_id"] as? String) ?? ""
            Task { [weak self] in
                // Long enough that every task in a 6-wide batch has certainly reached `send`
                // before any of them gets its answer back, so `maxOutstanding` reflects real
                // overlap rather than however fast this fake happens to run.
                try? await Task.sleep(for: .milliseconds(30))
                await self?.reply(id: id, entityId: entityId)
            }
        }

        private func reply(id: Int, entityId: String) {
            outstanding -= 1
            if failing.contains(entityId) {
                enqueue(#"{"id":\#(id),"type":"result","success":false,"error":{"code":"unknown_error","message":"nope"}}"#)
            } else {
                enqueue(#"{"id":\#(id),"type":"result","success":true,"result":null}"#)
            }
            answered += 1
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

    /// Authenticates a client against `socket` and attaches it to a fresh `HomeStore` — no
    /// `bootstrap()`, since these tests only need `allOff`/`closeAll` and drive `states` directly.
    private func makeStore(failing: Set<String> = []) async throws -> (HomeStore, ScriptedBulkSocket) {
        let socket = ScriptedBulkSocket(failing: failing)
        await socket.enqueue(#"{"type":"auth_required"}"#)
        await socket.enqueue(#"{"type":"auth_ok"}"#)
        let client = HAWebSocketClient(connection: socket)
        try await client.authenticate(token: "t")
        let store = HomeStore()
        store.attach(HomeConnection(client: client))
        return (store, socket)
    }

    private func lightsOn(_ ids: [String], in store: HomeStore) -> Rollup {
        for id in ids {
            store.states[id] = EntityState(entityId: id, state: "on", attributes: [:],
                                           lastUpdated: Date(timeIntervalSince1970: 0))
        }
        return RoomRollups.compute(entityIds: ids, states: store.states).first { $0.kind == .lights }!
    }

    /// Polls until the socket has answered every expected `call_service` frame, rather than
    /// sleeping a fixed guess — `runBulk` awaits a batch of network round-trips (each with its own
    /// scripted delay) before starting the next, so a fixed sleep would either be flaky under load
    /// or need to be generously long for no reason.
    ///
    /// A short grace sleep follows: `answered` flips the instant the socket enqueues its last
    /// response, which still has to cross back through the client's receive loop, resolve the
    /// waiting continuation, and let `runBulk`'s `@MainActor` task record the tally and (on
    /// failure) roll the entity back — all real `await`s this function must not race.
    private func waitForCommands(_ expected: Int, on socket: ScriptedBulkSocket) async {
        for _ in 0..<200 {
            if await socket.answered >= expected { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// The Critical this round of review pinned: a failure tallied in one room must not appear on
    /// another room's roll-up of the same kind. Two of five lights are scripted to fail.
    @Test func failuresAreScopedToTheRoomThatRanTheAction() async throws {
        let ids = ["light.a", "light.b", "light.c", "light.d", "light.e"]
        let (store, socket) = try await makeStore(failing: ["light.a", "light.b"])
        let rollup = lightsOn(ids, in: store)

        store.allOff(rollup, in: "kitchen")
        await waitForCommands(ids.count, on: socket)

        #expect(store.bulkFailureCount(for: .lights, in: "kitchen") == 2)
        #expect(store.bulkFailureCount(for: .lights, in: "living") == 0)
    }

    /// The property the brief itself names as the one that must survive: one entity's failure must
    /// never revert another. After the run, the three that succeeded read "off" and exactly the
    /// two scripted to fail reverted to "on".
    ///
    /// Also pins fix #2 directly, which the final-state assertions alone cannot: a flip that
    /// happened late, inside the batched command work, and one that happened up front and
    /// synchronously would settle on identical final states, so a regression that moved the flip
    /// back into `work` would still pass a check that only looks after everything has finished.
    /// `allOff` is `@MainActor` and this suite is `@MainActor`, so nothing else can run on
    /// MainActor between the call returning and the next `await` — the flip is either done by
    /// then or it never happens synchronously at all.
    @Test func onlyTheFailedEntitiesRevert() async throws {
        let ids = ["light.a", "light.b", "light.c", "light.d", "light.e"]
        let (store, socket) = try await makeStore(failing: ["light.a", "light.b"])
        let rollup = lightsOn(ids, in: store)

        store.allOff(rollup, in: "kitchen")
        // Every target is already flipped to "off" synchronously, before any network round-trip
        // has even had a chance to run — the whole point of fix #2.
        for id in ids { #expect(store.states[id]?.state == "off") }

        await waitForCommands(ids.count, on: socket)

        #expect(store.states["light.a"]?.state == "on")
        #expect(store.states["light.b"]?.state == "on")
        #expect(store.states["light.c"]?.state == "off")
        #expect(store.states["light.d"]?.state == "off")
        #expect(store.states["light.e"]?.state == "off")
    }

    /// The one assertion that would catch a future "tidy" removing the bound: 13 targets is more
    /// than two full waves of 6, and at no point may more than 6 `call_service` calls be
    /// outstanding at once.
    @Test func atMostBulkConcurrencyCommandsAreOutstandingAtOnce() async throws {
        let ids = (1...13).map { "light.l\($0)" }
        let (store, socket) = try await makeStore()
        let rollup = lightsOn(ids, in: store)

        store.allOff(rollup, in: "kitchen")
        await waitForCommands(ids.count, on: socket)

        let peak = await socket.maxOutstanding
        #expect(peak <= 6)
        #expect(peak >= 2)   // sanity: genuinely overlapping, not accidentally serialized to 1
    }

    /// Round-2 review finding: the rollback guard has to compare the *whole* `EntityState` the
    /// flip wrote, not just its `state` string. `light.a` is scripted to fail; while its command is
    /// still in flight (the socket delays every response by 30ms) a fresh push lands reporting it
    /// as `"off"` — the same string the flip wrote, but with new attributes and a new
    /// `lastUpdated`, standing in for a real device-driven change or a WebSocket `state_changed`
    /// event. A `state`-only guard would call that a match and, when the command then fails,
    /// overwrite the pushed reading with the stale tap-time snapshot (`state: "on"`, plus its own
    /// stale attributes/`lastUpdated`) — exactly the regression review caught. The whole-entity
    /// guard must see they differ and leave the pushed value alone.
    @Test func aPushThatArrivesMidFlightSurvivesAFailedCommand() async throws {
        let id = "light.a"
        let (store, socket) = try await makeStore(failing: [id])
        let rollup = lightsOn([id], in: store)

        store.allOff(rollup, in: "kitchen")
        // The flip already wrote state "off" with the epoch-zero `lastUpdated` from `lightsOn`.
        // This lands well before the scripted 30ms response delay, so it is unambiguously
        // "during" the in-flight command, not after it resolved.
        try await Task.sleep(for: .milliseconds(10))
        let pushed = EntityState(entityId: id, state: "off",
                                 attributes: ["source": .string("push")], lastUpdated: Date())
        store.states[id] = pushed

        await waitForCommands(1, on: socket)

        // Rollback did not fire: the pushed value — not the tap-time "on" snapshot — is what
        // survives the failed command.
        #expect(store.states[id] == pushed)
    }

    /// `closeAll`'s own parameters, now that they are the only thing distinguishing it from
    /// `allOff`.
    ///
    /// Every test above drives `allOff`, and `closeAll` used to be a second hand-written copy of
    /// the same body — so the shared machinery (bounded batches, per-room tallies, whole-entity
    /// rollback) was verified on one copy and merely assumed on the other. Both now run through
    /// `bulkFlip`, which means those tests net this path too, and what is left uncovered is exactly
    /// the four arguments `closeAll` passes in. This pins the two that can be silently wrong:
    /// which covers are targets, and what they are flipped to.
    ///
    /// The predicate is an allow-list (`open` or `opening`), and the room deliberately contains
    /// three covers that a deny-list would get wrong. `Rollup.targetEntityIds` for covers is
    /// **every** cover in the room, not just the open ones (see `RoomRollups.compute`, which uses
    /// the open subset for the *count* and the full list for the targets), so this predicate is the
    /// only thing standing between "close all" and a command sent to every shade in the room.
    ///
    /// - `closing` — already going the right way; commanding it again is noise.
    /// - `unavailable` — the state this codebase keeps having to defend against. Note that
    ///   `bulkFlip` has **no explicit unavailable guard** of the kind `fireAndForget` and
    ///   `optimisticState` carry: an unreachable cover is excluded here only because the string
    ///   `"unavailable"` is neither `"open"` nor `"opening"`. That is correct but incidental, and
    ///   the same is true of `allOff` (`state == "on"`). A predicate rewritten as a deny-list
    ///   would silently lose that protection along with the rest.
    ///
    /// A `!= "closed"` predicate — the obvious "simplification" — passes a room of only open and
    /// closed covers and fails here, on all three.
    @Test func closeAllTargetsOpenAndOpeningCoversOnly() async throws {
        let (store, socket) = try await makeStore()
        let states = ["cover.a": "open", "cover.b": "opening", "cover.c": "closed",
                      "cover.d": "closing", "cover.e": "unavailable"]
        for (id, state) in states {
            store.states[id] = EntityState(entityId: id, state: state, attributes: [:],
                                           lastUpdated: Date(timeIntervalSince1970: 0))
        }
        let rollup = RoomRollups.compute(entityIds: states.keys.sorted(), states: store.states)
            .first { $0.kind == .covers }!
        // Guards the premise: if this ever became the open-only subset, every assertion below
        // would still pass while testing nothing.
        #expect(rollup.targetEntityIds.count == 5)

        store.closeAll(rollup, in: "kitchen")

        // Synchronous, up-front flip — the same property `onlyTheFailedEntitiesRevert` pins for
        // `allOff`, and asserted before any `await` for the same reason.
        #expect(store.states["cover.a"]?.state == "closed")
        #expect(store.states["cover.b"]?.state == "closed")
        // Untouched: not flipped, and — asserted on the wire below — not commanded either.
        #expect(store.states["cover.c"]?.state == "closed")
        #expect(store.states["cover.d"]?.state == "closing")
        #expect(store.states["cover.e"]?.state == "unavailable")

        await waitForCommands(2, on: socket)

        #expect(await socket.answered == 2)
        #expect(store.bulkFailureCount(for: .covers, in: "kitchen") == 0)
    }
}
