import Testing
import Foundation
@testable import HavenCore

/// The guided-install flow, exercised as a state machine. `App/` has no test target, so every
/// claim of the form "after X the next step is Y" has to be executable here or it isn't verified
/// at all — which is exactly how a previous fix in this codebase shipped incomplete.
@Suite struct HavenOnboardingFlowTests {
    private let ourName = HavenIntegrationDetector.hacsRepositoryFullName
    private let probeFailed = WSError(code: "unknown_command", message: "havenapp/info not registered")

    private func readyInfo(capabilities: [String] = ["config.v1"], schemaVersion: Int = 1, admin: Bool = true) -> HavenIntegrationInfo {
        HavenIntegrationInfo(integrationVersion: "0.1.0", schemaVersion: schemaVersion, capabilities: capabilities, haUserIsAdmin: admin)
    }
    private func repo(installed: Bool, id: String = "42") -> HACSRepository {
        HACSRepository(id: id, fullName: ourName, installed: installed)
    }
    private func step(
        _ status: HavenIntegrationStatus,
        repository: HACSRepository? = nil,
        completed: Set<HavenOnboardingAction> = [],
        configFlowHandoffFailed: Bool = false
    ) -> HavenOnboardingStep {
        HavenOnboardingFlow.nextStep(
            status: status,
            ourRepository: repository,
            completed: completed,
            configFlowHandoffFailed: configFlowHandoffFailed
        )
    }

    // MARK: - Every verdict maps to exactly one step

    @Test func readyIsDone() {
        #expect(step(.ready(readyInfo())) == .done)
    }

    @Test func hacsMissingLinksOutRatherThanOfferingAnInstall() {
        let s = step(.hacsMissing)
        #expect(s == .installHACS)
        // Not automatable: no mutating call may hide behind this step.
        #expect(s.mutation == nil)
    }

    @Test func needsInstallWithNoHACSEntryAddsTheRepositoryFirst() {
        #expect(step(.needsInstall, repository: nil) == .addRepository)
    }

    @Test func needsInstallWithAKnownHACSEntryDownloadsByThatEntrysID() {
        // The id must come from HACS's answer, never be assumed — `hacs/repository/download`
        // takes HACS's own id, and a guessed one is a silent failure.
        #expect(step(.needsInstall, repository: repo(installed: false, id: "1296269"))
                == .downloadRepository(repositoryID: "1296269"))
    }

    @Test func needsConfigEntryOnAColdArrivalOffersTheConfigFlow() {
        #expect(step(.needsConfigEntry, repository: repo(installed: true)) == .addConfigEntry)
    }

    @Test func needsUpdateNamesTheMissingCapabilities() {
        #expect(step(.needsUpdate(missingCapabilities: ["config.v2"]))
                == .updateIntegration(missingCapabilities: ["config.v2"]))
    }

    @Test func appTooOldIsTerminalAndSaysNothingAboutTheIntegration() {
        let s = step(.appTooOld(schemaVersion: 7))
        #expect(s == .updateApp(schemaVersion: 7))
        #expect(s.isTerminal)
        let p = s.presentation()
        #expect(p.actionLabel == nil)
        // Telling the user to update an already-newer integration would be actively wrong.
        #expect(!p.explanation.lowercased().contains("hacs"))
    }

    @Test func indeterminateBecomesADiagnosticNotARemediation() {
        let s = step(.indeterminate)
        #expect(s == .diagnostic(.indeterminateComponents))
        let p = s.presentation()
        #expect(p.intent == .reprobe)
        // It must own the problem rather than send the user off to change something.
        #expect(p.explanation.contains("problem with Haven"))
        #expect(p.actionLabel == nil)
    }

    @Test func disconnectedBecomesADiagnosticThatDoesNotBlameHaven() {
        // I-3 (final whole-branch review): probing over a dead socket must not produce the same
        // "this is a problem with Haven… please report it" copy as a genuine decoding surprise —
        // that's confidently wrong for a plain dropped Wi-Fi connection.
        let s = step(.disconnected)
        #expect(s == .diagnostic(.disconnected))
        let p = s.presentation()
        #expect(p.intent == .reprobe)
        #expect(!p.explanation.lowercased().contains("problem with haven"))
        #expect(!p.explanation.lowercased().contains("please report"))
        #expect(p.actionLabel == nil)
    }

    @Test func commandsUnregisteredCarriesTheUnderlyingErrorIntoTheDiagnostic() {
        let s = step(.commandsUnregistered(probeFailed))
        #expect(s == .diagnostic(.commandsUnregistered(probeFailed)))
        #expect(s.presentation().explanation.contains("unknown_command"))
    }

    // MARK: - Permissions: never show instructions the user cannot perform

    @Test func notAdminShowsNoInstallInstructionsAtAll() {
        let s = step(.notAdmin)
        #expect(s == .notAdmin)
        let p = s.presentation()
        #expect(p.actionLabel == nil)
        #expect(p.intent == .none)
        #expect(s.mutation == nil)
        // `.notAdmin` means everything *is* already installed and answering, so any trace of the
        // install path here would be both wrong and unfollowable. (It may of course say the
        // integration *is* installed — that's the reassurance, not an instruction.)
        let text = (p.title + p.explanation).lowercased()
        #expect(!text.contains("hacs"))
        #expect(!text.contains("download"))
        #expect(!text.contains("devices & services"))
        #expect(text.contains("installed and working"))
    }

    @Test func blockedByNonAdminNamesTheBlockedStepButOffersNoActionToTakeIt() {
        for remediation: HavenIntegrationRemediation in [.hacsMissing, .needsInstall, .needsConfigEntry] {
            let s = step(.blockedByNonAdmin(remediation))
            #expect(s == .adminRequired(remediation))
            let p = s.presentation()
            // Explains *what* an admin must do…
            #expect(!p.explanation.isEmpty)
            #expect(p.explanation.contains("administrator"))
            // …while structurally offering this user nothing to tap, and no mutation.
            #expect(p.actionLabel == nil)
            #expect(p.intent == .none)
            #expect(s.mutation == nil)
        }
    }

    @Test func adminRequiredNamesADifferentBlockedStepForEachRemediation() {
        // Guards the two collapsing into one vague message.
        let texts = [HavenIntegrationRemediation.hacsMissing, .needsInstall, .needsConfigEntry]
            .map { HavenOnboardingStep.adminRequired($0).presentation().explanation }
        #expect(Set(texts).count == 3)
        #expect(HavenOnboardingStep.notAdmin.presentation().explanation != texts[0])
    }

    // MARK: - The install chain, as an executable sequence

    @Test func theFullInstallChainAdvancesOnlyOnAFreshProbe() {
        var flow = HavenOnboardingFlow()
        #expect(flow.step == .probing)
        #expect(!flow.needsGuidance)

        // 1. HACS is loaded, havenapp isn't, HACS has never heard of us.
        flow.apply(HavenOnboardingProbe(components: ["hacs", "light"], info: .failure(probeFailed),
                                        hacsRepositories: [], isAdmin: true))
        #expect(flow.step == .addRepository)
        #expect(flow.needsGuidance)

        // 2. We added it. HACS now lists it — but `installed` is still false.
        flow.recordAttempt(.addedRepositoryToHACS)
        flow.apply(HavenOnboardingProbe(components: ["hacs", "light"], info: .failure(probeFailed),
                                        hacsRepositories: [repo(installed: false, id: "42")], isAdmin: true))
        #expect(flow.step == .downloadRepository(repositoryID: "42"))
        #expect(!flow.lastAttemptDidNotLand)

        // 3. Downloaded. The files exist, but the running Home Assistant hasn't loaded them, so
        //    the config flow can't be offered yet — restart comes next, not the deep link.
        flow.recordAttempt(.downloadedRepository)
        flow.apply(HavenOnboardingProbe(components: ["hacs", "light"], info: .failure(probeFailed),
                                        hacsRepositories: [repo(installed: true, id: "42")], isAdmin: true))
        #expect(flow.step == .restartHomeAssistant)

        // 4. Restarted, HA came back, still no config entry — now the deep link.
        flow.recordAttempt(.restartedHomeAssistant)
        flow.apply(HavenOnboardingProbe(components: ["hacs", "light"], info: .failure(probeFailed),
                                        hacsRepositories: [repo(installed: true, id: "42")], isAdmin: true))
        #expect(flow.step == .addConfigEntry)

        // 5. Config entry added: havenapp/info finally answers.
        flow.recordAttempt(.openedConfigFlow)
        flow.apply(HavenOnboardingProbe(components: ["hacs", "havenapp", "light"], info: .success(readyInfo())))
        #expect(flow.step == .done)
        #expect(!flow.needsGuidance)
    }

    @Test func afterASuccessfulDownloadTheNextStepIsTheRestart() {
        #expect(step(.needsConfigEntry, repository: repo(installed: true), completed: [.downloadedRepository])
                == .restartHomeAssistant)
    }

    @Test func afterTheRestartTheNextStepIsTheConfigEntry() {
        #expect(step(.needsConfigEntry, repository: repo(installed: true),
                     completed: [.downloadedRepository, .restartedHomeAssistant]) == .addConfigEntry)
    }

    @Test func aConfigFlowThatKeepsNotLandingEscalatesToARestartRatherThanLoopingOnTheDeepLink() {
        // The cold-arrival gap: files downloaded in some earlier session, Home Assistant never
        // restarted since. The deep link cannot work, so repeating it forever is a dead end.
        var flow = HavenOnboardingFlow()
        let stuck = HavenOnboardingProbe(components: ["hacs"], info: .failure(probeFailed),
                                         hacsRepositories: [repo(installed: true)], isAdmin: true)
        flow.apply(stuck)
        #expect(flow.step == .addConfigEntry)
        flow.recordAttempt(.openedConfigFlow)

        // First contradicting probe: they may simply not have finished the wizard yet. Ask, don't
        // escalate — the escalation is a restart, and a restart takes their whole home offline.
        flow.apply(stuck)
        #expect(flow.step == .addConfigEntry)
        #expect(flow.lastAttemptDidNotLand)

        // Still stuck on a second look: now the likeliest explanation really is an unrestarted
        // Home Assistant, so offer the restart.
        flow.apply(stuck)
        #expect(flow.step == .restartHomeAssistant)
    }

    @Test func openingTheConfigFlowDoesNotByItselfArmTheRestartEscalation() {
        // Guards the specific misfire: tap "Open Home Assistant", get bounced out of the app, come
        // back and hit "Check again" before finishing the form. That user has an unfinished
        // wizard, not a Home Assistant that needs restarting — and must not be shown a
        // home-goes-offline prompt for it.
        #expect(step(.needsConfigEntry, repository: repo(installed: true),
                     completed: [.openedConfigFlow], configFlowHandoffFailed: false) == .addConfigEntry)
        #expect(step(.needsConfigEntry, repository: repo(installed: true),
                     completed: [.openedConfigFlow], configFlowHandoffFailed: true) == .restartHomeAssistant)
    }

    @Test func aStepThatDidNotLandIsReportedRatherThanAdvancedPast() {
        var flow = HavenOnboardingFlow()
        flow.apply(HavenOnboardingProbe(components: ["hacs"], info: .failure(probeFailed),
                                        hacsRepositories: [], isAdmin: true))
        #expect(flow.step == .addRepository)
        // We "added" it, but HACS still doesn't list it.
        flow.recordAttempt(.addedRepositoryToHACS)
        flow.apply(HavenOnboardingProbe(components: ["hacs"], info: .failure(probeFailed),
                                        hacsRepositories: [], isAdmin: true))
        #expect(flow.step == .addRepository)
        #expect(flow.lastAttemptDidNotLand)
        #expect(flow.step.presentation(didNotLand: true).didNotLandHint != nil)
        // And the hint clears once it does land.
        flow.apply(HavenOnboardingProbe(components: ["hacs"], info: .failure(probeFailed),
                                        hacsRepositories: [repo(installed: false)], isAdmin: true))
        #expect(!flow.lastAttemptDidNotLand)
    }

    @Test func issuingARestartSuspendsProbingUntilHomeAssistantIsBack() {
        // Restarting drops the socket, so every question asked in that window fails — and a failed
        // `get_config` classifies as `.indeterminate`, which would put a "Haven couldn't tell
        // what's installed" diagnostic on screen at the exact moment setup is going right. The
        // flag is what tells callers to wait for the reconnect instead of probing into the void;
        // it is also the only honest confirmation available that the restart happened, since the
        // service call's own success only means Home Assistant accepted it.
        var flow = HavenOnboardingFlow()
        flow.apply(HavenOnboardingProbe(components: ["hacs"], info: .failure(probeFailed),
                                        hacsRepositories: [repo(installed: true)],
                                        isAdmin: true))
        flow.recordAttempt(.downloadedRepository)
        flow.apply(HavenOnboardingProbe(components: ["hacs"], info: .failure(probeFailed),
                                        hacsRepositories: [repo(installed: true)], isAdmin: true))
        #expect(flow.step == .restartHomeAssistant)
        #expect(!flow.isAwaitingRestart)

        flow.recordAttempt(.restartedHomeAssistant)
        #expect(flow.isAwaitingRestart)
        // Still on the restart step — nothing advanced on the strength of the call succeeding.
        #expect(flow.step == .restartHomeAssistant)

        flow.apply(HavenOnboardingProbe(components: ["hacs"], info: .failure(probeFailed),
                                        hacsRepositories: [repo(installed: true)], isAdmin: true))
        #expect(!flow.isAwaitingRestart)
        #expect(flow.step == .addConfigEntry)
    }

    @Test func onlyTheRestartSuspendsProbing() {
        var flow = HavenOnboardingFlow()
        for action: HavenOnboardingAction in [.addedRepositoryToHACS, .downloadedRepository, .openedConfigFlow, .openedHACS, .openedHACSDocs] {
            flow.recordAttempt(action)
            #expect(!flow.isAwaitingRestart)
        }
    }

    @Test func nothingAdvancesWithoutAProbe() {
        // `recordAttempt` alone must never move the flow — the whole "guide and verify" principle
        // rests on the step only changing when a fresh probe says the world changed.
        var flow = HavenOnboardingFlow()
        flow.apply(HavenOnboardingProbe(components: ["hacs"], info: .failure(probeFailed),
                                        hacsRepositories: [], isAdmin: true))
        let before = flow.step
        flow.recordAttempt(.addedRepositoryToHACS)
        flow.recordAttempt(.downloadedRepository)
        flow.recordAttempt(.restartedHomeAssistant)
        #expect(flow.step == before)
    }

    // MARK: - Confirmation gating

    /// Exhaustive over every step that can perform a mutation: if a step can change something on
    /// the user's Home Assistant, its primary intent must be a confirmation carrying that same
    /// mutation. This is the rule that keeps a future step from quietly acquiring a side effect.
    @Test func mutatingStepsAlwaysRequireConfirmationOfTheSameMutation() {
        let allSteps: [HavenOnboardingStep] = [
            .probing, .done, .installHACS, .addRepository, .downloadRepository(repositoryID: "7"),
            .restartHomeAssistant, .addConfigEntry, .updateIntegration(missingCapabilities: ["config.v1"]),
            .updateApp(schemaVersion: 2), .adminRequired(.needsInstall), .notAdmin,
            .diagnostic(.indeterminateComponents), .diagnostic(.commandsUnregistered(probeFailed)),
            .diagnostic(.disconnected),
        ]
        for s in allSteps {
            guard let mutation = s.mutation else {
                // A non-mutating step must not be able to reach a mutation through its intent
                // either — that would be the same hole by another route.
                if case .confirmMutation = s.presentation().intent {
                    Issue.record("non-mutating step \(s) offers a mutation through its intent")
                }
                continue
            }
            guard case .confirmMutation(let confirmed, let confirmation) = s.presentation().intent else {
                Issue.record("mutating step \(s) is not gated behind a confirmation")
                continue
            }
            #expect(confirmed == mutation)
            #expect(!confirmation.message.isEmpty)
            #expect(!confirmation.confirmLabel.isEmpty)
        }
    }

    /// Extends the invariant above to Task 3's mutation (`cloud/remote/connect`) rather than
    /// writing a second, differently-shaped check for it. `NabuCasaRemoteAccessOffer` is a sibling
    /// to `HavenOnboardingStep` — it is keyed on `NabuCasaRemoteAccessDetector.classify`, not
    /// `HavenIntegrationDetector.classify`, so it cannot join the `allSteps` array above — but it
    /// reuses the exact same confirmation type (`HavenOnboardingConfirmation`), and the property
    /// being asserted is identical: the mutating call is unreachable without a confirmation naming
    /// it, present exactly when the call would actually be allowed to run.
    @Test func theRemoteAccessOfferMutationIsAlsoAlwaysGatedBehindConfirmation() {
        let enableable = NabuCasaRemoteAccessOffer(domain: "abc123.ui.nabu.casa", canEnable: true)
        guard let confirmation = enableable.confirmation else {
            Issue.record("an enable-able offer must carry a confirmation"); return
        }
        #expect(!confirmation.message.isEmpty)
        #expect(!confirmation.confirmLabel.isEmpty)

        // The mirror: when Home Assistant would refuse the call outright
        // (`remote_allow_remote_enable == false`), there must be no confirmation to tap through —
        // the same hole `mutatingStepsAlwaysRequireConfirmationOfTheSameMutation` guards against,
        // reached from the other direction (no confirmation ⇒ no path to the mutation at all,
        // rather than a confirmation that lies about what will happen).
        let refused = NabuCasaRemoteAccessOffer(domain: "abc123.ui.nabu.casa", canEnable: false)
        #expect(refused.confirmation == nil)
    }

    @Test func theRestartConfirmationWarnsThatTheHomeGoesOffline() {
        guard case .confirmMutation(_, let confirmation) = HavenOnboardingStep.restartHomeAssistant.presentation().intent else {
            Issue.record("the restart must be confirmed"); return
        }
        #expect(confirmation.message.lowercased().contains("offline"))
        #expect(confirmation.isDestructive)
    }

    @Test func theAddRepositoryConfirmationNamesTheRepositoryAndSaysNothingIsDownloadedYet() {
        guard case .confirmMutation(let mutation, let confirmation) = HavenOnboardingStep.addRepository.presentation().intent else {
            Issue.record("adding a custom repository writes to HACS's own config and must be confirmed"); return
        }
        #expect(mutation == .addRepositoryToHACS(fullName: ourName, category: "integration"))
        #expect(confirmation.message.contains(ourName))
        #expect(confirmation.message.lowercased().contains("no files are downloaded"))
    }

    @Test func theDownloadConfirmationCarriesTheIDFromTheStepItself() {
        guard case .confirmMutation(let mutation, _) = HavenOnboardingStep.downloadRepository(repositoryID: "1296269").presentation().intent else {
            Issue.record("the download must be confirmed"); return
        }
        #expect(mutation == .downloadRepository(repositoryID: "1296269"))
    }

    // MARK: - Handoffs

    @Test func theConfigEntryStepUsesTheMyHomeAssistantRedirectAndNeverDrivesTheFlowItself() {
        guard case .openLink(let url, let records) = HavenOnboardingStep.addConfigEntry.presentation().intent else {
            Issue.record("the config entry is a handoff, not an automated call"); return
        }
        #expect(url == URL(string: "https://my.home-assistant.io/redirect/config_flow_start/?domain=havenapp"))
        #expect(records == .openedConfigFlow)
        #expect(HavenOnboardingStep.addConfigEntry.mutation == nil)
    }

    @Test func theHACSPanelLinkNamesOurRepository() {
        #expect(HavenOnboardingLinks.hacsRepository.absoluteString
                == "https://my.home-assistant.io/redirect/hacs_repository/?owner=timmead&repository=hacs-havenapp&category=integration")
    }

    @Test func everyHandoffLinkIsHTTPS() {
        for url in [HavenOnboardingLinks.configFlowStart, HavenOnboardingLinks.hacsRepository, HavenOnboardingLinks.hacsDocs] {
            #expect(url.scheme == "https")
        }
    }

    // MARK: - Probe assembly

    /// Runs a real `probeHavenIntegration()` over a fake socket with canned answers, and reports
    /// both the probe and the command names that actually went out — the conditionals inside
    /// `probeHavenIntegration` are the one piece of I/O-shaped logic in this feature, so asserting
    /// on a hand-built `HavenOnboardingProbe` would test nothing about them.
    private func runProbe(answers: [String: String]) async throws -> (probe: HavenOnboardingProbe, sentTypes: [String]) {
        let conn = FakeWebSocketConnection()
        let client = HAWebSocketClient(connection: conn)
        await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
        await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
        try await client.authenticate(token: "t")
        await conn.setOnSend { data in
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let id = obj?["id"] as? Int, let type = obj?["type"] as? String, type != "auth" else { return }
            if let body = answers[type] {
                await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":\#(body)}"#)
            } else {
                await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":false,"error":{"code":"unknown_command","message":"nope"}}"#)
            }
        }
        let probe = await HomeConnection(client: client).probeHavenIntegration()
        let types = await conn.sent.compactMap {
            ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["type"] as? String
        }
        return (probe, types)
    }

    @Test func aWorkingInstanceIsNeverAskedAboutHACSOrAboutAdminRights() async throws {
        // `classify` ignores both inputs once `havenapp/info` has answered, so asking would be
        // pure noise on a healthy instance — and onboarding poking at someone's HACS store for no
        // reason is exactly the kind of thing this feature must not do.
        let (probe, sent) = try await runProbe(answers: [
            "get_config": #"{"components":["hacs","havenapp","light"]}"#,
            "havenapp/info": #"{"integration_version":"0.1.0","schema_version":1,"capabilities":["config.v1"],"ha_user_is_admin":true}"#,
        ])
        #expect(probe.status == .ready(readyInfo()))
        #expect(!sent.contains { $0.hasPrefix("hacs/") })
        #expect(!sent.contains("auth/current_user"))
    }

    @Test func aFailedProbeOnAnInstanceWithHACSAsksHACSAndAboutAdminRights() async throws {
        let (probe, sent) = try await runProbe(answers: [
            "get_config": #"{"components":["hacs","light"]}"#,
            "hacs/repositories/list": #"[{"id":"42","full_name":"timmead/hacs-havenapp","installed":false}]"#,
            "auth/current_user": #"{"is_admin":true}"#,
        ])
        #expect(sent.contains("hacs/repositories/list"))
        #expect(sent.contains("auth/current_user"))
        #expect(probe.isAdmin == true)
        #expect(probe.ourRepository?.id == "42")
        #expect(probe.status == .needsInstall)
    }

    @Test func aFailedProbeOnAnInstanceWithoutHACSSkipsTheHACSQuery() async throws {
        let (probe, sent) = try await runProbe(answers: [
            "get_config": #"{"components":["light"]}"#,
            "auth/current_user": #"{"is_admin":false}"#,
        ])
        #expect(!sent.contains { $0.hasPrefix("hacs/") })
        #expect(probe.status == .blockedByNonAdmin(.hacsMissing))
    }

    @Test func probeHavenIntegrationTreatsATransportFailureAsDisconnectedNotIndeterminate() async throws {
        // I-3 (final whole-branch review): the socket dying before get_config's result ever
        // arrives must not be told to the user as "this is a problem with Haven… please report
        // it" — that's `.indeterminate`'s copy, reserved for a genuine decoding-shape surprise.
        // `disconnect()` fails every request in flight with `WSError(code: "closed", ...)` — not
        // a `DecodingError` — which is exactly the signal `probeHavenIntegration` looks for.
        let conn = FakeWebSocketConnection()
        let client = HAWebSocketClient(connection: conn)
        await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
        await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
        try await client.authenticate(token: "t")
        await conn.setOnSend { _ in await client.disconnect() }

        let probe = await HomeConnection(client: client).probeHavenIntegration()

        #expect(probe.components == nil)
        #expect(probe.transportFailed)
        #expect(probe.status == .disconnected)
    }

    @Test func aNonAdminIsNeverWalkedThroughAnInstall() {
        var flow = HavenOnboardingFlow()
        flow.apply(HavenOnboardingProbe(components: ["hacs"], info: .failure(probeFailed),
                                        hacsRepositories: [], isAdmin: false))
        #expect(flow.step == .adminRequired(.needsInstall))
        #expect(flow.step.mutation == nil)
        #expect(flow.step.presentation().actionLabel == nil)
    }
}
