import Foundation

/// One entry from HACS's `hacs/repositories/list` result — the subset of fields onboarding needs.
///
/// The critical thing about this command is that it lists **every repository HACS knows about**,
/// not only the downloaded ones. The moment `hacs/repositories/add` succeeds, our repository
/// appears here with `installed == false`. Treating mere membership as "downloaded" would send a
/// user to the config-flow deep link before any files exist on disk — a link that cannot work.
/// So the two questions this type answers are deliberately kept apart everywhere it is used:
///
/// - *Which repository do I download?* → `HACSRepositoryIndex.match(fullName:in:)` over the raw
///   list, which must include not-yet-installed entries (that's the whole point of the step).
/// - *Is ours already downloaded?* → `HACSRepositoryIndex.downloadedFullNames(in:)`, which is what
///   `HavenIntegrationDetector.classify` takes, and which filters on `installed`.
///
/// Field shapes verified against HACS's own websocket serialization, not assumed.
public struct HACSRepository: Sendable, Equatable, Decodable {
    /// HACS's own identifier, and the only thing `hacs/repository/download` accepts as its
    /// `repository` parameter. Serialized by HACS as a string, but decoded leniently from a JSON
    /// number too (see `init(from:)`) — the value is numeric-looking, so a representation change
    /// there is a plausible break that would otherwise fail the *entire* list decode.
    public let id: String
    /// The GitHub `owner/repo` string, e.g. `timmead/hacs-havenapp`. Required, not optional:
    /// an entry we cannot name is an entry we cannot match, so a wire-shape change here must
    /// fail loudly at the decode rather than quietly produce a list nothing ever matches.
    public let fullName: String
    public let name: String?
    /// Whether HACS has actually downloaded this repository's files. Required for the same reason
    /// `fullName` is, and deliberately *not* defaulted to `false`: a default would make "HACS
    /// changed this field's name" indistinguishable from "HACS says it isn't downloaded," and the
    /// second is a fact onboarding acts on. Failing the decode instead surfaces as a `nil`
    /// repository list, which `classify` already documents as "treat as not downloaded" — the
    /// same conservative outcome, but logged rather than silent.
    public let installed: Bool
    public let installedVersion: String?
    public let availableVersion: String?
    public let category: String?
    /// The HA integration domain the repository provides (`"havenapp"` for ours), when HACS knows
    /// it. Informational — matching is done on `fullName`, which is stable across renames of the
    /// integration's internal domain.
    public let domain: String?
    public let canDownload: Bool?

    public init(
        id: String,
        fullName: String,
        name: String? = nil,
        installed: Bool,
        installedVersion: String? = nil,
        availableVersion: String? = nil,
        category: String? = nil,
        domain: String? = nil,
        canDownload: Bool? = nil
    ) {
        self.id = id
        self.fullName = fullName
        self.name = name
        self.installed = installed
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.category = category
        self.domain = domain
        self.canDownload = canDownload
    }

    // Spelled out only because a custom `init(from:)` suppresses synthesis; the *names* are the
    // property names verbatim. Decoding goes through `HACoding.decoder`
    // (`.convertFromSnakeCase`), which maps `full_name` -> `fullName` etc. — none of these
    // collide under that conversion the way `HAInstanceConfig`'s `internal_url` does.
    private enum CodingKeys: String, CodingKey {
        case id, fullName, name, installed, installedVersion, availableVersion, category, domain, canDownload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // String-or-number tolerance for `id` only; every other field is taken at its declared
        // type so a real shape change still fails visibly.
        if let s = try? c.decode(String.self, forKey: .id) {
            id = s
        } else {
            id = String(try c.decode(Int.self, forKey: .id))
        }
        fullName = try c.decode(String.self, forKey: .fullName)
        installed = try c.decode(Bool.self, forKey: .installed)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        installedVersion = try c.decodeIfPresent(String.self, forKey: .installedVersion)
        availableVersion = try c.decodeIfPresent(String.self, forKey: .availableVersion)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        domain = try c.decodeIfPresent(String.self, forKey: .domain)
        canDownload = try c.decodeIfPresent(Bool.self, forKey: .canDownload)
    }
}

/// Pure lookups over a `hacs/repositories/list` result. Separate from the I/O below so the
/// full-name-to-id resolution the download step depends on is exercised by unit tests rather than
/// only by a live HACS.
public enum HACSRepositoryIndex {
    /// Our repository's entry, matched on `full_name` case-insensitively (GitHub's `owner/repo`
    /// is itself case-insensitive, and `HavenIntegrationDetector.classify` already compares this
    /// way). Returns the entry whether or not it is installed — the download step exists
    /// precisely for entries that are not.
    public static func match(fullName: String, in repositories: [HACSRepository]) -> HACSRepository? {
        repositories.first { $0.fullName.caseInsensitiveCompare(fullName) == .orderedSame }
    }

    /// Only the repositories HACS has actually downloaded. This — never the raw list — is what
    /// `HavenIntegrationDetector.classify` must be given, since its `hacsRepositories` parameter
    /// means "downloaded" and it does a plain membership test with no `installed` check of its
    /// own. See `HACSRepository`'s documentation for the failure this prevents.
    public static func downloadedFullNames(in repositories: [HACSRepository]) -> [String] {
        repositories.filter(\.installed).map(\.fullName)
    }
}

extension HomeConnection {
    /// Asks HACS what it knows about. Narrowed to the `integration` category — onboarding has no
    /// interest in themes/plugins, and a smaller answer is a cheaper one on an instance with a
    /// large HACS install.
    ///
    /// Read-only. Never throws, for the same reason `fetchIntegrationInfo` doesn't: callers fold
    /// a failure into "no answer from HACS," which `classify` documents as equivalent to "our
    /// repository isn't downloaded."
    public func fetchHACSRepositories(categories: [String]? = ["integration"]) async -> Result<[HACSRepository], WSError> {
        do {
            let v = try await client.request { WSCommand.hacsRepositoriesList(id: $0, categories: categories) }
            let data = try JSONEncoder().encode(v)
            return .success(try HACoding.decoder.decode([HACSRepository].self, from: data))
        } catch {
            // Same discipline as `fetchInstanceConfig`'s components warning: a decode failure here
            // is indistinguishable, downstream, from "HACS isn't installed" — so if our
            // assumption about HACS's list shape is wrong, it has to be visible here rather than
            // only as an onboarding flow that mysteriously always offers a fresh install.
            havenCoreLog.error("hacs/repositories/list failed or did not decode as [HACSRepository] — onboarding will treat our repository as not downloaded: \(String(describing: error), privacy: .public)")
            return .failure(Self.normalize(error))
        }
    }

    /// MUTATING. Registers our repository with HACS as a custom repository. Only ever called from
    /// `HavenOnboardingStep.addRepository`, which carries a confirmation naming exactly this.
    public func addHACSRepository(fullName: String, category: String) async -> Result<Void, WSError> {
        do {
            _ = try await client.request { WSCommand.hacsRepositoriesAdd(id: $0, repository: fullName, category: category) }
            return .success(())
        } catch {
            return .failure(Self.normalize(error))
        }
    }

    /// MUTATING. Downloads a repository's files onto the Home Assistant host. `repositoryID` is
    /// HACS's own id, read back from `fetchHACSRepositories` — never our `owner/repo` name.
    public func downloadHACSRepository(repositoryID: String, version: String? = nil) async -> Result<Void, WSError> {
        do {
            _ = try await client.request { WSCommand.hacsRepositoryDownload(id: $0, repository: repositoryID, version: version) }
            return .success(())
        } catch {
            return .failure(Self.normalize(error))
        }
    }

    /// MUTATING, and the most disruptive thing this app can do: it takes the user's whole home
    /// offline for as long as Home Assistant takes to come back. Only ever called from
    /// `HavenOnboardingStep.restartHomeAssistant`, behind a confirmation that says so.
    ///
    /// A `.success` here means only that HA accepted the service call — it is *not* evidence the
    /// restart happened, and nothing in this codebase treats it as such. See
    /// `HavenOnboardingFlow` for how the restart is confirmed transitively instead.
    public func restartHomeAssistant() async -> Result<Void, WSError> {
        do {
            _ = try await client.request { WSCommand.restartHomeAssistant(id: $0) }
            return .success(())
        } catch {
            return .failure(Self.normalize(error))
        }
    }

    /// The signed-in HA user's admin flag, from stock `auth/current_user`. Returns `nil` when the
    /// question could not be answered at all — which `HavenIntegrationDetector.classify`
    /// deliberately treats as "don't withhold the remediation," not as "not an admin."
    public func fetchCurrentUserIsAdmin() async -> Bool? {
        guard let v = try? await client.request({ WSCommand.currentUser(id: $0) }),
              let isAdmin = v.asObject?["is_admin"]?.asBool else { return nil }
        return isAdmin
    }
}
