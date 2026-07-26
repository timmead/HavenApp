import Foundation
import Network

/// Extracts the peer's resolved IP literal from an `NWPath.remoteEndpoint`.
///
/// Split out of `NWWebSocketConnection` on purpose: this is the half of peer classification that
/// depends on Network.framework's endpoint shapes, and it is where a wrong assumption would be
/// invisible. The other half — the private-range test — is `ConnectionClass.observed(peerAddress:)`,
/// a pure function over the string this returns. Both halves are unit-tested, because between them
/// they decide whether a connection is trusted.
public enum PeerEndpointAddress {
    /// - Returns: The peer's address as an IP literal (`"192.168.1.10"`, `"fe80::1%en0"`), or `nil`
    ///   when the endpoint carries no resolved address. `nil` is a real answer, not an error:
    ///   `ConnectionClass.observed(peerAddress:)` maps it to `.remote`, which is the fail-closed
    ///   side.
    ///
    /// `NWPath.remoteEndpoint` **does** resolve names to addresses once the connection is `.ready`
    /// — verified in `NWWebSocketConnectionTests` against an in-process loopback listener, dialled
    /// by name and by `.url(…)` (the form `NWWebSocketConnection` uses), both of which report
    /// `::1`. That is worth a test rather than a comment: if names came back unresolved instead,
    /// every connection would classify `.remote`, nothing would ever be adopted, and the symptom
    /// would be "remote access never works" with no error anywhere — the same silent shape as the
    /// `purgeDiscoveredURLs` trap, one layer down.
    public static func address(of endpoint: NWEndpoint?) -> String? {
        guard let endpoint, case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        // An unresolved name. Not classifiable, so the caller fails closed.
        case .name: return nil
        @unknown default: return nil
        }
    }
}
