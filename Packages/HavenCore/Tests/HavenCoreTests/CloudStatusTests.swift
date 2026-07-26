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

// MARK: - Task 3: the one-tap offer

@Test func cloudRemoteConnectEmitsTheExactCommandNameHomeAssistantRegisters() throws {
    // Same discipline as `cloud/status`'s own test: a typo here answers `unknown_command`, which
    // is indistinguishable at the wire level from "the cloud component isn't loaded" — so getting
    // this string wrong would silently break the enable button for every subscriber.
    let data = WSCommand.cloudRemoteConnect(id: 3)
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(obj["type"] as? String == "cloud/remote/connect")
    #expect(obj["id"] as? Int == 3)
}

@Test func enableNabuCasaRemoteAccessSendsTheCommandAndReturnsSuccess() async throws {
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["id"] as? Int, obj?["type"] as? String == "cloud/remote/connect" else { return }
        await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":{}}"#)
    }
    let home = HomeConnection(client: client)
    let result = await home.enableNabuCasaRemoteAccess()
    guard case .success = result else {
        Issue.record("expected success, got \(result)"); return
    }
}

@Test func enableNabuCasaRemoteAccessSurfacesAHomeAssistantErrorRatherThanThrowing() async throws {
    // The failed-call path: never thrown, folded into the same `Result<Void, WSError>` shape as
    // every other mutating call, so the caller can show HA's own message verbatim.
    let conn = FakeWebSocketConnection()
    let client = HAWebSocketClient(connection: conn)
    await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
    await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
    try await client.authenticate(token: "t")
    await conn.setOnSend { data in
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = obj?["id"] as? Int, obj?["type"] as? String == "cloud/remote/connect" else { return }
        await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":false,"error":{"code":"not_found","message":"cloud not enabled"}}"#)
    }
    let home = HomeConnection(client: client)
    let result = await home.enableNabuCasaRemoteAccess()
    guard case .failure(let error) = result else {
        Issue.record("expected failure, got \(result)"); return
    }
    #expect(error == WSError(code: "not_found", message: "cloud not enabled"))
}

@Test func remoteDisabledTriggersTheOffer() {
    // **The test this task exists for.** `.remoteDisabled` is the only classification that
    // produces an offer at all.
    let status = HACloudStatus(
        loggedIn: true, activeSubscription: true,
        remoteDomain: "abc123.ui.nabu.casa", prefs: .init(remoteEnabled: false)
    )
    let offer = NabuCasaRemoteAccessDetector.offer(from: .success(status), over: .local)
    #expect(offer?.domain == "abc123.ui.nabu.casa")
    #expect(offer?.canEnable == true)
}

@Test func remoteAvailableDoesNotTriggerTheOffer() {
    // The mirror: a tunnel that is already switched on (regardless of `remote_connected`) must
    // never be offered a "fix" — see `CloudStatusTests`' own distinction tests above for why.
    let status = HACloudStatus(
        loggedIn: true, activeSubscription: true,
        remoteDomain: "abc123.ui.nabu.casa", remoteConnected: false, prefs: .init(remoteEnabled: true)
    )
    #expect(NabuCasaRemoteAccessDetector.offer(from: .success(status), over: .local) == nil)
}

@Test func noOtherOutcomeEverTriggersTheOffer() {
    // Asserted over every other case so a future one can't quietly acquire an offer, mirroring
    // `noOutcomeOtherThanRemoteAvailableEverYieldsAURLToAdopt` above.
    let noSubscription = HACloudStatus(loggedIn: true, activeSubscription: false)
    let cloudNotLoaded: Result<HACloudStatus, WSError> = .failure(WSError(code: "unknown_command", message: "x"))
    let notLoggedIn = HACloudStatus(loggedIn: false)
    let indeterminate = HACloudStatus(loggedIn: true, activeSubscription: nil)
    let transportFailure: Result<HACloudStatus, WSError> = .failure(WSError(code: "probe_failed", message: "x"))
    for result in [
        Result<HACloudStatus, WSError>.success(noSubscription),
        cloudNotLoaded,
        .success(notLoggedIn),
        .success(indeterminate),
        transportFailure,
    ] {
        #expect(NabuCasaRemoteAccessDetector.offer(from: result, over: .local) == nil)
        #expect(NabuCasaRemoteAccessDetector.offer(from: result, over: .remote) == nil)
    }
}

@Test func theOfferConfirmationNamesExactlyWhatWillChange() {
    let offer = NabuCasaRemoteAccessOffer(domain: "abc123.ui.nabu.casa", canEnable: true)
    guard let confirmation = offer.confirmation else {
        Issue.record("an enable-able offer must carry a confirmation"); return
    }
    #expect(confirmation.message.contains("Nabu Casa"))
    #expect(confirmation.message.contains("abc123.ui.nabu.casa"))
    #expect(!confirmation.confirmLabel.isEmpty)
}

@Test func aMissingDomainStillProducesAConfirmationWithNoDomainClause() {
    // Mirrors `remoteDisabledIsStillReportedWhenNoDomainWasGiven`: the offer's trigger is the
    // preference alone, and a missing domain must not make the confirmation say something false.
    let offer = NabuCasaRemoteAccessOffer(domain: nil, canEnable: true)
    let confirmation = offer.confirmation
    #expect(confirmation != nil)
    #expect(confirmation?.message.contains(" at ") == false)
}

@Test func remoteAllowRemoteEnableFalseIsExplainedRatherThanOpaque() {
    // **The test this half of the task exists for.** When Home Assistant would refuse the call
    // outright, there must be no confirmation to tap through at all — not a button that leads to
    // an opaque failure — and the explanation must say why.
    let status = HACloudStatus(
        loggedIn: true, activeSubscription: true, remoteDomain: "abc123.ui.nabu.casa",
        prefs: .init(remoteEnabled: false, remoteAllowRemoteEnable: false)
    )
    let offer = NabuCasaRemoteAccessDetector.offer(from: .success(status), over: .remote)
    #expect(offer?.canEnable == false)
    #expect(offer?.confirmation == nil)
    #expect(offer?.explanation.isEmpty == false)
}

// The "mutation is unreachable without confirmation" invariant for this offer is asserted in
// `HavenOnboardingFlowTests.theRemoteAccessOfferMutationIsAlsoAlwaysGatedBehindConfirmation`,
// alongside (and as an explicit extension of) the equivalent check for `HavenOnboardingStep`.

@Test func evaluateEnableAttemptSucceedsWhenTheReprobeShowsRemoteAvailable() {
    // Success is re-probed, never assumed from the call returning.
    let reprobe = HACloudStatus(
        loggedIn: true, activeSubscription: true,
        remoteDomain: "abc123.ui.nabu.casa", prefs: .init(remoteEnabled: true)
    )
    let outcome = NabuCasaRemoteAccessDetector.evaluateEnableAttempt(reprobe: .success(reprobe))
    #expect(outcome == .succeeded(URL(string: "https://abc123.ui.nabu.casa")!))
}

@Test func evaluateEnableAttemptDoesNotTakeEffectWhenTheReprobeStillShowsItDisabled() {
    let reprobe = HACloudStatus(
        loggedIn: true, activeSubscription: true,
        remoteDomain: "abc123.ui.nabu.casa", prefs: .init(remoteEnabled: false)
    )
    let outcome = NabuCasaRemoteAccessDetector.evaluateEnableAttempt(reprobe: .success(reprobe))
    #expect(outcome == .didNotTakeEffect(message: NabuCasaRemoteAccessDetector.remoteAccessDidNotTakeEffectMessage))
}

@Test func evaluateEnableAttemptDoesNotTakeEffectWhenTheReprobeIsIndeterminateOrFails() {
    // A dropped socket or an unreadable reply right after the mutating call is not evidence of
    // success either — the same "didn't take effect" message covers it, rather than a confident
    // claim we can't support.
    let indeterminate = HACloudStatus(loggedIn: true, activeSubscription: nil)
    #expect(NabuCasaRemoteAccessDetector.evaluateEnableAttempt(reprobe: .success(indeterminate))
            == .didNotTakeEffect(message: NabuCasaRemoteAccessDetector.remoteAccessDidNotTakeEffectMessage))
    let failed: Result<HACloudStatus, WSError> = .failure(WSError(code: "probe_failed", message: "x"))
    #expect(NabuCasaRemoteAccessDetector.evaluateEnableAttempt(reprobe: failed)
            == .didNotTakeEffect(message: NabuCasaRemoteAccessDetector.remoteAccessDidNotTakeEffectMessage))
}

// MARK: - Review M-4: a lapsed Nabu Casa URL must be able to leave the slot
//
// Nothing ever cleared `discoveredExternalURL` except a sign-in/sign-out, so a subscription that
// lapses leaves a dead `*.ui.nabu.casa` URL in it forever — ordered *ahead* of the user's custom
// remote URL, so someone who then sets up their own reverse proxy pays a connect deadline against a
// tunnel that will never answer, on every connect away from home, with no way to remove it.

@Suite struct SupersededRemoteURLTests {
    private func url(_ s: String) -> URL { URL(string: s)! }
    private let nabuCasa = URL(string: "https://abc123.ui.nabu.casa")!

    @Test func aLapsedSubscriptionSupersedesTheStoredNabuCasaURL() {
        #expect(NabuCasaRemoteAccessDetector.storedRemoteURLIsSuperseded(
            nabuCasa, by: .noSubscription, learnedOver: .local))
        #expect(NabuCasaRemoteAccessDetector.storedRemoteURLIsSuperseded(
            nabuCasa, by: .notLoggedIn, learnedOver: .local))
    }

    @Test func anAbsenceOfEvidenceIsNotEvidenceTheTunnelIsGone() {
        // `.indeterminate` is what a transport blip classifies as. Deleting a working remote address
        // because one probe failed would strand the user the next time they leave home — the exact
        // failure this codebase keeps producing, pointed the other way.
        #expect(!NabuCasaRemoteAccessDetector.storedRemoteURLIsSuperseded(
            nabuCasa, by: .indeterminate, learnedOver: .local))
        // `.cloudNotLoaded` says the component isn't loaded *now*; it is also what a mistyped
        // command name would produce (see `cloudStatusEmitsTheExactCommandNameHomeAssistantRegisters`).
        #expect(!NabuCasaRemoteAccessDetector.storedRemoteURLIsSuperseded(
            nabuCasa, by: .cloudNotLoaded, learnedOver: .local))
        #expect(!NabuCasaRemoteAccessDetector.storedRemoteURLIsSuperseded(
            nabuCasa, by: .remoteDisabled(domain: "abc123.ui.nabu.casa"), learnedOver: .local))
        #expect(!NabuCasaRemoteAccessDetector.storedRemoteURLIsSuperseded(
            nabuCasa, by: .remoteAvailable(nabuCasa), learnedOver: .local))
    }

    @Test func aSelfHostedExternalURLInTheSameSlotIsNotDestroyed() {
        // The slot's *other* occupant: `get_config`'s `external_url`, written first, belonging to a
        // user whose HA has the cloud component loaded but no subscription — precisely the
        // `.noSubscription` user. Their reverse proxy is not evidence about anybody's cloud account.
        #expect(!NabuCasaRemoteAccessDetector.storedRemoteURLIsSuperseded(
            url("https://ha.example.com"), by: .noSubscription, learnedOver: .local))
        #expect(!NabuCasaRemoteAccessDetector.storedRemoteURLIsSuperseded(
            url("https://ha.example.com"), by: .notLoggedIn, learnedOver: .local))
    }

    @Test func aRemoteConnectionStillGetsNoSayInWhatWeRemember() {
        // This one only ever *deletes*, so it is the safe direction — but the rule stays symmetric,
        // because one sentence is easier to keep true than two.
        #expect(!NabuCasaRemoteAccessDetector.storedRemoteURLIsSuperseded(
            nabuCasa, by: .noSubscription, learnedOver: .remote))
        #expect(!NabuCasaRemoteAccessDetector.storedRemoteURLIsSuperseded(
            nabuCasa, by: .notLoggedIn, learnedOver: .remote))
    }

    @Test func nothingStoredIsNothingToSupersede() {
        #expect(!NabuCasaRemoteAccessDetector.storedRemoteURLIsSuperseded(
            nil, by: .noSubscription, learnedOver: .local))
    }
}

// MARK: - Review I-2: the four non-Nabu-Casa outcomes have copy, and it is honest
//
// `.cloudNotLoaded`, `.notLoggedIn`, `.noSubscription` and `.indeterminate` were classified,
// documented and unit-tested — and rendered nowhere in the app. Design §3's outcomes 3 and 4.

@Suite struct CustomRemoteURLGuidanceTests {
    @Test func everyOutcomeThatRoutesToTheCustomURLPathHasCopy() {
        for outcome: NabuCasaRemoteAccess in [.cloudNotLoaded, .notLoggedIn, .noSubscription, .indeterminate] {
            #expect(outcome.customRemoteURLGuidance != nil)
        }
    }

    @Test func theTwoNabuCasaOutcomesSayNothingHere() {
        // `.remoteAvailable` needs no guidance; `.remoteDisabled` is Task 3's offer, which owns its
        // own copy — a second explanation beside it would be two voices on one screen.
        #expect(NabuCasaRemoteAccess.remoteAvailable(URL(string: "https://abc123.ui.nabu.casa")!).customRemoteURLGuidance == nil)
        #expect(NabuCasaRemoteAccess.remoteDisabled(domain: nil).customRemoteURLGuidance == nil)
    }

    @Test func theSelfHostedUserIsNotToldTheyNeedASubscription() {
        // `.cloudNotLoaded` is the ordinary self-hosted user, per design §3 outcome 4 — not an
        // error, and not a sales pitch. Someone whose Tailscale setup already works must not read
        // this as "you need Nabu Casa".
        let copy = NabuCasaRemoteAccess.cloudNotLoaded.customRemoteURLGuidance
        #expect(copy?.contains("normal") == true)
        #expect(copy?.lowercased().contains("subscription") == false)
    }

    @Test func theIndeterminateCopyClaimsNothingAboutTheAccount() {
        // The distinction Task 2's report asked for: `.indeterminate` means we failed to establish
        // anything, so the copy must not imply the user has (or lacks) a subscription or an account.
        let copy = NabuCasaRemoteAccess.indeterminate.customRemoteURLGuidance
        #expect(copy?.contains("couldn't tell") == true)
        #expect(copy?.lowercased().contains("doesn't have") == false)
        #expect(copy?.lowercased().contains("isn't signed in") == false)
    }
}
