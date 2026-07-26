import Foundation

/// Which side of the trust boundary a fact was learned on.
///
/// HavenApp's trust model binds trust to **where** a fact was learned, never to **what it says**:
/// the local network is trusted (Home Assistant's default is cleartext HTTP and we support that as
/// a first-class configuration; LAN-based man-in-the-middle is explicitly out of scope), the
/// internet is not. Every decision that depends on that boundary takes this as a parameter rather
/// than trying to infer it from a URL's shape.
public enum ConnectionClass: Sendable, Equatable {
    /// Learned over a connection to the instance's LAN address. Responses are treated as genuine.
    case local
    /// Learned over a connection that crossed the internet. Nothing self-reported is adopted.
    case remote
}

/// The one place that decides what — out of a fresh `get_config` result — is safe to remember as a
/// future connection candidate for this Home Assistant instance.
///
/// ## The rule: adopt a URL only when it was learned over a `.local` connection.
///
/// That single rule is the whole security design. `internal_url` and `external_url` are adopted
/// when `learnedOver == .local`, and adopted from *nothing* when `learnedOver == .remote`. It
/// replaces every earlier attempt to validate a URL's *shape*, and it is strictly stronger than
/// any of them, because it never has to answer the question those attempts kept getting wrong:
/// *whose* Nabu Casa account a `*.ui.nabu.casa` hostname belongs to. That question has no answer —
/// Nabu Casa subdomains are issued to any paying subscriber, so a suffix match proves the
/// *category* (this is *some* Nabu Casa instance) and never the *identity* (it is *this user's*).
/// Using it as a trust gate was the C-1 incident; see
/// `docs/superpowers/2026-07-26-overnight-run-report.md` §1 for the history, and note its
/// SUPERSEDED banner — the "adopt nothing, ever" posture that incident produced has since been
/// reversed by product decision in
/// `docs/superpowers/specs/2026-07-26-havenapp-connection-model-design.md` §1.
///
/// Why the connection class is the right gate: a URL learned over a local connection came from the
/// user's own Home Assistant, reached at the address they typed themselves, inside the trusted
/// zone. A URL learned over a remote connection did not — and the remote candidate is precisely
/// the one `TokenProvider` would later POST the refresh token to, so a remote connection is never
/// allowed to teach us about a *new* remote address. Discovery only ever flows inward: local
/// connection → new remote URL. Never remote → remote.
///
/// The only filtering applied beyond the connection class is basic well-formedness (a non-empty
/// host, an `http`/`https` scheme). That is **not** a trust check — it exists so a malformed value
/// like `URL(string: "homeassistant.local:8123")` (which parses with scheme `homeassistant.local`
/// and *no* host) can't become a nonsense candidate. Do not add checks here that inspect *what*
/// the host is — private-range tests, `.local` suffix tests, Nabu Casa suffix tests. Those are the
/// shape validation this rule replaces, and reintroducing one is a regression, not a hardening.
///
/// This exists as a pure function `AppModel` calls, not logic `AppModel` reimplements inline —
/// `App/` has no test target, so anything living only there is a claim about behavior nobody
/// actually exercises. That is how both the C-1 identity gap and two other overnight bugs shipped
/// green. Every test in `ConnectionEndpointTests` that exercises this type runs against the exact
/// code the write boundary (`AppModel.rememberDiscoveredURLs`) calls.
public struct DiscoveredCandidateURLs: Sendable, Equatable {
    /// Home Assistant's own `internal_url`, or `nil` if it wasn't adopted. Adopted only when
    /// learned over a `.local` connection. Low value on its own — the user already typed a local
    /// address — but it recovers the case where what they typed was a DHCP-assigned IP that has
    /// since moved.
    public let internalURL: URL?

    /// Home Assistant's own `external_url`, or `nil` if it wasn't adopted. Adopted only when
    /// learned over a `.local` connection, and always normalized to `https`: a remote address is
    /// HTTPS-only, always, whatever the instance reported.
    public let externalURL: URL?

    public init(internalURL: URL?, externalURL: URL?) {
        self.internalURL = internalURL
        self.externalURL = externalURL
    }

    /// - Parameters:
    ///   - rawInternalURL: `get_config`'s `internal_url`, exactly as reported.
    ///   - rawExternalURL: `get_config`'s `external_url`, exactly as reported.
    ///   - learnedOver: the class of the connection this `get_config` result arrived over.
    ///     `.remote` yields no candidates at all — **that is the security property**, and it holds
    ///     no matter how legitimate the URLs look.
    public static func validating(
        rawInternalURL: URL?,
        rawExternalURL: URL?,
        learnedOver: ConnectionClass
    ) -> DiscoveredCandidateURLs {
        guard learnedOver == .local else {
            // The security property, stated as code: a remote connection can never teach us a new
            // address to reach this instance at. Not "validate harder when remote" — adopt
            // nothing, unconditionally.
            return DiscoveredCandidateURLs(internalURL: nil, externalURL: nil)
        }
        return DiscoveredCandidateURLs(
            internalURL: wellFormed(rawInternalURL),
            externalURL: wellFormed(rawExternalURL).map(forcedHTTPS)
        )
    }

    /// Well-formedness, not trust — see the type doc. Deliberately says nothing about *what* the
    /// host is.
    private static func wellFormed(_ url: URL?) -> URL? {
        guard let url,
              let host = url.host(), !host.isEmpty,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private static func forcedHTTPS(_ url: URL) -> URL {
        guard url.scheme?.lowercased() != "https" else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = "https"
        return components.url ?? url
    }
}

/// One-time cleanup of connection URLs persisted by the "adopt nothing" overnight build.
///
/// ## Why this is a migration and not a purge
///
/// The overnight build called an unconditional `purgeDiscoveredURLs()` at the top of *every*
/// iteration of `AppModel.connect()`'s `while true` loop. With adoption re-enabled that is a
/// silent-failure trap: the URL learned at the end of one round is deleted at the top of the next,
/// before anything reads it. The symptom is "remote access never works", with no error logged
/// anywhere and every test still green. So the clear must happen **exactly once per device**, from
/// outside the connect loop — never repeatedly.
///
/// ## Why any clear is needed at all
///
/// A device that ran the overnight build (or one of the two earlier fix rounds) may hold values
/// written under rules that no longer exist — including, from before the C-1 fix, an `external_url`
/// that was never gated on the connection it was learned over. Rather than reason about which
/// era each stored value came from, clear them once and let the device re-learn cleanly over its
/// next local connection. After that, stored values are trusted: they can only have been written
/// by `DiscoveredCandidateURLs.validating` under the `.local` rule.
///
/// Lives here, with an injectable `UserDefaults`, so it is exercised by real tests — the whole
/// reason the trap it fixes was able to exist is that `AppModel` has no test target.
public enum DiscoveredURLMigration {
    /// `UserDefaults` key holding a discovered `internal_url`.
    public static let discoveredInternalURLKey = "discoveredInternalURL"
    /// `UserDefaults` key holding a discovered `external_url`.
    public static let discoveredExternalURLKey = "discoveredExternalURL"
    /// `UserDefaults` key holding the candidate URL that last completed a full connect.
    public static let lastWorkingURLKey = "lastWorkingURL"
    /// Set once the clear below has run. Versioned so a future migration can be added beside it
    /// rather than by mutating this one's meaning.
    public static let didClearOvernightURLsKey = "havenapp.migration.didClearOvernightDiscoveredURLs.v1"

    /// Clears the three connection-URL keys, once per device.
    ///
    /// - Returns: `true` if this call performed the clear, `false` if it had already been done.
    ///   Note the flag is set on the first call whether or not anything was actually present, so a
    ///   device with nothing stored doesn't keep "migrating" forever — and, critically, so a URL
    ///   written *after* the migration ran survives every subsequent call. That is the trap.
    @discardableResult
    public static func runIfNeeded(in defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: didClearOvernightURLsKey) else { return false }
        defaults.removeObject(forKey: discoveredInternalURLKey)
        defaults.removeObject(forKey: discoveredExternalURLKey)
        defaults.removeObject(forKey: lastWorkingURLKey)
        defaults.set(true, forKey: didClearOvernightURLsKey)
        return true
    }
}
