import Testing
import Foundation
@testable import HavenCore

@Suite struct NWWebSocketConnectionTests {
    @Test func connectTimesOutAgainstAnUnreachableAddressInsteadOfHangingOnNetworkFrameworksDefault() async throws {
        // 192.0.2.0/24 is IANA's TEST-NET-1 — reserved for documentation, guaranteed to never
        // have a live host answering — a safe stand-in for "the LAN candidate when the phone is
        // away from home." Without NWWebSocketConnection's explicit deadline, Network.framework's
        // own default TCP connect timeout is tens of seconds; this is what proves AppModel's
        // candidate failover isn't starved waiting on that for a dead local address.
        let url = URL(string: "ws://192.0.2.1:8123/api/websocket")!
        let conn = NWWebSocketConnection(url: url, deadline: .seconds(2))
        let start = Date()
        await #expect(throws: Error.self) {
            try await conn.connect()
        }
        // Generous upper bound: proves we bailed out near our own deadline, not near
        // Network.framework's much longer default.
        #expect(Date().timeIntervalSince(start) < 8)
    }
}
