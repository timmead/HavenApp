import Testing
import Foundation
@testable import HavenCore

// Tests for the Nabu Casa bootstrap: `cloud/status`'s wire shape, the pure classifier that turns
// it into a decision, and the trust gate the resulting URL has to pass before it is stored.
//
// Two themes run through the whole file and are worth stating once:
//
//  1. **Intent is not state.** `prefs.remote_enabled` says whether the user switched remote access
//     on; `remote_connected` says whether the tunnel happens to be up this second. Only the first
//     can justify offering to change someone's Home Assistant configuration.
//  2. **A missing key is not `false`.** Every field decodes optional, and the classifier branches
//     on `== false` / `== true` explicitly, so an absent field can never be mistaken for a
//     confident answer. This is the `components: []` failure shape, in a place where getting it
//     wrong proposes a mutation.

// MARK: - The command itself

@Test func cloudStatusEmitsTheExactCommandNameHomeAssistantRegisters() throws {
    // Not ceremony. HA answers an unregistered command with `unknown_command`, which
    // `classify` reads as "the cloud component isn't loaded" — so a typo in this string is
    // indistinguishable, at the wire level, from a genuinely self-hosted instance, and would
    // silently send *every* Nabu Casa subscriber down the custom-URL path. Verified against
    // `home-assistant/core`, `components/cloud/http_api.py`.
    let data = WSCommand.cloudStatus(id: 7)
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(obj["type"] as? String == "cloud/status")
    #expect(obj["id"] as? Int == 7)
}

// MARK: - Decoding

private func decodeStatus(_ json: String) throws -> HACloudStatus {
    // A plain decoder, matching `HomeConnection.fetchCloudStatus` exactly — `HACoding.decoder`'s
    // `.convertFromSnakeCase` would defeat the explicit snake_case `CodingKeys`.
    try JSONDecoder().decode(HACloudStatus.self, from: Data(json.utf8))
}

@Test func decodesTheFullSignedInShape() throws {
    let status = try decodeStatus(#"""
    {"logged_in":true,"active_subscription":true,"remote_domain":"abc123.ui.nabu.casa",
     "remote_connected":true,"email":"a@b.c",
     "prefs":{"remote_enabled":true,"remote_allow_remote_enable":true,"alexa_enabled":false}}
    """#)
    #expect(status.loggedIn == true)
    #expect(status.activeSubscription == true)
    #expect(status.remoteDomain == "abc123.ui.nabu.casa")
    #expect(status.remoteConnected == true)
    #expect(status.prefs?.remoteEnabled == true)
    #expect(status.prefs?.remoteAllowRemoteEnable == true)
}

@Test func decodesHomeAssistantsMinimalSignedOutShape() throws {
    // What `_account_data` actually returns when no cloud account is signed in: `logged_in` and
    // little else. Everything absent must decode as `nil` rather than throwing.
    let status = try decodeStatus(#"{"logged_in":false,"cloud":"disconnected"}"#)
    #expect(status.loggedIn == false)
    #expect(status.activeSubscription == nil)
    #expect(status.remoteDomain == nil)
    #expect(status.remoteConnected == nil)
    #expect(status.prefs == nil)
}

@Test func aMissingBoolDecodesAsNilNotFalse() throws {
    // The whole reason every field is optional. If `remote_enabled` defaulted to `false`, a
    // subscriber whose remote access works perfectly would be told it is switched off and invited
    // to "fix" it — the `HAInstanceConfig.components` mistake, relocated somewhere it mutates the
    // user's Home Assistant.
    let status = try decodeStatus(#"{"logged_in":true,"active_subscription":true,"prefs":{}}"#)
    #expect(status.prefs != nil)
    #expect(status.prefs?.remoteEnabled == nil)
    #expect(status.prefs?.remoteAllowRemoteEnable == nil)
    #expect(status.remoteConnected == nil)
}

@Test func fetchCloudStatusDecodesASuccessfulProbe() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["id"] as? Int, obj?["type"] as? String == "cloud/status" else { return }
        let body = #"{"logged_in":true,"active_subscription":true,"remote_domain":"abc123.ui.nabu.casa","remote_connected":false,"prefs":{"remote_enabled":true}}"#
        await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":\#(body)}"#)
    }
    let home = HomeConnection(client: client)
    let result = await home.fetchCloudStatus()
    #expect(result == .success(HACloudStatus(
        loggedIn: true,
        activeSubscription: true,
        remoteDomain: "abc123.ui.nabu.casa",
        remoteConnected: false,
        prefs: HACloudStatus.Prefs(remoteEnabled: true)
    )))
}

@Test func fetchCloudStatusSurfacesUnknownCommandAsAFailureRatherThanThrowing() async throws {
    // The self-hosted instance: `cloud` isn't loaded, so HA never registered the command. It must
    // arrive as an ordinary `.failure` the classifier can read — never as a thrown error that
    // would take down the caller's connect path.
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["id"] as? Int, obj?["type"] as? String == "cloud/status" else { return }
        await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":false,"error":{"code":"unknown_command","message":"unknown command"}}"#)
    }
    let home = HomeConnection(client: client)
    let result = await home.fetchCloudStatus()
    #expect(result == .failure(WSError(code: "unknown_command", message: "unknown command")))
    #expect(NabuCasaRemoteAccessDetector.classify(result) == .cloudNotLoaded)
}

@Test func fetchCloudStatusNormalizesAnUndecodablePayloadToProbeFailed() async throws {
    // A payload of the wrong *type* (not merely missing keys) must not throw out of the probe, and
    // must not borrow a code that looks like one of HA's own.
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["id"] as? Int, obj?["type"] as? String == "cloud/status" else { return }
        await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":{"logged_in":"yes"}}"#)
    }
    let home = HomeConnection(client: client)
    let result = await home.fetchCloudStatus()
    guard case .failure(let error) = result else {
        Issue.record("expected a decode failure to surface as .failure, got \(result)")
        return
    }
    #expect(error.code == "probe_failed")
    // And critically, it is *not* read as "cloud isn't loaded".
    #expect(NabuCasaRemoteAccessDetector.classify(result) == .indeterminate)
}

// MARK: - The five plan outcomes

@Test func activeSubscriptionWithRemoteEnabledYieldsTheRemoteURL() {
    let status = HACloudStatus(
        loggedIn: true, activeSubscription: true,
        remoteDomain: "abc123.ui.nabu.casa", remoteConnected: true,
        prefs: .init(remoteEnabled: true)
    )
    #expect(NabuCasaRemoteAccessDetector.classify(.success(status))
            == .remoteAvailable(URL(string: "https://abc123.ui.nabu.casa")!))
}

@Test func activeSubscriptionWithRemoteExplicitlyDisabledYieldsRemoteDisabled() {
    let status = HACloudStatus(
        loggedIn: true, activeSubscription: true,
        remoteDomain: "abc123.ui.nabu.casa", remoteConnected: false,
        prefs: .init(remoteEnabled: false)
    )
    #expect(NabuCasaRemoteAccessDetector.classify(.success(status))
            == .remoteDisabled(domain: "abc123.ui.nabu.casa"))
}

@Test func loggedInWithoutAnActiveSubscriptionYieldsNoSubscription() {
    let status = HACloudStatus(loggedIn: true, activeSubscription: false)
    #expect(NabuCasaRemoteAccessDetector.classify(.success(status)) == .noSubscription)
}

@Test func unknownCommandYieldsCloudNotLoadedAndNeverAnError() {
    // The self-hosted user — Tailscale, a reverse proxy, a plain HA install. Getting this branch
    // wrong walks someone whose remote access already works into a Nabu Casa dead end. There is no
    // error case in `NabuCasaRemoteAccess` at all, by construction; this asserts the mapping.
    let result: Result<HACloudStatus, WSError> =
        .failure(WSError(code: "unknown_command", message: "unknown command"))
    #expect(NabuCasaRemoteAccessDetector.classify(result) == .cloudNotLoaded)
}

@Test func loggedInFalseYieldsNotLoggedIn() {
    #expect(NabuCasaRemoteAccessDetector.classify(.success(HACloudStatus(loggedIn: false)))
            == .notLoggedIn)
}

// MARK: - The distinction that decides whether we propose a mutation

@Test func remoteEnabledTrueWithRemoteConnectedFalseIsAvailableNotDisabled() {
    // **The test this task exists for.** `prefs.remote_enabled` is intent; `remote_connected` is
    // current state, and it reads `false` while the tunnel is establishing or after a brief drop.
    // Branching on it would produce `.remoteDisabled` here, and Task 3 would then offer to change
    // the user's Home Assistant configuration to fix something that was never broken. The URL is
    // adopted regardless: a tunnel that is down now may well be up by the time we need it, and a
    // wrong candidate costs one 2s connect attempt.
    let status = HACloudStatus(
        loggedIn: true, activeSubscription: true,
        remoteDomain: "abc123.ui.nabu.casa", remoteConnected: false,
        prefs: .init(remoteEnabled: true)
    )
    #expect(NabuCasaRemoteAccessDetector.classify(.success(status))
            == .remoteAvailable(URL(string: "https://abc123.ui.nabu.casa")!))
}

@Test func remoteConnectedTrueDoesNotOverrideAnExplicitlyDisabledPreference() {
    // The mirror image, asserted so nobody "simplifies" the two fields into one: intent is the
    // authority in both directions.
    let status = HACloudStatus(
        loggedIn: true, activeSubscription: true,
        remoteDomain: "abc123.ui.nabu.casa", remoteConnected: true,
        prefs: .init(remoteEnabled: false)
    )
    #expect(NabuCasaRemoteAccessDetector.classify(.success(status))
            == .remoteDisabled(domain: "abc123.ui.nabu.casa"))
}

@Test func aMissingRemoteEnabledPreferenceIsNotTreatedAsDisabled() {
    // Absent is not `false`. Reading it as "switched off" would propose a mutation of the user's
    // Home Assistant on the strength of a key we never saw.
    let status = HACloudStatus(
        loggedIn: true, activeSubscription: true,
        remoteDomain: "abc123.ui.nabu.casa", prefs: .init()
    )
    #expect(NabuCasaRemoteAccessDetector.classify(.success(status))
            == .remoteAvailable(URL(string: "https://abc123.ui.nabu.casa")!))
    // ...and the same with no `prefs` object at all.
    let noPrefs = HACloudStatus(
        loggedIn: true, activeSubscription: true, remoteDomain: "abc123.ui.nabu.casa"
    )
    #expect(NabuCasaRemoteAccessDetector.classify(.success(noPrefs))
            == .remoteAvailable(URL(string: "https://abc123.ui.nabu.casa")!))
}

@Test func remoteDisabledIsStillReportedWhenNoDomainWasGiven() {
    // The case's trigger is the preference alone. Requiring a domain would add a second, unstated
    // precondition and route a genuinely switched-off user into `.indeterminate`, where Task 3
    // would offer them nothing — and `cloud/remote/connect` needs no domain to run.
    let status = HACloudStatus(
        loggedIn: true, activeSubscription: true, remoteDomain: nil, prefs: .init(remoteEnabled: false)
    )
    #expect(NabuCasaRemoteAccessDetector.classify(.success(status)) == .remoteDisabled(domain: nil))
}

// MARK: - Indeterminate: the cases where no confident claim is available

@Test func anActiveSubscriptionWithNoRemoteDomainProducesNoURLAndDoesNotCrash() {
    // Subscribed, not switched off, but nothing to build a URL from — a tunnel mid-registration
    // looks like this. `.noSubscription` would tell a paying subscriber they aren't one;
    // `.remoteDisabled` would invite them to mutate a Home Assistant that isn't misconfigured.
    let status = HACloudStatus(
        loggedIn: true, activeSubscription: true, remoteDomain: nil,
        remoteConnected: false, prefs: .init(remoteEnabled: true)
    )
    let outcome = NabuCasaRemoteAccessDetector.classify(.success(status))
    #expect(outcome == .indeterminate)
    // Whatever else happens, no URL escapes into the candidate list.
    #expect(NabuCasaRemoteAccessDetector.adoptableRemoteURL(from: outcome, learnedOver: .local) == nil)
}

@Test func anEmptyOrWhitespaceRemoteDomainProducesNoURL() {
    for domain in ["", "   ", "\n"] {
        let status = HACloudStatus(
            loggedIn: true, activeSubscription: true, remoteDomain: domain,
            prefs: .init(remoteEnabled: true)
        )
        #expect(NabuCasaRemoteAccessDetector.classify(.success(status)) == .indeterminate)
    }
}

@Test func aMissingActiveSubscriptionFlagIsUnknownNotNoSubscription() {
    // `.noSubscription` is a claim about the user's account. It needs the key to actually say so.
    let status = HACloudStatus(loggedIn: true, activeSubscription: nil, remoteDomain: "abc.ui.nabu.casa")
    #expect(NabuCasaRemoteAccessDetector.classify(.success(status)) == .indeterminate)
}

@Test func aTransportFailureIsNotReportedAsCloudNotLoaded() {
    // The converse of the `unknown_command` mapping, and the mirror of the bug it guards against:
    // a dropped socket normalizes to `probe_failed`, and reading *that* as "cloud isn't loaded"
    // would tell a Nabu Casa subscriber whose Wi-Fi blipped that they are self-hosted.
    for code in ["probe_failed", "closed", "not_authorized", "unknown"] {
        let result: Result<HACloudStatus, WSError> = .failure(WSError(code: code, message: "x"))
        #expect(NabuCasaRemoteAccessDetector.classify(result) == .indeterminate)
    }
}

// MARK: - URL derivation

@Test func httpsIsPrependedExactlyOnce() {
    let url = NabuCasaRemoteAccessDetector.remoteURL(fromDomain: "abc123.ui.nabu.casa")
    #expect(url?.absoluteString == "https://abc123.ui.nabu.casa")
    #expect(url?.scheme == "https")
    #expect(url?.host() == "abc123.ui.nabu.casa")
}

@Test func theDerivedURLSurvivesTheAdoptionPathWithoutGainingASecondScheme() {
    // End-to-end through the real gate: `DiscoveredCandidateURLs.validating` also forces `https`,
    // so this is where a double-prefix would show up if the derivation ever grew one.
    let outcome = NabuCasaRemoteAccessDetector.classify(.success(HACloudStatus(
        loggedIn: true, activeSubscription: true,
        remoteDomain: "abc123.ui.nabu.casa", prefs: .init(remoteEnabled: true)
    )))
    let adopted = NabuCasaRemoteAccessDetector.adoptableRemoteURL(from: outcome, learnedOver: .local)
    #expect(adopted?.absoluteString == "https://abc123.ui.nabu.casa")
}

@Test func aURLShapedRemoteDomainIsRejectedRatherThanRepaired() {
    // HA's contract for this field is "domain". A value carrying a scheme or a path means that
    // assumption has broken, and quietly stripping it would hide exactly the wire-shape surprise
    // this codebase has been bitten by three times. Rejecting surfaces it as `.indeterminate`,
    // which is visible — and guarantees `https://https://…` can never be constructed.
    for domain in [
        "https://abc123.ui.nabu.casa",
        "http://abc123.ui.nabu.casa",
        "abc123.ui.nabu.casa/",
        "abc123.ui.nabu.casa/lovelace",
        "abc 123.ui.nabu.casa",
    ] {
        #expect(NabuCasaRemoteAccessDetector.remoteURL(fromDomain: domain) == nil,
                "expected \(domain) to be rejected as not a bare domain")
    }
}

@Test func remoteURLTrimsSurroundingWhitespace() {
    #expect(NabuCasaRemoteAccessDetector.remoteURL(fromDomain: "  abc123.ui.nabu.casa \n")?
        .absoluteString == "https://abc123.ui.nabu.casa")
}

// MARK: - The trust binding

@Test func aCloudStatusObtainedOverARemoteConnectionDoesNotUpdateTheStoredRemoteURL() {
    // **The security property.** Byte-identical input to
    // `theDerivedURLSurvivesTheAdoptionPathWithoutGainingASecondScheme` above; only the class of
    // the connection it was learned over differs, and that alone rejects it. A remote connection
    // can never nominate a new host — and the remote candidate is precisely the one
    // `TokenProvider` would later POST the refresh token to. Discovery flows inward only.
    let outcome = NabuCasaRemoteAccessDetector.classify(.success(HACloudStatus(
        loggedIn: true, activeSubscription: true,
        remoteDomain: "abc123.ui.nabu.casa", remoteConnected: true, prefs: .init(remoteEnabled: true)
    )))
    // The *classification* is unchanged — the UI may honestly say remote access exists...
    #expect(outcome == .remoteAvailable(URL(string: "https://abc123.ui.nabu.casa")!))
    // ...but nothing is adopted.
    #expect(NabuCasaRemoteAccessDetector.adoptableRemoteURL(from: outcome, learnedOver: .remote) == nil)
    #expect(NabuCasaRemoteAccessDetector.adoptableRemoteURL(from: outcome, learnedOver: .local)
            == URL(string: "https://abc123.ui.nabu.casa"))
}

@Test func noOutcomeOtherThanRemoteAvailableEverYieldsAURLToAdopt() {
    // There is exactly one source of an adoptable URL. Asserted over every other case so a future
    // case can't quietly acquire one.
    let others: [NabuCasaRemoteAccess] = [
        .remoteDisabled(domain: "abc123.ui.nabu.casa"),
        .remoteDisabled(domain: nil),
        .noSubscription,
        .cloudNotLoaded,
        .notLoggedIn,
        .indeterminate,
    ]
    for outcome in others {
        #expect(NabuCasaRemoteAccessDetector.adoptableRemoteURL(from: outcome, learnedOver: .local) == nil)
        #expect(NabuCasaRemoteAccessDetector.adoptableRemoteURL(from: outcome, learnedOver: .remote) == nil)
    }
}

// MARK: - remote_allow_remote_enable

@Test func enablingRemoteAccessIsAlwaysPermittedFromALocalConnection() {
    // The preference only ever restricts enabling *from a remote connection*, and HavenApp only
    // ever offers it from a local one — so this is the branch that actually runs in practice.
    let restrictive = HACloudStatus(prefs: .init(remoteAllowRemoteEnable: false))
    #expect(NabuCasaRemoteAccessDetector.canEnableRemoteAccess(restrictive, over: .local))
}

@Test func enablingRemoteAccessIsRefusedFromARemoteConnectionWhenThePreferenceForbidsIt() {
    let restrictive = HACloudStatus(prefs: .init(remoteAllowRemoteEnable: false))
    #expect(!NabuCasaRemoteAccessDetector.canEnableRemoteAccess(restrictive, over: .remote))
}

@Test func anAbsentAllowRemoteEnablePreferenceIsPermissive() {
    // Absent is not `false` here either. Withholding an offer on a key we never saw would be the
    // same confident-claim-from-a-missing-field mistake, pointed the other way.
    #expect(NabuCasaRemoteAccessDetector.canEnableRemoteAccess(HACloudStatus(), over: .remote))
    #expect(NabuCasaRemoteAccessDetector.canEnableRemoteAccess(
        HACloudStatus(prefs: .init()), over: .remote))
    #expect(NabuCasaRemoteAccessDetector.canEnableRemoteAccess(
        HACloudStatus(prefs: .init(remoteAllowRemoteEnable: true)), over: .remote))
}

@Test func theAllowRemoteEnablePreferenceDoesNotChangeTheClassification() {
    // It is a permission on Task 3's *offer*, not a fact about the account. Folding it into
    // `classify` would make `.remoteDisabled` mean two different things.
    let status = HACloudStatus(
        loggedIn: true, activeSubscription: true, remoteDomain: "abc123.ui.nabu.casa",
        prefs: .init(remoteEnabled: false, remoteAllowRemoteEnable: false)
    )
    #expect(NabuCasaRemoteAccessDetector.classify(.success(status))
            == .remoteDisabled(domain: "abc123.ui.nabu.casa"))
}
