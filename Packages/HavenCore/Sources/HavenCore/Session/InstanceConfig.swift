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

    /// Every component HA currently has loaded — e.g. `"hacs"`, `"havenapp"`. This is onboarding's
    /// detector for the `havenapp` integration (`HavenIntegrationDetector.classify`): a custom
    /// integration only appears here once a config entry has set it up, which is exactly the
    /// signal needed to tell "not installed" apart from "installed but commands not registered."
    /// Defaults to `[]` — via the custom `init(from:)` below, not a synthesized decode — so a
    /// payload from before this field existed (or any other caller that never mentions it, like
    /// every existing `fetchInstanceConfig` test fixture) still decodes instead of throwing a
    /// missing-key error.
    public let components: [String]

    private enum CodingKeys: String, CodingKey {
        case internalURL = "internal_url"
        case externalURL = "external_url"
        case components
    }

    public init(internalURL: URL?, externalURL: URL?, components: [String] = []) {
        self.internalURL = internalURL
        self.externalURL = externalURL
        self.components = components
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        internalURL = try container.decodeIfPresent(URL.self, forKey: .internalURL)
        externalURL = try container.decodeIfPresent(URL.self, forKey: .externalURL)
        components = try container.decodeIfPresent([String].self, forKey: .components) ?? []
    }
}
