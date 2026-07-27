import Testing
import Foundation
@testable import HavenCore

/// An authenticated `HomeConnection` over a fake socket, plus the last `havenapp/config/*` frame
/// the client sent — the wire shape matters as much as the decode here, since `base_version` being
/// wrong is silent (the write just conflicts forever).
private func connectedHome(
    _ respond: @escaping @Sendable (Int, String, [String: Any]) -> String?
) async throws -> (HomeConnection, FakeWebSocketConnection) {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { data in
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? Int, let type = obj["type"] as? String else { return }
        if let body = respond(id, type, obj) {
            await conn.enqueueIncoming(body.replacingOccurrences(of: "$ID", with: "\(id)"))
        }
    }
    return (HomeConnection(client: client), conn)
}

private func result(_ body: String) -> String {
    #"{"id":$ID,"type":"result","success":true,"result":\#(body)}"#
}

@Test func configGetReturnsNilForAbsentRecord() async throws {
    let (home, _) = try await connectedHome { _, type, _ in
        type == "havenapp/config/get" ? result("null") : nil
    }
    #expect(try await home.loadConfig(scope: "shared", key: "dashboard") == nil)
}

@Test func configGetDecodesRecord() async throws {
    let (home, _) = try await connectedHome { _, type, _ in
        guard type == "havenapp/config/get" else { return nil }
        return result(#"{"version":3,"payload":{"schema":1},"updated":"2026-07-27T00:00:00+00:00","updated_by":"user-1"}"#)
    }
    let record = try #require(try await home.loadConfig(scope: "shared", key: "dashboard"))
    #expect(record.version == 3)
    #expect(record.updatedBy == "user-1")
    #expect(record.payload.asObject?["schema"]?.asInt == 1)
}

@Test func configSetSendsBaseVersionAndPayload() async throws {
    let (home, conn) = try await connectedHome { _, type, _ in
        type == "havenapp/config/set" ? result(#"{"status":"ok","version":1}"#) : nil
    }
    let write = try await home.saveConfig(scope: "shared", key: "dashboard", baseVersion: 0,
                                          payload: .object(["schema": .int(1)]))
    #expect(write == .ok(version: 1))

    // The wire shape, asserted rather than assumed: `base_version: 0` is what the integration
    // requires for a first write (`ConfigStore.async_set` compares against `existing.version if
    // existing else 0`), and getting it wrong would make every first write conflict forever
    // without ever surfacing an error.
    // Matched on the decoded `type`, not a substring of the raw text: `JSONSerialization` escapes
    // forward slashes, so the frame on the wire reads `havenapp\/config\/set`. Valid JSON that HA
    // parses fine — but a substring search for the unescaped form silently finds nothing.
    let frames = await conn.sentTexts().compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
    let frame = try #require(frames.first { $0["type"] as? String == "havenapp/config/set" })
    #expect(frame["base_version"] as? Int == 0)
    #expect(frame["scope"] as? String == "shared")
    #expect(frame["key"] as? String == "dashboard")
    #expect((frame["payload"] as? [String: Any])?["schema"] as? Int == 1)
}

/// A stale write must arrive as a *value* carrying the current record, not a thrown error. The
/// integration deliberately returns it as a success result for exactly this reason (HA's
/// `send_error` cannot attach a payload), and throwing it away would force the refetch that design
/// exists to avoid.
@Test func configSetSurfacesVersionConflictWithCurrentRecord() async throws {
    let (home, _) = try await connectedHome { _, type, _ in
        guard type == "havenapp/config/set" else { return nil }
        return result(#"""
        {"status":"version_conflict","current":{"version":7,"payload":{"schema":1},
         "updated":"2026-07-27T00:00:00+00:00","updated_by":"other"}}
        """#)
    }
    let write = try await home.saveConfig(scope: "shared", key: "dashboard", baseVersion: 2,
                                          payload: .object([:]))
    guard case .versionConflict(let current) = write else {
        Issue.record("expected .versionConflict, got \(write)"); return
    }
    #expect(current?.version == 7)
    #expect(current?.updatedBy == "other")
}

/// A record deleted between the read and the write conflicts with a null `current`. The caller
/// retries from version 0, which is the correct base for a record that no longer exists.
@Test func configSetVersionConflictToleratesNullCurrent() async throws {
    let (home, _) = try await connectedHome { _, type, _ in
        guard type == "havenapp/config/set" else { return nil }
        return result(#"{"status":"version_conflict","current":null}"#)
    }
    let write = try await home.saveConfig(scope: "shared", key: "dashboard", baseVersion: 4,
                                          payload: .object([:]))
    #expect(write == .versionConflict(current: nil))
}

/// A non-admin writing `shared` is the expected steady state for a household member, so the code
/// must survive intact for the caller to recognise it rather than collapsing into a generic
/// failure.
@Test func configSetPreservesNotAuthorizedCode() async throws {
    let (home, _) = try await connectedHome { _, type, _ in
        guard type == "havenapp/config/set" else { return nil }
        return #"{"id":$ID,"type":"result","success":false,"error":{"code":"not_authorized","message":"not authorized for this scope"}}"#
    }
    await #expect(throws: WSError.self) {
        _ = try await home.saveConfig(scope: "shared", key: "dashboard", baseVersion: 0,
                                      payload: .object([:]))
    }
    do {
        _ = try await home.saveConfig(scope: "shared", key: "dashboard", baseVersion: 0,
                                      payload: .object([:]))
    } catch let error as WSError {
        #expect(error.isNotAuthorized)
    }
}
