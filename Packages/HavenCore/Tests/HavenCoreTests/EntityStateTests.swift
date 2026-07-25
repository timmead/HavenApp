import Testing
import Foundation
@testable import HavenCore

@Test func domainIsPrefixBeforeDot() {
    let s = EntityState(entityId: "light.kitchen", state: "on", attributes: [:], lastUpdated: .init())
    #expect(s.domain == "light")
}

@Test func jsonValueDecodesMixedAttributes() throws {
    let json = #"{"brightness": 254, "friendly_name": "Kitchen", "on": true, "nested": {"x": 1.5}}"#.data(using: .utf8)!
    let v = try HACoding.decoder.decode([String: JSONValue].self, from: json)
    #expect(v["brightness"]?.asInt == 254)
    #expect(v["friendly_name"]?.asString == "Kitchen")
    #expect(v["on"] == .bool(true))
    #expect(v["nested"]?.asObject?["x"]?.asDouble == 1.5)
}
