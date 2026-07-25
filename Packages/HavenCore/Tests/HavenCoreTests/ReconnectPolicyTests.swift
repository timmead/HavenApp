import Testing
@testable import HavenCore

@Test func linearBackoffCaps() {
    let p = ReconnectPolicy(base: .seconds(3), max: .seconds(30))
    #expect(p.delay(forAttempt: 0) == .seconds(0))
    #expect(p.delay(forAttempt: 1) == .seconds(3))
    #expect(p.delay(forAttempt: 5) == .seconds(15))
    #expect(p.delay(forAttempt: 100) == .seconds(30))
}
