import Testing
import Foundation
@testable import HavenCore

@Test func decodesAuthRequired() throws {
    let f = try ServerFrame.decode(#"{"type":"auth_required","ha_version":"2026.7"}"#)
    #expect(f == .authRequired)
}
@Test func decodesResultSuccess() throws {
    let f = try ServerFrame.decode(#"{"id":5,"type":"result","success":true,"result":[]}"#)
    guard case let .result(id, success, _, error) = f else { Issue.record("wrong frame"); return }
    #expect(id == 5 && success && error == nil)
}
@Test func decodesResultError() throws {
    let f = try ServerFrame.decode(#"{"id":6,"type":"result","success":false,"error":{"code":"x","message":"nope"}}"#)
    guard case let .result(_, success, _, error) = f else { Issue.record("wrong"); return }
    #expect(!success && error == WSError(code: "x", message: "nope"))
}
@Test func decodesStateChangedEvent() throws {
    let json = #"""
    {"id":9,"type":"event","event":{"event_type":"state_changed","data":{"entity_id":"light.k",
    "new_state":{"entity_id":"light.k","state":"on","attributes":{"brightness":200},"last_updated":"2026-07-25T10:00:00.000000+00:00"}}}}
    """#
    guard case let .event(_, payload) = try ServerFrame.decode(json) else { Issue.record("not event"); return }
    let sc = try StateChangedEvent(eventPayload: payload)
    #expect(sc.newState?.entityId == "light.k")
    #expect(sc.newState?.attributes["brightness"]?.asInt == 200)
}
@Test func encodesAuth() throws {
    let data = WSCommand.auth(token: "abc")
    let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(obj["type"] as? String == "auth")
    #expect(obj["access_token"] as? String == "abc")
}
@Test func encodesCallService() throws {
    let data = WSCommand.callService(id: 3, domain: "light", service: "toggle", entityId: "light.k")
    let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(obj["type"] as? String == "call_service")
    #expect(obj["domain"] as? String == "light")
    let target = obj["target"] as? [String: Any]
    #expect(target?["entity_id"] as? String == "light.k")
}
