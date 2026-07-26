import Foundation

/// The one place that decides what — out of a fresh `get_config` result, *or* whatever was
/// previously written to persisted storage, which is exactly as untrusted (see below) — is safe
/// to remember as a future connection candidate for this Home Assistant instance.
///
/// ## The answer is: nothing. Neither `internal_url` nor `external_url` is ever adopted.
///
/// Two fix rounds tried to auto-adopt `external_url` when it was "a genuine Nabu Casa host"
/// (`ConnectionEndpoint.isNabuCasaHost`, a suffix match on `.ui.nabu.casa`). That check proves the
/// *category* — this is *some* Nabu Casa instance — never the *identity* — that it is *this
/// user's* instance. Nabu Casa is a cheap, self-service consumer subscription: an attacker with
/// only a transient position on the user's LAN can MITM the cleartext default
/// `http://homeassistant.local:8123` `get_config` response, rewrite `external_url` to their own,
/// legitimately-issued `https://<attacker-uuid>.ui.nabu.casa`, and walk away. The suffix check
/// passes, the TLS certificate is genuinely valid, and there is nothing about the URL itself that
/// distinguishes it from the user's own Nabu Casa address. Later — off the compromised network
/// entirely, once the phone's cached access token expires (roughly every 30 minutes) — `AppModel`
/// repoints `TokenProvider` at this "discovered" candidate and refreshes *before opening a
/// socket*, handing the user's long-lived refresh token to a host the attacker administers. That
/// is precisely the persistence-beyond-the-MITM-window this whole feature exists to prevent, not
/// something it accidentally reintroduces.
///
/// There is no smarter check to write here. Nothing about a URL arriving over an
/// attacker-controlled channel can prove it belongs to the user's instance, and instance identity
/// cannot be verified *first* either, because — by construction — the refresh POST has to happen
/// before any WebSocket is opened to ask the candidate who it is. Binding adoption to something
/// harder to fake (the instance's own `uuid`, observed and pinned at first connection) or gating
/// it behind explicit user confirmation are both real fixes; neither is a thing this function can
/// do by itself, and building a confirmation UI overnight without the user able to review it is
/// out of scope. So: nothing from `get_config` is auto-adopted, full stop. Remote access comes
/// only from the URL the user actually typed (`ConnectionEndpoint.candidates`'s `userEntered`
/// parameter) — which, if it's their Nabu Casa URL, they entered it themselves, over a channel
/// this app doesn't need to trust blindly, because *they* are the one who typed it.
///
/// `internal_url` was the same finding through the adjacent field, closed the same way in an
/// earlier fix round: it was classified `.local` for *any* non-Nabu-Casa host, with nothing
/// requiring it to look like a private/LAN address, and it has no legitimate use this app needs
/// anyway (local access is already served by `userEntered`). Validating it as "a private address"
/// isn't implementable inside this threat model either — a legitimate `internal_url` is routinely
/// a bare hostname (`homeassistant.local`, `hass.home.arpa`, a user's own domain) that can't be
/// classified as private without a DNS lookup, and on the exact MITM'd LAN this threat model is
/// about, that lookup is the attacker's too.
///
/// This exists as a pure function `AppModel` calls, not logic `AppModel` reimplements inline —
/// `AppModel` has no test target, so anything living only there is a claim about behavior nobody
/// actually exercises, which is exactly how the Nabu Casa identity gap shipped in the first place.
/// Every test in `ConnectionEndpointTests` that exercises this type runs against the exact code
/// both `rememberDiscoveredURLs` (the write boundary) and `discoveredExternalURL` (the read
/// boundary — whatever is already sitting in `UserDefaults`, possibly written by one of the
/// earlier, less careful builds) call.
public struct DiscoveredCandidateURLs: Sendable, Equatable {
    /// Always `nil`. See the type-level doc for why nothing from `get_config` is ever adopted.
    public let externalURL: URL?

    public init(externalURL: URL?) {
        self.externalURL = externalURL
    }

    /// - Parameters:
    ///   - rawInternalURL: Whatever an untrusted source (the wire, or persisted storage) reports
    ///     as `internal_url`. Accepted only so "this is never adopted, no matter what it says" is
    ///     an assertion a test can make against this exact function — the result never depends on
    ///     its value.
    ///   - rawExternalURL: Whatever an untrusted source reports as `external_url`. Also accepted
    ///     only to prove the same thing: even a genuine `*.ui.nabu.casa` host is never adopted
    ///     from here, because that check proves category, not ownership — see the type-level doc.
    public static func validating(rawInternalURL: URL?, rawExternalURL: URL?) -> DiscoveredCandidateURLs {
        _ = rawInternalURL   // Deliberately unused — see the type-level doc for why.
        _ = rawExternalURL   // Deliberately unused — see the type-level doc for why.
        return DiscoveredCandidateURLs(externalURL: nil)
    }
}
