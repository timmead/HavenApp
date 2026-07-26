import Foundation

/// The one place that decides what — out of a fresh `get_config` result, *or* whatever was
/// previously written to persisted storage, which is exactly as untrusted (see below) — is safe
/// to remember as a future connection candidate for this Home Assistant instance.
///
/// This exists so that decision is a pure function `AppModel` calls, not logic `AppModel`
/// reimplements inline — `AppModel` has no test target, so anything living only there is a claim
/// about behavior nobody actually exercises. Every test in `ConnectionEndpointTests` that
/// exercises this type runs against the exact code both `rememberDiscoveredURLs` (the write
/// boundary — a fresh `get_config` response) and `discoveredURLs` (the read boundary — whatever
/// is already sitting in `UserDefaults`, possibly written by an older, less careful build) call.
///
/// ## Why `internal_url` is not in the result at all
///
/// An earlier fix round validated `external_url` (it must be a genuine `*.ui.nabu.casa` host —
/// see `ConnectionEndpoint.isNabuCasaHost`) but left `internal_url` completely unchecked. That
/// was the same vulnerability through the adjacent field: `get_config` returns both URLs from the
/// same MITM-able response, `internal_url` was classified `.local` for *any* non-Nabu-Casa host
/// with nothing requiring it to look like a private/LAN address, it was appended as a candidate
/// *ahead of* even the URL the user typed, and it was handed to `TokenProvider.setBaseURL()` —
/// so injecting `internal_url: https://evil.example` instead of `external_url` got an attacker a
/// *better* result than before that fix (tried first, not just tried at all).
///
/// The tempting-looking fix — "require `internal_url` to be a private/LAN address" — does not
/// work inside this threat model. A legitimate `internal_url` is routinely a bare hostname
/// (`homeassistant.local`, `hass.home.arpa`, a user's own domain) that cannot be classified as
/// private without a DNS lookup — and on the exact MITM'd LAN this whole threat model is about,
/// the DNS answer is the attacker's too. There is no validation to write here that isn't
/// "resolve an attacker-controlled name to decide whether to trust attacker-controlled data."
///
/// `internal_url` also has no consumer this app needs: local access is already served by the URL
/// the user typed (`ConnectionEndpoint.candidates`'s `userEntered` parameter), and remote access
/// by a validated `external_url`. So it is dropped unconditionally, not "validated" — there is no
/// value of `internal_url` this type will ever adopt.
public struct DiscoveredCandidateURLs: Sendable, Equatable {
    /// `nil` unless `rawExternalURL` was a genuine `*.ui.nabu.casa` host.
    public let externalURL: URL?

    public init(externalURL: URL?) {
        self.externalURL = externalURL
    }

    /// - Parameters:
    ///   - rawInternalURL: Whatever an untrusted source (the wire, or persisted storage) reports
    ///     as `internal_url`. Accepted only so "this is never adopted, no matter what it says" is
    ///     an assertion a test can make against this exact function, rather than a claim about
    ///     code with no test coverage — the result never depends on its value.
    ///   - rawExternalURL: Whatever an untrusted source reports as `external_url`. Kept only if
    ///     it is a genuine Nabu Casa host (`ConnectionEndpoint.isNabuCasaHost`); anything else —
    ///     including `nil` — yields a `nil` `externalURL`.
    public static func validating(rawInternalURL: URL?, rawExternalURL: URL?) -> DiscoveredCandidateURLs {
        _ = rawInternalURL // Deliberately unused — see the type-level doc for why.
        let external = rawExternalURL.flatMap { ConnectionEndpoint.isNabuCasaHost($0) ? $0 : nil }
        return DiscoveredCandidateURLs(externalURL: external)
    }
}
