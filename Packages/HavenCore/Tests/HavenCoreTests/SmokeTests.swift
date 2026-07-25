import Testing
@testable import HavenCore

@Test func versionIsSet() {
    #expect(HavenCoreVersion.current == "0.1.0")
}
