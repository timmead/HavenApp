import Foundation

/// Why a typed external address was refused. The message is here, in HavenCore, rather than in the
/// view: "an `http://` address is rejected with an actionable explanation" is a behaviour, and a
/// behaviour whose text lives only in `App/` is untestable — same reason every other decision in
/// this layer was moved out of `AppModel`. The view renders `message` verbatim, exactly as it does
/// `RemoteAccessOfferModel.failureMessage`.
public enum CustomRemoteURLError: Error, Sendable, Equatable {
    /// Nothing (or only whitespace) was typed.
    case empty

    /// The user explicitly typed `http://`.
    ///
    /// **Deliberately not repaired.** Rewriting it to `https://` would produce an address the user
    /// never chose, and if their server doesn't actually serve TLS the result is a connection
    /// failure at some later point that says nothing about the cause. Refusing here, with the
    /// reason, is the one moment the explanation can still reach them.
    case insecureScheme

    /// A scheme other than `http`/`https`, or something that isn't a URL with a host at all.
    case malformed

    /// Shown to the user verbatim. Each one names what was wrong *and* what to do about it —
    /// "invalid URL" on its own leaves someone who typed their working Tailscale address with
    /// nowhere to go.
    public var message: String {
        switch self {
        case .empty:
            return "Enter the address you use to reach Home Assistant from outside your home."
        case .insecureScheme:
            return """
            A remote address must start with https:// — it travels over the internet, so it has to \
            be encrypted. Haven won't change http:// to https:// for you, because that would only \
            work if your server is already set up for it. If it isn't, put Home Assistant behind \
            something that provides HTTPS — Tailscale, a reverse proxy, or Nabu Casa.
            """
        case .malformed:
            return "That doesn't look like an address. It should look like https://ha.example.com."
        }
    }
}

/// Validation for the **custom remote URL** — the user's own externally-reachable address, for
/// people running Tailscale or their own reverse proxy rather than Nabu Casa.
///
/// ## Why this is trusted without a `learnedOver` check
///
/// `DiscoveredCandidateURLs` gates `get_config`'s URLs on the connection class because those are
/// *self-reported by the far end*: the whole question there is whether the thing that told us the
/// address was really the user's Home Assistant. This address was typed by the user, exactly like
/// the local address they typed at sign-in, so that question doesn't arise. Gating it on
/// `learnedOver == .local` would not add security — it would just mean a user who is away from home
/// right now can't configure the address they need in order to get home. Do not "harden" it that
/// way.
///
/// ## HTTPS is required, and not by upgrading
///
/// Per the design's §1, remote connections are HTTPS-only, always. That rule is enforced here by
/// **rejection**, never by rewriting a typed `http://` into `https://` — see
/// `CustomRemoteURLError.insecureScheme`.
///
/// A *scheme-less* entry (`ha.example.com`, `ha.example.com:8443`) is a different case and is
/// accepted, with `https://` filled in: nothing was chosen, so nothing is being overridden, and
/// https is the only scheme this field can hold anyway. This mirrors `AppModel.signIn()`, which
/// fills in `http://` for a scheme-less local address for the same reason.
public enum CustomRemoteURL {
    /// Validates one raw text-field entry.
    ///
    /// Order matters: trim, reject empty, judge the scheme **on the raw string**, and only then
    /// parse. Parsing first would misreport the common `ha.example.com:8123` — `URL(string:)` reads
    /// that as scheme `ha.example.com` with *no host*, so a scheme-shaped complaint would be wrong
    /// and a host-shaped one would be baffling.
    public static func validating(_ raw: String) -> Result<URL, CustomRemoteURLError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        // The one branch this whole type exists for. Note it returns before anything is written —
        // see `CustomRemoteURLStore.save`.
        guard !hasScheme(trimmed, "http") else { return .failure(.insecureScheme) }
        let isHTTPS = hasScheme(trimmed, "https")
        // Some other scheme (`ws://`, `ftp://`, a typo). Prefixing `https://` onto it would build a
        // nonsense URL that parses, so refuse it as malformed rather than filling anything in.
        guard isHTTPS || !trimmed.contains("://") else { return .failure(.malformed) }
        let normalized = isHTTPS ? trimmed : "https://\(trimmed)"

        guard let url = URL(string: normalized),
              let host = url.host(), !host.isEmpty,
              url.scheme?.lowercased() == "https"
        else { return .failure(.malformed) }
        return .success(url)
    }

    /// Case-insensitive `<scheme>://` prefix test on the *raw* string. `http` must not also match
    /// `https`, hence the explicit `://`.
    private static func hasScheme(_ raw: String, _ scheme: String) -> Bool {
        raw.lowercased().hasPrefix("\(scheme)://")
    }
}

/// Persistence for the custom remote URL — **its own slot**, and that is the point of the type.
///
/// ## The collision this exists to prevent
///
/// `cloud/status`'s Nabu Casa URL and `get_config`'s `external_url` share the single
/// `discoveredExternalURL` key, and `cloud/status` runs second, so Nabu Casa wins. That precedence
/// is right for those two — `remote_domain` is the cloud's own authority on its tunnel, whereas
/// `external_url` is free text. But a user who runs **both** Nabu Casa and their own reverse proxy
/// has two genuinely different remote paths, and storing this one in that same slot would mean the
/// next `cloud/status` silently deleted the address they typed. They would never see an error;
/// their reverse proxy would simply stop being tried. Hence a separate key, written and cleared
/// only from here, and untouched by every other write boundary.
///
/// Injectable `UserDefaults` for the same reason `DiscoveredURLMigration` has one: the property
/// worth testing is *which slot gets written*, and that can only be tested where the storage is.
/// Not `Sendable`: `UserDefaults` isn't, and this type is only ever touched from the main actor
/// (`AppModel`) or from a test. `DiscoveredURLMigration` takes its defaults as a plain parameter for
/// the same reason.
public struct CustomRemoteURLStore {
    /// The dedicated slot. Deliberately not adjacent to `DiscoveredURLMigration`'s keys — it is not
    /// discovered, and it must not be swept up by that migration (which clears values written under
    /// rules that no longer exist; this value was written by the user, under no rule at all).
    public static let storageKey = "customRemoteURL"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored URL, or `nil` if the user has never set one (or cleared it).
    ///
    /// Read without re-validation, matching `AppModel.storedURL`: the only writer is `save` below,
    /// which stores only what `validating` returned. Re-deciding on read would be a second copy of
    /// the rule that could drift from the first.
    public var url: URL? {
        defaults.string(forKey: Self.storageKey).flatMap(URL.init(string:))
    }

    /// Validates and, only on success, persists.
    ///
    /// **Nothing is written on failure** — including the `http://` case, which must not leave a
    /// half-accepted value behind for the next connect to pick up.
    @discardableResult
    public func save(_ raw: String) -> Result<URL, CustomRemoteURLError> {
        let result = CustomRemoteURL.validating(raw)
        if case .success(let url) = result {
            defaults.set(url.absoluteString, forKey: Self.storageKey)
        }
        return result
    }

    /// Removes **only** this slot. The discovered/Nabu Casa URL, the local address and the
    /// last-working URL are all somebody else's state and are left exactly as they were.
    public func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}
