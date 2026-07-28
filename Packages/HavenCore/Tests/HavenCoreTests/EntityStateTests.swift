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

private func state(_ value: String) -> EntityState {
    EntityState(entityId: "sensor.x", state: value, attributes: [:],
                lastUpdated: Date(timeIntervalSince1970: 0))
}

/// Home Assistant's two "there is no reading here" states. Every surface that renders an entity
/// needs the same answer, and before this they each spelled it out separately.
@Test func unavailableAndUnknownAreTheUnavailableStates() {
    #expect(state("unavailable").isUnavailable)
    #expect(state("unknown").isUnavailable)
}

/// Every ordinary state is available — including "off", which is a perfectly good reading and
/// must never be confused with an unreachable device. That confusion is the whole reason the
/// calm-state work exists.
@Test func ordinaryStatesAreAvailable() {
    for value in ["on", "off", "open", "closed", "locked", "jammed", "heat", "playing", "21.5", ""] {
        #expect(!state(value).isUnavailable, "\(value) should be available")
    }
}

/// Home Assistant's state strings are lowercase; nothing normalises case on the way in, so an
/// entity reporting "Unavailable" is a different string and is deliberately not matched. Pinned
/// so a future "helpful" lowercasing is a conscious change rather than a silent one.
@Test func matchingIsExactAndCaseSensitive() {
    #expect(!state("Unavailable").isUnavailable)
    #expect(!state("UNKNOWN").isUnavailable)
}
