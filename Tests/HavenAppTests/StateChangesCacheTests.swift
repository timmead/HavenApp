import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// `HomeStore.loadStateChanges`/`stateChanges`/`stateChangesLoadFailed`, against a real
/// `HAWebSocketClient` and a scripted socket — the cache this branch gave a `fetched` timestamp
/// and expiry (fix #2, matching `historyByKey`), and the failure tracking that lets the
/// binary-sensor modal tell "not asked yet" apart from "asked, and it failed" (fix #3).
@Suite @MainActor struct StateChangesCacheTests {
    /// Answers every `history/history_during_period` request with either a (possibly empty)
    /// success or a scripted failure, and counts how many were sent.
    private actor ScriptedHistorySocket: WebSocketConnection {
        private var incoming: [Data] = []
        private var waiters: [CheckedContinuation<Data, Error>] = []
        private var succeed: Bool
        private(set) var requestCount = 0

        init(succeed: Bool) { self.succeed = succeed }

        func connect() async throws {}
        nonisolated func close() {}

        func setSucceed(_ v: Bool) { succeed = v }

        func send(_ data: Data) async throws {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? Int, let type = obj["type"] as? String,
                  type == "history/history_during_period" else { return }
            requestCount += 1
            if succeed {
                enqueue(#"{"id":\#(id),"type":"result","success":true,"result":{}}"#)
            } else {
                enqueue(#"{"id":\#(id),"type":"result","success":false,"error":{"code":"unknown_error","message":"nope"}}"#)
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

    private func makeStore(succeed: Bool) async throws -> (HomeStore, ScriptedHistorySocket) {
        let socket = ScriptedHistorySocket(succeed: succeed)
        await socket.enqueue(#"{"type":"auth_required"}"#)
        await socket.enqueue(#"{"type":"auth_ok"}"#)
        let client = HAWebSocketClient(connection: socket)
        try await client.authenticate(token: "t")
        let store = HomeStore()
        store.attach(HomeConnection(client: client))
        return (store, socket)
    }

    /// The state before fix #3: `nil` covered both "never asked" and "asked and it threw", so an
    /// install without the `history` integration (or an entity `recorder` excludes) showed
    /// "Loading…" forever. Now a failure with nothing cached is reported distinctly.
    @Test func aFailedFetchWithNothingCachedIsReportedDistinctlyFromNotAskedYet() async throws {
        let (store, socket) = try await makeStore(succeed: false)
        #expect(store.stateChanges("binary_sensor.door") == nil)
        #expect(!store.stateChangesLoadFailed("binary_sensor.door"))

        await store.loadStateChanges("binary_sensor.door")

        #expect(store.stateChanges("binary_sensor.door") == nil)
        #expect(store.stateChangesLoadFailed("binary_sensor.door"))
        #expect(await socket.requestCount == 1)
    }

    /// A later successful attempt must clear the earlier failure — otherwise reopening the modal
    /// after Home Assistant recovers would go on showing "Couldn't load recent changes" forever,
    /// the same permanence bug fix #3 exists to remove from the *other* direction.
    @Test func aSuccessfulFetchClearsAPriorFailureAndCachesTheList() async throws {
        let (store, socket) = try await makeStore(succeed: false)
        await store.loadStateChanges("binary_sensor.door")
        #expect(store.stateChangesLoadFailed("binary_sensor.door"))

        await socket.setSucceed(true)
        await store.loadStateChanges("binary_sensor.door")

        #expect(!store.stateChangesLoadFailed("binary_sensor.door"))
        #expect(store.stateChanges("binary_sensor.door") != nil)
    }

    /// Fix #2 itself: before it, `stateChangesByEntity` had no `fetched` date at all, so an entry
    /// never expired — opening a door sensor's modal at 09:00 and again at 18:00 kept showing
    /// 09:00's list. A stale entry (older than `HistoryRange.day.cacheLifetime`) must trigger a
    /// real re-fetch; a fresh one must not cause a second round trip.
    @Test func aStaleCacheEntryIsRefetchedButAFreshOneIsNot() async throws {
        let (store, socket) = try await makeStore(succeed: true)
        store.historyCache.stateChangesByEntity["binary_sensor.door"] =
            (changes: [], fetched: Date().addingTimeInterval(-(HistoryRange.day.cacheLifetime + 1)))

        await store.loadStateChanges("binary_sensor.door")
        #expect(await socket.requestCount == 1)

        // Freshly re-cached by the call above — a second call within the lifetime must not re-ask.
        await store.loadStateChanges("binary_sensor.door")
        #expect(await socket.requestCount == 1)
    }
}
