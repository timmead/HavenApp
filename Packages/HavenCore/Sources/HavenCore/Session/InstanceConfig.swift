import Foundation

/// A subset of Home Assistant's `get_config` WebSocket command result — just the fields
/// HavenApp needs to discover how to reach the instance from outside the LAN, plus `components`
/// (see below). HA's real payload carries many more fields (version, unit_system, ...) that we
/// don't decode.
///
/// Either URL may be absent: `internal_url` is unset unless the user has configured one under
/// Settings > System > Network, and `external_url` is unset unless remote access (Nabu Casa
/// cloud, or a self-hosted reverse proxy) is configured and enabled.
public struct HAInstanceConfig: Sendable, Equatable, Decodable {
    public let internalURL: URL?
    public let externalURL: URL?

    /// Every component HA currently has loaded — e.g. `"hacs"`, `"havenapp"` — or `nil` if
    /// `get_config`'s response didn't include the key at all (or it failed to decode as a string
    /// array). This is onboarding's detector for the `havenapp` integration
    /// (`HavenIntegrationDetector.classify`): a custom integration only appears here once a
    /// config entry has set it up, which is exactly the signal needed to tell "not installed"
    /// apart from "installed but commands not registered."
    ///
    /// Deliberately `[String]?`, not defaulted to `[]`: this exact wire shape has never been
    /// verified against a live `get_config` response (see `HomeConnection.fetchInstanceConfig`'s
    /// logging), so "the key was missing/unparseable" must stay distinguishable from "HA
    /// genuinely reported zero loaded components" — itself an absurd result in practice, since HA
    /// always has some components loaded. Collapsing either of those into an empty array here
    /// would let `HavenIntegrationDetector.classify` treat a broken decoding assumption as proof
    /// nothing is installed, and confidently walk a correctly-configured user through installing
    /// HACS. See `HavenIntegrationStatus.indeterminate`, which is exactly the outcome this
    /// preserves the information to produce. The memberwise initializer below defaults this to
    /// `nil` for the same reason — "not provided" is the honest default, not "empty."
    public let components: [String]?

    private enum CodingKeys: String, CodingKey {
        case internalURL = "internal_url"
        case externalURL = "external_url"
        case components
    }

    public init(internalURL: URL?, externalURL: URL?, components: [String]? = nil) {
        self.internalURL = internalURL
        self.externalURL = externalURL
        self.components = components
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        internalURL = try container.decodeIfPresent(URL.self, forKey: .internalURL)
        externalURL = try container.decodeIfPresent(URL.self, forKey: .externalURL)
        // No `?? []` here — see the property's documentation for why a missing key must remain
        // `nil`, not silently become an empty (and therefore indistinguishable-from-"confirmed
        // empty") array.
        components = try container.decodeIfPresent([String].self, forKey: .components)
    }
}
