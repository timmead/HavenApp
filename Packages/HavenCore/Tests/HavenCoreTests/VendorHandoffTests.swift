import Foundation
import Testing
@testable import HavenCore

@Test func uniFiProtectOrdersPerDeviceThenPlainAppLaunch() {
    let candidates = VendorHandoff.candidates(platform: "unifiprotect", uniqueId: "abc123")
    #expect(candidates == [
        URL(string: "unifi-protect://protect/devices/abc123")!,
        URL(string: "unifi-protect://")!,
    ])
}

@Test func uniFiProtectPercentEncodesAColonOrSlashBearingUniqueId() {
    // MAC-derived unique ids commonly contain `:`; some integrations compose ids with `/`. Both
    // must be escaped into the path segment rather than read as path structure.
    let candidates = VendorHandoff.candidates(platform: "unifiprotect", uniqueId: "aa:bb/cc")
    #expect(candidates.first == URL(string: "unifi-protect://protect/devices/aa%3Abb%2Fcc"))
}

@Test func uniFiProtectWithNilUniqueIdStillYieldsPlainAppLaunch() {
    let candidates = VendorHandoff.candidates(platform: "unifiprotect", uniqueId: nil)
    #expect(candidates == [URL(string: "unifi-protect://")!])
}

@Test func uniFiProtectWithEmptyUniqueIdStillYieldsPlainAppLaunch() {
    // Never a malformed per-device URL from an empty string — the ladder still has its
    // app-launch rung.
    let candidates = VendorHandoff.candidates(platform: "unifiprotect", uniqueId: "")
    #expect(candidates == [URL(string: "unifi-protect://")!])
}

@Test func sonosYieldsOnlyThePlainAppLaunch() {
    let candidates = VendorHandoff.candidates(platform: "sonos", uniqueId: "RINCON_123")
    #expect(candidates == [URL(string: "sonos://")!])
}

@Test func sonosWithNilUniqueIdStillYieldsPlainAppLaunch() {
    let candidates = VendorHandoff.candidates(platform: "sonos", uniqueId: nil)
    #expect(candidates == [URL(string: "sonos://")!])
}

@Test func unknownPlatformYieldsNoCandidates() {
    #expect(VendorHandoff.candidates(platform: "hue", uniqueId: "abc123") == [])
    #expect(VendorHandoff.candidates(platform: nil, uniqueId: "abc123") == [])
}
