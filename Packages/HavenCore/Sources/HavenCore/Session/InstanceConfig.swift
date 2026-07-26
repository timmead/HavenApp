import Foundation

/// A subset of Home Assistant's `get_config` WebSocket command result — just the fields
/// HavenApp needs to discover how to reach the instance from outside the LAN. HA's real payload
/// carries many more fields (components, version, unit_system, ...) that we don't decode.
///
/// Either URL may be absent: `internal_url` is unset unless the user has configured one under
/// Settings > System > Network, and `external_url` is unset unless remote access (Nabu Casa
/// cloud, or a self-hosted reverse proxy) is configured and enabled.
public struct HAInstanceConfig: Sendable, Equatable, Decodable {
    public let internalURL: URL?
    public let externalURL: URL?

    private enum CodingKeys: String, CodingKey {
        case internalURL = "internal_url"
        case externalURL = "external_url"
    }

    public init(internalURL: URL?, externalURL: URL?) {
        self.internalURL = internalURL
        self.externalURL = externalURL
    }
}
