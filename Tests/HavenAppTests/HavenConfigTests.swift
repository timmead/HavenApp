import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// A scriptable Home Assistant socket: answers each command with whatever the test says, and
/// records every frame the app sent.
///
/// Duplicated from `DashboardConfigWriteBackTests` rather than shared. Two test files cannot see
/// each other's `private` types, and a shared test-support target for two callers costs more than
/// forty lines of fake — but if a third file needs this, that is the moment to extract it.
private actor ScriptedSocket: WebSocketConnection {
    private var incoming: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var sentTexts: [String] = []
    private var respond: (@Sendable (Int, String, [String: Any]) -> String?)?

    func connect() async throws {}
    nonisolated func close() {}

    func setResponder(_ f: @escaping @Sendable (Int, String, [String: Any]) -> String?) {
        respond = f
    }

    func send(_ data: Data) async throws {
        sentTexts.append(String(decoding: data, as: UTF8.self))
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? Int, let type = obj["type"] as? String else { return }
        if let body = respond?(id, type, obj) {
            enqueue(body.replacingOccurrences(of: "$ID", with: "\(id)"))
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

    func frameTexts(ofType type: String) -> [String] {
        sentTexts.filter { decode($0)?["type"] as? String == type }
    }
}

private let fixtureRegistry: [String: String] = [
    "config/floor_registry/list": #"[]"#,
    "config/area_registry/list": #"[{"area_id":"living","name":"Living","floor_id":null}]"#,
    "config/device_registry/list": #"[]"#,
    "config/entity_registry/list": #"[{"entity_id":"sensor.lr_temp","area_id":"living"}]"#,
]
private let fixtureStates =
    #"[{"entity_id":"sensor.lr_temp","state":"21.5","attributes":{"device_class":"temperature","unit_of_measurement":"°C"},"last_updated":"2026-07-27T00:00:00+00:00"}]"#

private func ok(_ id: Int) -> String {
    #"{"id":\#(id),"type":"result","success":true,"result":{"status":"ok","version":1}}"#
}
private func absent(_ id: Int) -> String {
    #"{"id":\#(id),"type":"result","success":true,"result":null}"#
}
private func decode(_ text: String) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
}

/// A one-shot flag usable from the socket's `@Sendable` responder.
private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var taken: Bool
    init(_ taken: Bool) { self.taken = taken }
    /// True exactly once — the second call and every one after it returns false.
    func takeIfUnset() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// **`HavenConfig`, the one writer of Haven's own configuration.**
///
/// Everything that decides *whether* an edit is possible and *what happens when a write goes wrong*
/// lives here: the gate on configuration mode, the refusal to write a no-op, the single conflict
/// retry that reapplies onto the other phone's document, and the two failures that must never reach
/// the user as errors.
@Suite @MainActor struct HavenConfigTests {

    /// Boots a store against a socket that serves the fixture home, deferring to `config` for the
    /// two `havenapp/config/*` commands and answering the admin probe with yes.
    private func boot(
        config: @escaping @Sendable (Int, String, [String: Any]) -> String?
    ) async throws -> (HomeStore, ScriptedSocket) {
        let socket = ScriptedSocket()
        await socket.setResponder { id, type, msg in
            if let body = fixtureRegistry[type] {
                return #"{"id":\#(id),"type":"result","success":true,"result":\#(body)}"#
            }
            switch type {
            case "get_states":
                return #"{"id":\#(id),"type":"result","success":true,"result":\#(fixtureStates)}"#
            case "subscribe_events":
                return #"{"id":\#(id),"type":"result","success":true,"result":null}"#
            case "auth/current_user":
                return #"{"id":\#(id),"type":"result","success":true,"result":{"is_admin":true}}"#
            default:
                return config(id, type, msg)
            }
        }
        await socket.enqueue(#"{"type":"auth_required"}"#)
        await socket.enqueue(#"{"type":"auth_ok"}"#)
        let client = HAWebSocketClient(connection: socket)
        try await client.authenticate(token: "t")
        let store = HomeStore()
        store.attach(HomeConnection(client: client))
        try await store.bootstrap()
        // `load` fires the admin probe without awaiting it, so that a Home Assistant which never
        // answers costs a menu item rather than the whole launch (see `HavenConfig.load`). Tests
        // that assert the gate need the answer to have landed, so they ask for it directly.
        await store.config.refreshAdminStatus()
        return (store, socket)
    }

    /// `canConfigure` is the whole gate on configuration mode, and every one of its inputs denies on
    /// its own. Written as one test over the matrix because the interesting property is that *each*
    /// is sufficient to deny — a version that ANDed only two of them would pass any single-case test.
    @Test func everyGateDeniesConfigurationOnItsOwn() {
        let config = HavenConfig()
        // Nothing attached, nothing loaded, no admin answer: denied three times over.
        #expect(!config.canConfigure)

        config.setForTesting(isAdmin: true, isLoaded: true, isWritable: true, isConnected: true)
        #expect(config.canConfigure)

        config.setForTesting(isAdmin: false, isLoaded: true, isWritable: true, isConnected: true)
        #expect(!config.canConfigure)
        // "Could not find out" is not a yes. The cost — an admin whose probe failed has no entry
        // until the next connect — is accepted; the alternative offers a household member a control
        // that cannot act.
        config.setForTesting(isAdmin: nil, isLoaded: true, isWritable: true, isConnected: true)
        #expect(!config.canConfigure)
        // Editing over a document we could not read is how a household's configuration gets
        // overwritten.
        config.setForTesting(isAdmin: true, isLoaded: false, isWritable: true, isConnected: true)
        #expect(!config.canConfigure)
        config.setForTesting(isAdmin: true, isLoaded: true, isWritable: false, isConnected: true)
        #expect(!config.canConfigure)
        // Every edit is a write.
        config.setForTesting(isAdmin: true, isLoaded: true, isWritable: true, isConnected: false)
        #expect(!config.canConfigure)
    }

    /// A write that changes nothing must not reach the socket at all: a no-op write churns the
    /// shared record's version and `updated_by` for nothing, which the rest of the household sees as
    /// somebody having edited the dashboard.
    @Test func aMutationThatChangesNothingSendsNoFrame() async throws {
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get": return absent(id)
            case "havenapp/config/set": return ok(id)
            default: return nil
            }
        }
        let before = await socket.frameTexts(ofType: "havenapp/config/set").count
        let outcome = await store.config.update { $0 }
        #expect(outcome == .unchanged)
        #expect(await socket.frameTexts(ofType: "havenapp/config/set").count == before)
    }

    /// A version conflict means another admin's phone wrote first. The mutation is reapplied to
    /// *their* document — not to ours, which would discard their change — and retried once.
    @Test func aConflictReappliesTheEditToTheOtherPhonesDocumentAndRetriesOnce() async throws {
        let bootstrapWrite = LockedBox(false)
        let (store, socket) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get": return absent(id)
            case "havenapp/config/set":
                // The bootstrap's own nomination write goes through; every write after it conflicts.
                if bootstrapWrite.takeIfUnset() { return ok(id) }
                return #"""
                {"id":\#(id),"type":"result","success":true,"result":{"status":"version_conflict",
                 "current":{"version":7,"payload":{"schema":1,
                 "entities":{"light.hall":{"name":"Hall"}}},"updated":"2026-07-28T00:00:00+00:00"}}}
                """#
            default: return nil
            }
        }
        // Conflicts, retries against version 7, and conflicts again — the second conflict is the one
        // this deliberately does not spin on. A busy document is left for the next edit.
        let outcome = await store.config.update { $0.settingDisplayName("Lamp", for: "light.kitchen") }
        #expect(outcome == .failed)
        // Their document is what we now hold: a retry that kept ours would have discarded their name.
        #expect(store.config.document.displayNames["light.hall"] == "Hall")
        let writes = await socket.frameTexts(ofType: "havenapp/config/set").compactMap(decode)
        #expect(writes.count == 3)                              // bootstrap, first attempt, one retry
        #expect(writes.last?["base_version"] as? Int == 7)      // the retry used *their* version
    }

    /// The same conflict, resolved: the retry succeeds, and the edit lands on top of the other
    /// phone's document rather than replacing it.
    @Test func aResolvedConflictKeepsBothPhonesEdits() async throws {
        let bootstrapWrite = LockedBox(false)
        let conflicted = LockedBox(false)
        let (store, _) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get": return absent(id)
            case "havenapp/config/set":
                if bootstrapWrite.takeIfUnset() { return ok(id) }
                if conflicted.takeIfUnset() {
                    return #"""
                    {"id":\#(id),"type":"result","success":true,"result":{"status":"version_conflict",
                     "current":{"version":7,"payload":{"schema":1,
                     "entities":{"light.hall":{"name":"Hall"}}},"updated":"2026-07-28T00:00:00+00:00"}}}
                    """#
                }
                return #"{"id":\#(id),"type":"result","success":true,"result":{"status":"ok","version":8}}"#
            default: return nil
            }
        }
        let outcome = await store.config.update { $0.settingDisplayName("Lamp", for: "light.kitchen") }
        #expect(outcome == .written)
        #expect(store.config.document.displayNames["light.hall"] == "Hall")
        #expect(store.config.document.displayNames["light.kitchen"] == "Lamp")
        #expect(store.config.version == 8)
    }

    /// Not an admin is an expected steady state for a household member, not a fault: it is reported
    /// as an outcome the caller can explain, never thrown or logged as an error. And the refusal
    /// closes the door behind it — `canConfigure` goes false, which is what leaves configuration
    /// mode without each sheet having to wire an exit.
    @Test func aRefusedWriteIsReportedAsNotAuthorizedAndClosesTheMode() async throws {
        let (store, _) = try await boot { id, type, _ in
            switch type {
            case "havenapp/config/get": return absent(id)
            case "havenapp/config/set":
                return #"""
                {"id":\#(id),"type":"result","success":false,
                 "error":{"code":"not_authorized","message":"admin required"}}
                """#
            default: return nil
            }
        }
        let outcome = await store.config.update { $0.settingDisplayName("Lamp", for: "light.kitchen") }
        #expect(outcome == .notAuthorized)
        #expect(store.config.isAdmin == false)
        #expect(!store.config.canConfigure)
    }

    /// A document that could not be *read* leaves `isLoaded` false — which is what stops the mode
    /// being entered at all. The distinction from an *absent* record, which is an ordinary first run
    /// and loads perfectly well, is the whole point.
    @Test func anUnreadableDocumentIsNotLoadedButAnAbsentOneIs() async throws {
        let (absentStore, _) = try await boot { id, type, _ in
            type == "havenapp/config/get" ? absent(id) : ok(id)
        }
        #expect(absentStore.config.isLoaded)
        #expect(absentStore.config.canConfigure)

        let (brokenStore, _) = try await boot { id, type, _ in
            guard type == "havenapp/config/get" else { return ok(id) }
            return #"""
            {"id":\#(id),"type":"result","success":false,
             "error":{"code":"unknown_error","message":"nope"}}
            """#
        }
        #expect(!brokenStore.config.isLoaded)
        #expect(!brokenStore.config.canConfigure)
    }

    /// **A document that could not be read is never written over**, and that has to hold for the
    /// automatic nomination write-back as much as for a user's edit — the write-back does not
    /// consult configuration mode at all, so `canConfigure` cannot be what protects it.
    ///
    /// Worth pinning rather than trusting: the previous design enforced this by *not calling* its
    /// write path in the failure branch, and consolidating writes behind one entry point quietly
    /// dropped it. The symptom was a bootstrap that hung — the proposal write went to a socket that
    /// had only ever been scripted to fail the read.
    @Test func aFailedReadIsNeverWrittenOver() async throws {
        let (store, socket) = try await boot { id, type, _ in
            guard type == "havenapp/config/get" else { return ok(id) }
            return #"""
            {"id":\#(id),"type":"result","success":false,
             "error":{"code":"unknown_error","message":"nope"}}
            """#
        }
        #expect(!store.config.isLoaded)
        // Bootstrap resolved and proposed, and wrote nothing at all.
        #expect(await socket.frameTexts(ofType: "havenapp/config/set").isEmpty)
        // Nor does an explicit edit get through.
        let outcome = await store.config.update { $0.settingDisplayName("Lamp", for: "light.kitchen") }
        #expect(outcome == .failed)
        #expect(await socket.frameTexts(ofType: "havenapp/config/set").isEmpty)
    }
}
