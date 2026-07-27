import Foundation

/// Turns whatever the user typed into a base URL for their Home Assistant, or explains why it
/// can't be one.
///
/// Pure and in HavenCore rather than inline in `AppModel.signIn`, because the previous inline
/// version was a validation gate that *looked* like it held and didn't, and nothing could catch
/// that: the app layer's logic was untested by construction.
///
/// ## The bug this replaces
///
/// The old normalizer asked "does this start with `http://` or `https://`?" and, if not, prepended
/// `http://` — **whatever else was already there**. So an input carrying a different or malformed
/// scheme was not rejected, it was rewritten into a new and entirely valid URL pointing somewhere
/// the user had never named:
///
/// | typed | became | host |
/// |---|---|---|
/// | `http//homeassistant.local` (missing colon) | `http://http//homeassistant.local` | `http` |
/// | `htp://homeassistant.local` (transposed) | `http://htp://homeassistant.local` | `htp` |
///
/// Both then satisfied the `scheme == "http" || scheme == "https"` guard that reads as though it
/// prevents exactly this. A dropped colon is an ordinary typo, and the result was a spinner
/// followed by an authentication attempt against a host that does not exist.
public enum ServerURL {
    public enum Invalid: Error, Equatable {
        case empty
        /// A scheme we can't talk to. Carries what they typed so the message can name it, rather
        /// than saying "invalid URL" about something the user can plainly see is a URL.
        case unsupportedScheme(String)
        /// `http//host` — a scheme with its colon dropped. Distinct from `unsupportedScheme`
        /// because the remedy is different and specific: they typed the right scheme.
        case malformedScheme(String)
        /// Parseable as a URL but with no host — `http://`, `http://:8123`.
        case noHost

        public var message: String {
            switch self {
            case .empty:
                return "Enter your Home Assistant address, like homeassistant.local:8123"
            case .unsupportedScheme(let scheme):
                return "Haven can't connect over \(scheme). Use http or https, like http://homeassistant.local:8123"
            case .malformedScheme(let scheme):
                return "That looks like it's missing a colon — did you mean \(scheme)://?"
            case .noHost:
                return "That address is missing a hostname. Try something like http://homeassistant.local:8123"
            }
        }
    }

    /// A scheme, recognised by the `//` that follows it rather than by the colon alone.
    ///
    /// The colon cannot be the signal, because RFC 3986 permits `.` and `-` inside a scheme name —
    /// so `homeassistant.local:8123` is indistinguishable from a scheme called
    /// `homeassistant.local` if you only look for `name:`. That is precisely the input the
    /// tolerance exists to accept. Requiring `://` separates the two cleanly: a port is digits
    /// after a colon, a scheme is followed by a double slash.
    private static let scheme = try! NSRegularExpression(
        pattern: "^([A-Za-z][A-Za-z0-9+.-]*)://", options: []
    )

    /// The same thing with the colon missing — `http//homeassistant.local`. Worth detecting
    /// separately because it is a common typo and, left alone, it is invisible: with no colon
    /// there is no scheme to reject, so it falls through to the tolerant branch and becomes
    /// `http://http//homeassistant.local`, a perfectly valid URL whose host is `http`.
    private static let schemeMissingColon = try! NSRegularExpression(
        pattern: "^([A-Za-z][A-Za-z0-9+.-]*)//", options: []
    )

    /// - Returns: the normalized URL, or why it can't be one.
    public static func normalize(_ typed: String) -> Result<URL, Invalid> {
        let raw = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .failure(.empty) }

        let range = NSRange(raw.startIndex..., in: raw)
        let candidate: String

        if let match = scheme.firstMatch(in: raw, options: [], range: range),
           let schemeRange = Range(match.range(at: 1), in: raw) {
            let name = raw[schemeRange].lowercased()
            guard name == "http" || name == "https" else {
                return .failure(.unsupportedScheme(String(raw[schemeRange])))
            }
            candidate = raw
        } else if let match = schemeMissingColon.firstMatch(in: raw, options: [], range: range),
                  let schemeRange = Range(match.range(at: 1), in: raw) {
            return .failure(.malformedScheme(String(raw[schemeRange])))
        } else {
            // No scheme — the case the tolerance exists for: "homeassistant.local:8123",
            // "192.168.1.10:8123", "ha:8123". The colon here introduces a port, not a scheme.
            candidate = "http://\(raw)"
        }

        guard let url = URL(string: candidate), let host = url.host(), !host.isEmpty else {
            return .failure(.noHost)
        }
        return .success(url)
    }
}
