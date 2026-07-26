import Testing
import Foundation
@testable import HavenCore

/// Two things are being guarded here, and they're the two ways the HACS integration can fail
/// silently rather than loudly:
///
/// 1. The **exact command names** on the wire. HACS's singular/plural split
///    (`hacs/repositories/list`, `hacs/repositories/add`, but `hacs/repository/download`) and the
///    add-takes-a-name / download-takes-an-id split are both easy to get wrong, and Home
///    Assistant answers a wrong command name with an error rather than doing anything — so a typo
///    here is a no-op the user experiences as "the button does nothing."
/// 2. The **installed-vs-known** distinction. `hacs/repositories/list` returns everything HACS has
///    heard of; conflating that with "downloaded" sends the user to a config-flow link for files
///    that don't exist.
@Suite struct HACSRepositoryTests {
    // MARK: - Wire shapes

    /// Drives a real `HomeConnection` over a fake socket and captures what actually went out, so
    /// these assertions are on emitted JSON rather than on a re-statement of the same constants.
    private func captureSentCommand(
        _ body: @Sendable (HomeConnection) async -> Void
    ) async throws -> [[String: Any]] {
        let conn = FakeWebSocketConnection()
        let client = HAWebSocketClient(connection: conn)
        await conn.enqueueIncoming(#"{"type":"auth_required"}"#)
        await conn.enqueueIncoming(#"{"type":"auth_ok"}"#)
        try await client.authenticate(token: "t")
        // Answer every request with an empty-array success so the caller's `await` returns and the
        // test doesn't hang; the *answer* is irrelevant here, only what was sent.
        await conn.setOnSend { data in
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let id = obj?["id"] as? Int, obj?["type"] as? String != "auth" else { return }
            await conn.enqueueIncoming(#"{"id":\#(id),"type":"result","success":true,"result":[]}"#)
        }
        await body(HomeConnection(client: client))
        return await conn.sent.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    @Test func repositoriesListUsesThePluralCommandAndNarrowsToIntegrations() async throws {
        let sent = try await captureSentCommand { _ = await $0.fetchHACSRepositories() }
        let cmd = try #require(sent.first { ($0["type"] as? String)?.hasPrefix("hacs/") == true })
        #expect(cmd["type"] as? String == "hacs/repositories/list")
        #expect(cmd["categories"] as? [String] == ["integration"])
    }

    @Test func repositoriesAddUsesThePluralCommandWithTheOwnerSlashRepoNameAndLowercaseCategory() async throws {
        let sent = try await captureSentCommand {
            _ = await $0.addHACSRepository(fullName: "timmead/hacs-havenapp", category: "integration")
        }
        let cmd = try #require(sent.first { ($0["type"] as? String)?.hasPrefix("hacs/") == true })
        #expect(cmd["type"] as? String == "hacs/repositories/add")
        // `repository` here is the GitHub full name — the opposite of the download command below.
        #expect(cmd["repository"] as? String == "timmead/hacs-havenapp")
        #expect(cmd["category"] as? String == "integration")
    }

    @Test func repositoryDownloadUsesTheSingularCommandWithHACSsOwnID() async throws {
        let sent = try await captureSentCommand { _ = await $0.downloadHACSRepository(repositoryID: "123456") }
        let cmd = try #require(sent.first { ($0["type"] as? String)?.hasPrefix("hacs/") == true })
        // Singular `repository/`, not `repositories/` — the whole reason this test exists.
        #expect(cmd["type"] as? String == "hacs/repository/download")
        // And `repository` is the id, not the owner/repo name.
        #expect(cmd["repository"] as? String == "123456")
        #expect(cmd["version"] == nil)
    }

    @Test func restartUsesHomeAssistantsOwnRestartServiceWithNoTarget() async throws {
        let sent = try await captureSentCommand { _ = await $0.restartHomeAssistant() }
        let cmd = try #require(sent.first { $0["type"] as? String == "call_service" })
        #expect(cmd["domain"] as? String == "homeassistant")
        #expect(cmd["service"] as? String == "restart")
        // A target would scope the restart to an entity, which is not a thing — it must be absent.
        #expect(cmd["target"] == nil)
    }

    // MARK: - Decoding

    private func decode(_ json: String) throws -> [HACSRepository] {
        try HACoding.decoder.decode([HACSRepository].self, from: Data(json.utf8))
    }

    @Test func decodesAListEntry() throws {
        let repos = try decode("""
        [{"id":"1296269","full_name":"timmead/hacs-havenapp","name":"Haven","installed":true,
          "installed_version":"0.1.0","available_version":"0.2.0","category":"integration",
          "domain":"havenapp","can_download":true}]
        """)
        #expect(repos.count == 1)
        #expect(repos[0].id == "1296269")
        #expect(repos[0].fullName == "timmead/hacs-havenapp")
        #expect(repos[0].installed)
        #expect(repos[0].availableVersion == "0.2.0")
    }

    @Test func decodesANumericIDAsAString() throws {
        // HACS serializes `id` as a string today; it is numeric-looking enough that a change to a
        // JSON number is a plausible break, and one that would otherwise fail the whole list.
        let repos = try decode(#"[{"id":1296269,"full_name":"a/b","installed":false}]"#)
        #expect(repos[0].id == "1296269")
    }

    @Test func aMissingInstalledFlagFailsTheDecodeRatherThanDefaultingToFalse() {
        // Deliberately strict: a silent `false` default would make "HACS renamed this field"
        // indistinguishable from "HACS says it isn't downloaded," and the second is a fact
        // onboarding acts on. Failing means the caller gets `nil` repositories, which `classify`
        // already documents as "treat as not downloaded" — the same conservative outcome, but
        // logged instead of invisible.
        #expect(throws: DecodingError.self) {
            _ = try decode(#"[{"id":"1","full_name":"a/b"}]"#)
        }
    }

    // MARK: - The installed-vs-known distinction

    private let known = HACSRepository(id: "99", fullName: "timmead/hacs-havenapp", installed: false)
    private let downloaded = HACSRepository(id: "99", fullName: "timmead/hacs-havenapp", installed: true)
    private let unrelated = HACSRepository(id: "1", fullName: "someone/other-thing", installed: true)

    @Test func matchFindsOurRepositoryEvenWhenItIsNotInstalled() {
        // The download step's entire purpose is a repository that is known but not installed, so
        // this lookup must not filter on `installed`.
        let found = HACSRepositoryIndex.match(fullName: "timmead/hacs-havenapp", in: [unrelated, known])
        #expect(found == known)
    }

    @Test func matchIsCaseInsensitiveLikeGitHubItself() {
        let found = HACSRepositoryIndex.match(fullName: "TimMead/HACS-HavenApp", in: [known])
        #expect(found == known)
    }

    @Test func downloadedFullNamesExcludesKnownButNotInstalledRepositories() {
        #expect(HACSRepositoryIndex.downloadedFullNames(in: [known, unrelated]) == ["someone/other-thing"])
        #expect(HACSRepositoryIndex.downloadedFullNames(in: [downloaded]) == ["timmead/hacs-havenapp"])
    }

    @Test func aRepositoryAddedButNotYetDownloadedStillClassifiesAsNeedsInstall() {
        // The regression this whole distinction exists for: the instant `hacs/repositories/add`
        // succeeds our repository appears in the list with `installed == false`. If that counted
        // as "downloaded", the verdict would jump to `.needsConfigEntry` and onboarding would send
        // the user to a config-flow deep link for files that are not on disk yet.
        let probe = HavenOnboardingProbe(
            components: ["hacs", "light"],
            info: .failure(WSError(code: "unknown_command", message: "not registered")),
            hacsRepositories: [known],
            isAdmin: true
        )
        #expect(probe.status == .needsInstall)
        #expect(probe.ourRepository == known)
    }

    @Test func aDownloadedRepositoryClassifiesAsNeedsConfigEntry() {
        let probe = HavenOnboardingProbe(
            components: ["hacs", "light"],
            info: .failure(WSError(code: "unknown_command", message: "not registered")),
            hacsRepositories: [downloaded],
            isAdmin: true
        )
        #expect(probe.status == .needsConfigEntry)
    }
}
