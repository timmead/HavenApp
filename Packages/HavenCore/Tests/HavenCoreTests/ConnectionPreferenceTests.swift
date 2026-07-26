import Testing
import Foundation
@testable import HavenCore

/// Candidate *ordering* under the three-layer home-detection stack.
///
/// The stack is graceful degradation, not a choice of alternatives: layer 1 (SSID) needs Location
/// Services, layer 2 (path class) is free, layer 3 (probe local, fail over) always works. So the
/// most important tests here are the ones showing that **permission absent behaves exactly like
/// SSID unknown** — the app has to be fully correct for a user who never grants location access,
/// because that is the default and, for a privacy-led product, the expected choice.
@Suite struct ConnectionPreferenceTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    private let lan = URL(string: "http://192.168.1.10:8123")!
    private let nabu = URL(string: "https://abc123.ui.nabu.casa")!

    // MARK: - homeSSIDMatch

    @Test func matchingSSIDsAreReportedAsAMatchCaseInsensitively() {
        #expect(ConnectionPreference.homeSSIDMatch(current: "Haven", home: "Haven") == true)
        // Two APs can legitimately differ in case; a case-sensitive miss would silently downgrade a
        // user who *did* grant permission back to the layer-3 probe.
        #expect(ConnectionPreference.homeSSIDMatch(current: "HAVEN", home: "haven") == true)
    }

    @Test func aDifferentSSIDIsReportedAsAMismatchNotAsUnknown() {
        // The distinction that matters: `false` means "we know we are NOT home" (skip the local
        // probe), `nil` means "no idea" (still probe local). Collapsing them loses layer 1 entirely.
        #expect(ConnectionPreference.homeSSIDMatch(current: "CafeWiFi", home: "Haven") == false)
    }

    @Test func aMissingSSIDOnEitherSideIsUnknownNotAMismatch() {
        // Location permission absent → current is nil. Never had a local connection yet → home is
        // nil. Neither is evidence of being away, and treating either as `false` would send a user
        // sitting at home straight out to their remote URL.
        #expect(ConnectionPreference.homeSSIDMatch(current: nil, home: "Haven") == nil)
        #expect(ConnectionPreference.homeSSIDMatch(current: "Haven", home: nil) == nil)
        #expect(ConnectionPreference.homeSSIDMatch(current: nil, home: nil) == nil)
        #expect(ConnectionPreference.homeSSIDMatch(current: "", home: "Haven") == nil)
        #expect(ConnectionPreference.homeSSIDMatch(current: "Haven", home: "") == nil)
    }

    // MARK: - leadingClass — every branch

    @Test func onTheHomeSSIDLocalLeadsWhateverThePathClassSays() {
        for path in [NetworkPathClass.wifi, .cellular, .other] {
            #expect(ConnectionPreference.leadingClass(homeSSIDMatch: true, pathClass: path) == .local)
        }
    }

    @Test func offTheHomeSSIDRemoteLeadsWhateverThePathClassSays() {
        for path in [NetworkPathClass.wifi, .cellular, .other] {
            #expect(ConnectionPreference.leadingClass(homeSSIDMatch: false, pathClass: path) == .remote)
        }
    }

    @Test func withoutAnSSIDSignalCellularLeadsRemoteAndWiFiLeadsLocal() {
        #expect(ConnectionPreference.leadingClass(homeSSIDMatch: nil, pathClass: .cellular) == .remote)
        // Wi-Fi does NOT mean home — `NWPathMonitor` distinguishes Wi-Fi from cellular, not home
        // Wi-Fi from a café's. So `.wifi` means only "a LAN address is worth the 2s probe".
        #expect(ConnectionPreference.leadingClass(homeSSIDMatch: nil, pathClass: .wifi) == .local)
        // Wired/unknown: same reasoning as Wi-Fi. A LAN address might well answer.
        #expect(ConnectionPreference.leadingClass(homeSSIDMatch: nil, pathClass: .other) == .local)
    }

    // MARK: - Ordering

    @Test func homeSSIDMatchPutsTheLocalCandidateFirst() {
        let ordered = ConnectionPreference.candidates(
            userEntered: lan, discoveredInternal: nil, discoveredExternal: nabu,
            homeSSIDMatch: true, pathClass: .wifi
        )
        #expect(ordered == [.local(lan), .remote(nabu)])
    }

    @Test func aForeignSSIDPutsTheRemoteCandidateFirst() {
        let ordered = ConnectionPreference.candidates(
            userEntered: lan, discoveredInternal: nil, discoveredExternal: nabu,
            homeSSIDMatch: false, pathClass: .wifi
        )
        #expect(ordered == [.remote(nabu), .local(lan)])
    }

    @Test func cellularWithoutAnSSIDSignalPutsTheRemoteCandidateFirst() {
        let ordered = ConnectionPreference.candidates(
            userEntered: lan, discoveredInternal: nil, discoveredExternal: nabu,
            homeSSIDMatch: nil, pathClass: .cellular
        )
        #expect(ordered == [.remote(nabu), .local(lan)])
    }

    @Test func wifiWithoutAnSSIDSignalProbesLocalFirstThenRemote() {
        // Layer 3, the universal fallback and the only one always available.
        let ordered = ConnectionPreference.candidates(
            userEntered: lan, discoveredInternal: nil, discoveredExternal: nabu,
            homeSSIDMatch: nil, pathClass: .wifi
        )
        #expect(ordered == [.local(lan), .remote(nabu)])
    }

    /// The requirement that outranks every optimisation here: the app must be **fully correct with
    /// Location permission denied**. With no SSID signal the ordering is decided entirely by layers
    /// 2–3, and every candidate is still tried.
    @Test func withLocationPermissionAbsentEveryCandidateIsStillReachedOnEveryPathClass() {
        for path in [NetworkPathClass.wifi, .cellular, .other] {
            let ordered = ConnectionPreference.candidates(
                userEntered: lan, discoveredInternal: nil, discoveredExternal: nabu,
                homeSSIDMatch: nil, pathClass: path
            )
            #expect(ordered.count == 2)
            #expect(ordered.contains(.local(lan)))
            #expect(ordered.contains(.remote(nabu)))
        }
    }

    /// Deliberate deviation from the plan's "on cellular, skip local entirely" parenthetical:
    /// candidates are **reordered, never dropped**. `ConnectionEndpoint.candidates` buckets any
    /// non-Nabu-Casa user-entered URL as local, so a Tailscale or reverse-proxy user's URL — the
    /// one that actually works off-LAN — sits in the "local" bucket. Dropping locals on cellular
    /// would strip their only working candidate the moment they also had a Nabu Casa URL, and would
    /// break the "never empty while any input is non-nil" invariant besides. The 2s connect
    /// deadline is what makes carrying a doomed candidate at the back cheap enough.
    @Test func cellularNeverDropsCandidatesItOnlyReordersThem() {
        let tailscale = url("https://ha.example.com")
        let ordered = ConnectionPreference.candidates(
            userEntered: tailscale, discoveredInternal: nil, discoveredExternal: nil,
            homeSSIDMatch: nil, pathClass: .cellular
        )
        // Bucketed local by hostname, kept anyway — and it is the only way this user connects.
        #expect(ordered == [.local(tailscale)])
    }

    @Test func aLocalOnlySetupIsUnaffectedByEveryLayer() {
        for (match, path) in [(true, NetworkPathClass.wifi), (false, .wifi), (false, .cellular)] as [(Bool?, NetworkPathClass)] {
            let ordered = ConnectionPreference.candidates(
                userEntered: lan, discoveredInternal: nil, discoveredExternal: nil,
                homeSSIDMatch: match, pathClass: path
            )
            #expect(ordered == [.local(lan)])
        }
    }

    @Test func orderingIsStableWithinEachClass() {
        let internalURL = url("http://192.168.1.20:8123")
        let ordered = ConnectionPreference.candidates(
            userEntered: lan, discoveredInternal: internalURL, discoveredExternal: nabu,
            homeSSIDMatch: false, pathClass: .wifi
        )
        // Remote first, then the two locals in the order `ConnectionEndpoint.candidates` produced.
        #expect(ordered == [.remote(nabu), .local(internalURL), .local(lan)])
    }

    // MARK: - lastWorking hoist

    @Test func lastWorkingHoistsWithinTheLeadingClass() {
        let internalURL = url("http://192.168.1.20:8123")
        let ordered = ConnectionPreference.candidates(
            userEntered: lan, discoveredInternal: internalURL, discoveredExternal: nabu,
            lastWorking: lan, homeSSIDMatch: true, pathClass: .wifi
        )
        // Both locals lead; the one that last worked goes first among them.
        #expect(ordered == [.local(lan), .local(internalURL), .remote(nabu)])
    }

    /// The reason the hoist is gated on the leading class. `lastWorking` is written on every
    /// successful connect, so after any evening at home it holds the *local* URL. Hoisting it
    /// unconditionally would put that doomed local candidate first again the next morning on
    /// cellular — reintroducing precisely the stall layer 2 exists to remove, and making the SSID
    /// layer pointless whenever the user was last home (i.e. almost always).
    @Test func lastWorkingDoesNotHoistAgainstALiveSignalAboutWhereWeAre() {
        let ordered = ConnectionPreference.candidates(
            userEntered: lan, discoveredInternal: nil, discoveredExternal: nabu,
            lastWorking: lan, homeSSIDMatch: nil, pathClass: .cellular
        )
        #expect(ordered == [.remote(nabu), .local(lan)])
    }

    @Test func lastWorkingHoistsTheRemoteCandidateWhenRemoteLeads() {
        let other = url("https://other.ui.nabu.casa")
        let ordered = ConnectionPreference.candidates(
            userEntered: lan, discoveredInternal: other, discoveredExternal: nabu,
            lastWorking: nabu, homeSSIDMatch: false, pathClass: .wifi
        )
        #expect(ordered.first == .remote(nabu))
    }

    @Test func aLastWorkingURLThatIsNotAmongTheCandidatesIsIgnored() {
        let ordered = ConnectionPreference.candidates(
            userEntered: lan, discoveredInternal: nil, discoveredExternal: nabu,
            lastWorking: url("http://10.9.9.9:8123"), homeSSIDMatch: true, pathClass: .wifi
        )
        #expect(ordered == [.local(lan), .remote(nabu)])
    }

    @Test func noInputsYieldsAnEmptyListRatherThanAnInventedCandidate() {
        let ordered = ConnectionPreference.candidates(
            userEntered: nil, discoveredInternal: nil, discoveredExternal: nil,
            homeSSIDMatch: nil, pathClass: .wifi
        )
        #expect(ordered.isEmpty)
    }
}
