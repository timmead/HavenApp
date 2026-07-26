import Testing
import Foundation
@testable import HavenCore

/// Every test here exercises `HavenIntegrationDetector.classify` directly — the pure function the
/// onboarding brief (ON-1) requires the entire havenapp-detection decision to live in, since
/// `App/` has no test target of its own. Table row numbers below refer to the detection table in
/// `.superpowers/overnight/onboarding-brief.md`.
@Suite struct HavenIntegrationDetectorTests {
    private func readyInfo(
        capabilities: [String] = ["config.v1"],
        schemaVersion: Int = 1,
        admin: Bool = true,
        integrationVersion: String = "0.1.0"
    ) -> HavenIntegrationInfo {
        HavenIntegrationInfo(
            integrationVersion: integrationVersion,
            schemaVersion: schemaVersion,
            capabilities: capabilities,
            haUserIsAdmin: admin
        )
    }

    // MARK: - Table row 1 — havenapp loaded, havenapp/info ok

    @Test func row1LoadedAndInfoOKYieldsReady() {
        let info = readyInfo()
        let status = HavenIntegrationDetector.classify(
            components: ["hacs", "havenapp"],
            infoResult: .success(info)
        )
        #expect(status == .ready(info))
    }

    @Test func readyDoesNotRequireHACSToBeLoaded() {
        // A manually-installed havenapp (no HACS involved at all) is just as ready. Note: the
        // success branch doesn't actually consult `components` at all (see
        // `indeterminateIsNeverReachedWhenTheProbeItselfSucceeded` for the property this really
        // rests on) — this test's `components` value is incidental, not load-bearing.
        let info = readyInfo()
        let status = HavenIntegrationDetector.classify(components: ["havenapp"], infoResult: .success(info))
        #expect(status == .ready(info))
    }

    // MARK: - Table row 2 — loaded but commands unregistered ("shouldn't happen")

    @Test func row2LoadedButInfoFailsYieldsCommandsUnregisteredWithDiagnosticPreserved() {
        let error = WSError(code: "unknown_command", message: "havenapp/info not registered")
        let status = HavenIntegrationDetector.classify(
            components: ["havenapp"],
            infoResult: .failure(error)
        )
        #expect(status == .commandsUnregistered(error))
    }

    @Test func commandsUnregisteredIgnoresTheErrorCodeItself() {
        // classify must never sniff the error's `code` for meaning — only whether it failed at
        // all, given `havenapp` is already confirmed loaded via `components`. Any error code
        // here, however unrelated-looking, produces the same case.
        let error = WSError(code: "version_conflict", message: "irrelevant to this branch")
        let status = HavenIntegrationDetector.classify(components: ["havenapp"], infoResult: .failure(error))
        #expect(status == .commandsUnregistered(error))
    }

    // MARK: - Table row 3 — HACS present, havenapp absent (ambiguous without the HACS repo list)

    @Test func row3aRepoListedAsDownloadedYieldsNeedsConfigEntry() {
        let status = HavenIntegrationDetector.classify(
            components: ["hacs"],
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a")),
            hacsRepositories: ["timmead/hacs-havenapp"]
        )
        #expect(status == .needsConfigEntry)
    }

    @Test func row3bRepoNotListedYieldsNeedsInstall() {
        let status = HavenIntegrationDetector.classify(
            components: ["hacs"],
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a")),
            hacsRepositories: ["someone/unrelated-repo"]
        )
        #expect(status == .needsInstall)
    }

    @Test func row3cNoAnswerFromHACSIsTreatedTheSameAsNotDownloaded() {
        // hacsRepositories == nil means "no answer from HACS at all" (query failed, or was
        // skipped) — must default to the conservative .needsInstall, never .needsConfigEntry.
        let status = HavenIntegrationDetector.classify(
            components: ["hacs"],
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a")),
            hacsRepositories: nil
        )
        #expect(status == .needsInstall)
    }

    @Test func repoComparisonIsCaseInsensitive() {
        // GitHub's owner/repo addressing is itself case-insensitive.
        let status = HavenIntegrationDetector.classify(
            components: ["hacs"],
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a")),
            hacsRepositories: ["TimMead/HACS-HavenApp"]
        )
        #expect(status == .needsConfigEntry)
    }

    // MARK: - Table row 4 — HACS itself missing

    @Test func row4NeitherLoadedYieldsHACSMissing() {
        let status = HavenIntegrationDetector.classify(
            components: ["light", "sensor"],
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a"))
        )
        #expect(status == .hacsMissing)
    }

    @Test func hacsMissingEvenWhenARepoListIsSomehowSupplied() {
        // hacsRepositories is meaningless without HACS itself loaded (a genuine, non-empty
        // components list here); must not accidentally produce .needsConfigEntry or .needsInstall.
        let status = HavenIntegrationDetector.classify(
            components: ["light", "sensor"],
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a")),
            hacsRepositories: ["timmead/hacs-havenapp"]
        )
        #expect(status == .hacsMissing)
    }

    // MARK: - Coordinator follow-up: components missing/empty must never be read as "confirmed
    // nothing installed"
    //
    // `HAInstanceConfig.components` decodes to `nil` if `get_config`'s response never included the
    // key — a real possibility, since this exact wire shape has never been verified against a live
    // instance. Defaulting that to `[]` and letting `classify` fall through the same path as a
    // genuinely-empty list would make a broken decoding assumption indistinguishable from "nothing
    // is installed," and the app would confidently walk a fully-configured user through installing
    // HACS. `.indeterminate` exists so that failure mode surfaces as an honest diagnostic instead.

    @Test func nilComponentsYieldsIndeterminateNeverHACSMissing() {
        let status = HavenIntegrationDetector.classify(
            components: nil,
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a"))
        )
        #expect(status == .indeterminate)
    }

    @Test func emptyComponentsIsTreatedIdenticallyToNil() {
        // A real HA instance never reports zero loaded components — an empty list here is exactly
        // as untrustworthy as a missing key, not proof of anything.
        let status = HavenIntegrationDetector.classify(
            components: [],
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a")),
            hacsRepositories: ["timmead/hacs-havenapp"]
        )
        #expect(status == .indeterminate)
    }

    @Test func indeterminateIsNeverReachedWhenTheProbeItselfSucceeded() {
        // A successful havenapp/info is positive, direct proof — stronger than components — so it
        // must win outright even if components came back nil/empty/malformed.
        let info = readyInfo()
        let status = HavenIntegrationDetector.classify(components: nil, infoResult: .success(info))
        #expect(status == .ready(info))
    }

    @Test func aRealNonEmptyListWithoutHavenappButWithHACSIsUnaffectedByTheIndeterminateChange() {
        // Sanity check that the fix didn't change behavior for the actual "ambiguous, needs HACS
        // disambiguation" row — only nil/[] changed meaning.
        let status = HavenIntegrationDetector.classify(
            components: ["hacs", "light"],
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a")),
            hacsRepositories: ["timmead/hacs-havenapp"]
        )
        #expect(status == .needsConfigEntry)
    }

    // MARK: - Coordinator follow-up: non-admin detected pre-`havenapp/info` via auth/current_user
    //
    // `ha_user_is_admin` only exists once `havenapp/info` has succeeded. The three branches below
    // never get that far — `havenapp` isn't even loaded — so without a separate signal, a
    // non-admin household member would be walked through an admin-only HACS/HA step (installing
    // HACS itself, adding our custom repository, or completing its config flow) they cannot
    // finish. `isAdmin` (sourced from HA's stock `auth/current_user`, independent of havenapp)
    // closes that gap. `nil` must reproduce today's behavior exactly — the fallback always fails
    // toward *showing* the remediation, never hiding it, since withholding it from someone who
    // could actually act (a caller that simply didn't query admin status) would be strictly worse
    // than the non-admin annoyance this exists to prevent.

    @Test func nonAdminBlockedFromNeedsInstall() {
        let status = HavenIntegrationDetector.classify(
            components: ["hacs"],
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a")),
            hacsRepositories: ["someone/unrelated-repo"],
            isAdmin: false
        )
        #expect(status == .blockedByNonAdmin(.needsInstall))
    }

    @Test func nonAdminBlockedFromNeedsConfigEntry() {
        let status = HavenIntegrationDetector.classify(
            components: ["hacs"],
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a")),
            hacsRepositories: ["timmead/hacs-havenapp"],
            isAdmin: false
        )
        #expect(status == .blockedByNonAdmin(.needsConfigEntry))
    }

    @Test func nonAdminBlockedFromHACSMissing() {
        let status = HavenIntegrationDetector.classify(
            components: ["light", "sensor"],
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a")),
            isAdmin: false
        )
        #expect(status == .blockedByNonAdmin(.hacsMissing))
    }

    @Test func isAdminNilReproducesTodaysBehaviorForNeedsInstall() {
        let status = HavenIntegrationDetector.classify(
            components: ["hacs"],
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a")),
            hacsRepositories: ["someone/unrelated-repo"],
            isAdmin: nil
        )
        #expect(status == .needsInstall)
    }

    @Test func isAdminNilReproducesTodaysBehaviorForNeedsConfigEntry() {
        let status = HavenIntegrationDetector.classify(
            components: ["hacs"],
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a")),
            hacsRepositories: ["timmead/hacs-havenapp"],
            isAdmin: nil
        )
        #expect(status == .needsConfigEntry)
    }

    @Test func isAdminNilReproducesTodaysBehaviorForHACSMissing() {
        let status = HavenIntegrationDetector.classify(
            components: ["light", "sensor"],
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a")),
            isAdmin: nil
        )
        #expect(status == .hacsMissing)
    }

    @Test func adminTrueLeavesNeedsInstallNeedsConfigEntryAndHACSMissingUnchanged() {
        #expect(HavenIntegrationDetector.classify(
            components: ["hacs"],
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a")),
            hacsRepositories: ["someone/unrelated-repo"],
            isAdmin: true
        ) == .needsInstall)

        #expect(HavenIntegrationDetector.classify(
            components: ["hacs"],
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a")),
            hacsRepositories: ["timmead/hacs-havenapp"],
            isAdmin: true
        ) == .needsConfigEntry)

        #expect(HavenIntegrationDetector.classify(
            components: ["light", "sensor"],
            infoResult: .failure(WSError(code: "unknown_command", message: "n/a")),
            isAdmin: true
        ) == .hacsMissing)
    }

    @Test func postInfoNotAdminPathIsUnaffectedByTheIsAdminParameter() {
        // `notAdmin` (once `havenapp/info` succeeded) is decided from `info.haUserIsAdmin` alone;
        // `isAdmin` — a pre-info signal — must not override or interact with it either way.
        let info = readyInfo(admin: false)
        let ignoredEvenTrue = HavenIntegrationDetector.classify(
            components: ["havenapp"], infoResult: .success(info), isAdmin: true
        )
        #expect(ignoredEvenTrue == .notAdmin)

        let ignoredEvenFalse = HavenIntegrationDetector.classify(
            components: ["havenapp"], infoResult: .success(info), isAdmin: false
        )
        #expect(ignoredEvenFalse == .notAdmin)
    }

    // MARK: - Brief extras: forward-compatible capabilities

    @Test func unknownFutureCapabilityAlongsideRequiredOnesStillYieldsReady() {
        let info = readyInfo(capabilities: ["config.v1", "some.future.capability.v7"])
        let status = HavenIntegrationDetector.classify(components: ["havenapp"], infoResult: .success(info))
        #expect(status == .ready(info))
    }

    // MARK: - Brief extras: required capability absent

    @Test func missingRequiredCapabilityYieldsNeedsUpdate() {
        let info = readyInfo(capabilities: ["some.other.capability"])
        let status = HavenIntegrationDetector.classify(components: ["havenapp"], infoResult: .success(info))
        #expect(status == .needsUpdate(missingCapabilities: ["config.v1"]))
    }

    @Test func entirelyEmptyCapabilitiesListYieldsNeedsUpdate() {
        let info = readyInfo(capabilities: [])
        let status = HavenIntegrationDetector.classify(components: ["havenapp"], infoResult: .success(info))
        #expect(status == .needsUpdate(missingCapabilities: ["config.v1"]))
    }

    // MARK: - Brief extras: schema_version higher than the client's

    @Test func newerSchemaVersionYieldsAppTooOldDistinctFromNeedsUpdate() {
        let info = readyInfo(schemaVersion: 2)
        let status = HavenIntegrationDetector.classify(components: ["havenapp"], infoResult: .success(info))
        #expect(status == .appTooOld(schemaVersion: 2))
    }

    @Test func appTooOldTakesPrecedenceOverAMissingCapability() {
        // A schema the app can't even parse correctly is a more fundamental blocker than a
        // missing capability string — the two are never conflated into the same case.
        let info = readyInfo(capabilities: [], schemaVersion: 2)
        let status = HavenIntegrationDetector.classify(components: ["havenapp"], infoResult: .success(info))
        #expect(status == .appTooOld(schemaVersion: 2))
    }

    // MARK: - Brief extras: integration_version "unknown" must not affect the verdict

    @Test func unknownIntegrationVersionDoesNotAffectTheVerdict() {
        let info = readyInfo(integrationVersion: "unknown")
        let status = HavenIntegrationDetector.classify(components: ["havenapp"], infoResult: .success(info))
        #expect(status == .ready(info))
    }

    // MARK: - Brief extras: non-admin

    @Test func nonAdminYieldsNotAdminOnlyAfterEveryOtherGatePasses() {
        let info = readyInfo(admin: false)
        let status = HavenIntegrationDetector.classify(components: ["havenapp"], infoResult: .success(info))
        #expect(status == .notAdmin)
    }

    @Test func nonAdminDoesNotMaskAMoreFundamentalSchemaOrCapabilityProblem() {
        // Precedence check: schema_version and capabilities are gated before admin status, since
        // fixing those isn't something any user (admin or not) can do from inside onboarding.
        let tooOld = readyInfo(schemaVersion: 2, admin: false)
        #expect(HavenIntegrationDetector.classify(components: ["havenapp"], infoResult: .success(tooOld))
                == .appTooOld(schemaVersion: 2))

        let missingCap = readyInfo(capabilities: [], admin: false)
        #expect(HavenIntegrationDetector.classify(components: ["havenapp"], infoResult: .success(missingCap))
                == .needsUpdate(missingCapabilities: ["config.v1"]))
    }

    // MARK: - The requirement declaration itself

    @Test func requiredCapabilitiesAndMinSchemaVersionAreExactlyWhatTheBriefSpecifies() {
        #expect(HavenIntegrationDetector.requiredCapabilities == ["config.v1"])
        #expect(HavenIntegrationDetector.minSchemaVersion == 1)
    }
}
