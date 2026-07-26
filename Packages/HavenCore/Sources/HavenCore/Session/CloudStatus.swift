import Foundation

/// A subset of Home Assistant's `cloud/status` WebSocket command result — the fields HavenApp
/// needs to discover a Nabu Casa remote address without the user typing anything.
///
/// **Wire shape verified against `home-assistant/core`**, not assumed: the command is served by
/// `homeassistant/components/cloud/http_api.py`'s `websocket_cloud_status`, whose payload is built
/// by `_account_data`. Signed out, that returns little more than `{"logged_in": false, ...}`;
/// signed in it returns `logged_in`, `active_subscription`, `remote_domain`, `remote_connected`
/// and the full `prefs` dictionary, among many fields we don't decode. The two `prefs` keys below
/// are the literal strings from `components/cloud/const.py` (`PREF_ENABLE_REMOTE = "remote_enabled"`,
/// `PREF_REMOTE_ALLOW_REMOTE_ENABLE = "remote_allow_remote_enable"`). Adding a field here without
/// checking it exists in that source has cost this project three separate incidents.
///
/// ## Every field is optional, and that is load-bearing
///
/// A missing key must stay distinguishable from a key that is present and `false`. Defaulting a
/// `Bool` to `false` here would be the `HAInstanceConfig.components` mistake again in a place where
/// it costs more: `remote_enabled` defaulting to `false` would tell a subscriber whose remote
/// access is working perfectly that it is switched off, and invite them to "fix" it with a
/// mutating call against their own Home Assistant. `NabuCasaRemoteAccessDetector.classify` is
/// written to branch on `== false` / `== true` explicitly, never on `!flag`, for the same reason.
public struct HACloudStatus: Sendable, Equatable, Decodable {
    /// Whether a Nabu Casa (Home Assistant Cloud) account is signed in on this instance. `nil`
    /// means the key was absent — not "signed out"; only an explicit `false` says that.
    public let loggedIn: Bool?

    /// Whether that account currently has an active subscription. Remote access is a subscription
    /// feature, so this — not `remote_domain`'s presence — is the gate on the Nabu Casa path.
    public let activeSubscription: Bool?

    /// The instance's assigned Nabu Casa **domain**, e.g. `abc123.ui.nabu.casa`.
    ///
    /// **A domain, not a URL.** The remote URL is `https://<remote_domain>`; see
    /// `NabuCasaRemoteAccessDetector.remoteURL(fromDomain:)`, which is the only place that
    /// derivation happens.
    public let remoteDomain: String?

    /// Whether the remote tunnel is connected **right now**.
    ///
    /// This is *current state*, and it is emphatically **not** the same question as "has the user
    /// enabled remote access" — that is `prefs.remoteEnabled`, which is *intent*. A tunnel that is
    /// merely establishing, or that dropped a moment ago, reports `false` here while being
    /// perfectly enabled. Nothing in `classify` branches on this field, deliberately: doing so
    /// would offer to change a user's Home Assistant configuration to fix something that was never
    /// broken. Decoded and carried for diagnostics only.
    public let remoteConnected: Bool?

    /// The cloud component's preferences object, or `nil` if absent (which it is whenever the user
    /// is signed out).
    public let prefs: Prefs?

    /// The subset of `cloud/status`'s `prefs` dictionary this app reads. Keys verified in
    /// `components/cloud/const.py`.
    public struct Prefs: Sendable, Equatable, Decodable {
        /// `PREF_ENABLE_REMOTE` — the user's *intent*: have they switched remote access on?
        ///
        /// This, and only this, is the "is it switched off?" signal. `nil` means the key was
        /// missing, which is not evidence of either answer, and `classify` treats it as "not
        /// switched off" — because the two mistakes cost different amounts. Reading an unknown as
        /// "enabled" and adopting a URL that turns out not to work costs one failed candidate at a
        /// 2s deadline; reading it as "disabled" proposes a mutation of the user's Home Assistant
        /// on no evidence.
        public let remoteEnabled: Bool?

        /// `PREF_REMOTE_ALLOW_REMOTE_ENABLE` — whether Home Assistant will accept
        /// `cloud/remote/connect` *over a remote connection*. Decoded so that Task 3's offer can
        /// respect it up front rather than discovering it as an opaque failure; see
        /// `NabuCasaRemoteAccessDetector.canEnableRemoteAccess(_:over:)`. It should never bite in
        /// practice, since the offer is only ever made from a local connection.
        public let remoteAllowRemoteEnable: Bool?

        private enum CodingKeys: String, CodingKey {
            case remoteEnabled = "remote_enabled"
            case remoteAllowRemoteEnable = "remote_allow_remote_enable"
        }

        public init(remoteEnabled: Bool? = nil, remoteAllowRemoteEnable: Bool? = nil) {
            self.remoteEnabled = remoteEnabled
            self.remoteAllowRemoteEnable = remoteAllowRemoteEnable
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            remoteEnabled = try container.decodeIfPresent(Bool.self, forKey: .remoteEnabled)
            remoteAllowRemoteEnable = try container.decodeIfPresent(Bool.self, forKey: .remoteAllowRemoteEnable)
        }
    }

    // Explicit snake_case keys, decoded with a *plain* `JSONDecoder` — never `HACoding.decoder`.
    // Same trap `HAInstanceConfig` documents: that decoder's `.convertFromSnakeCase` strategy
    // rewrites `remote_domain` to `remoteDomain` *before* matching against these raw values, so
    // every field here would silently decode as `nil`. See `HomeConnection.fetchCloudStatus`.
    private enum CodingKeys: String, CodingKey {
        case loggedIn = "logged_in"
        case activeSubscription = "active_subscription"
        case remoteDomain = "remote_domain"
        case remoteConnected = "remote_connected"
        case prefs
    }

    public init(
        loggedIn: Bool? = nil,
        activeSubscription: Bool? = nil,
        remoteDomain: String? = nil,
        remoteConnected: Bool? = nil,
        prefs: Prefs? = nil
    ) {
        self.loggedIn = loggedIn
        self.activeSubscription = activeSubscription
        self.remoteDomain = remoteDomain
        self.remoteConnected = remoteConnected
        self.prefs = prefs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `decodeIfPresent` throughout, and no `?? false` anywhere — see the type's documentation.
        loggedIn = try container.decodeIfPresent(Bool.self, forKey: .loggedIn)
        activeSubscription = try container.decodeIfPresent(Bool.self, forKey: .activeSubscription)
        remoteDomain = try container.decodeIfPresent(String.self, forKey: .remoteDomain)
        remoteConnected = try container.decodeIfPresent(Bool.self, forKey: .remoteConnected)
        prefs = try container.decodeIfPresent(Prefs.self, forKey: .prefs)
    }
}

/// Task 3's one-tap fix: what to show a subscriber who has switched remote access off, and whether
/// tapping its button would actually work from here.
///
/// A sibling to `HavenOnboardingStep`/`HavenOnboardingMutation`, not a member of either — those are
/// keyed on `HavenIntegrationDetector.classify`, which knows nothing about Nabu Casa, and folding an
/// unrelated mutation into `HavenOnboardingStep`'s closed, one-to-one-with-`HavenOnboardingFlow`
/// case set would make that state machine (and `OnboardingModel.confirmPendingMutation`'s switch)
/// respond to something it has no way to interpret. What *is* reused, deliberately, is
/// `HavenOnboardingConfirmation` itself — the same confirmation copy type, not a second one — per
/// the plan's explicit instruction not to invent a parallel pattern.
public struct NabuCasaRemoteAccessOffer: Sendable, Equatable {
    /// The domain remote access will use once turned on, when `cloud/status` happened to report
    /// one. Cosmetic only: `cloud/remote/connect` takes no domain argument, so its absence changes
    /// nothing about whether the offer is shown — see `NabuCasaRemoteAccess.remoteDisabled`.
    public let domain: String?

    /// `false` only when `remote_allow_remote_enable` would make Home Assistant refuse the call
    /// over this connection — see `NabuCasaRemoteAccessDetector.canEnableRemoteAccess`. HavenApp
    /// only ever shows this offer from a local connection, where that preference cannot bite, so
    /// this should never be `false` in practice. When it is, `confirmation` is `nil` and
    /// `explanation` says why, rather than letting the user tap a button into an opaque failure.
    public let canEnable: Bool

    public init(domain: String?, canEnable: Bool) {
        self.domain = domain
        self.canEnable = canEnable
    }

    public var title: String { "Remote access is turned off" }

    /// Plain, short, no security theatre — this confirms a configuration change to the user's own
    /// server, not a dangerous action, so the copy says what will happen and stops there.
    public var explanation: String {
        guard canEnable else {
            return """
            Your Nabu Casa subscription is active, but remote access is switched off, and Home \
            Assistant won't allow Haven to turn it on from outside your home network. Turn it on \
            once you're home, or from Home Assistant's own Home Assistant Cloud settings.
            """
        }
        return """
        Your Nabu Casa subscription is active, but remote access is switched off, so Home Assistant \
        can only be reached on your home network right now. Haven can turn it on for you.
        """
    }

    /// `nil` exactly when there is nothing to confirm because the call would be refused — see
    /// `canEnable`. Every other property here may render unconditionally; only this one gates the
    /// mutating call, and its absence is what makes that call unreachable without it.
    public var confirmation: HavenOnboardingConfirmation? {
        guard canEnable else { return nil }
        let domainClause = domain.map { " at \($0)" } ?? ""
        return HavenOnboardingConfirmation(
            title: "Turn on remote access?",
            message: """
            Haven will turn on remote access to your Home Assistant through Nabu Casa\(domainClause), \
            so you can reach it when you're away from home. This changes your Home Assistant's own \
            Home Assistant Cloud settings.
            """,
            confirmLabel: "Turn on"
        )
    }
}

/// What a `cloud/remote/connect` attempt turned out to mean, once verified. Produced only by
/// `NabuCasaRemoteAccessDetector.evaluateEnableAttempt` — never from the call's own result, which
/// (like `restartHomeAssistant`'s) means only that Home Assistant accepted the request.
public enum RemoteAccessEnableOutcome: Sendable, Equatable {
    /// A fresh `cloud/status`, re-probed and re-classified, now says `.remoteAvailable`. The fix
    /// took effect.
    case succeeded(URL)
    /// The re-probe still doesn't say `.remoteAvailable` — still switched off, or anything else
    /// (`.indeterminate`, a transport hiccup) that leaves nothing to celebrate. One plain,
    /// actionable message covers all of those: there is nothing more specific and true to say than
    /// "try again, or check Home Assistant directly."
    case didNotTakeEffect(message: String)
}

extension NabuCasaRemoteAccessDetector {
    /// Whether, and what, to offer. Built directly from the same `cloud/status` result `classify`
    /// reads — no separate probe — so the offer and the classification can never disagree about
    /// what `cloud/status` actually said.
    ///
    /// - Returns: `nil` whenever `classify` is anything other than `.remoteDisabled`: there is
    ///   nothing to fix for an available, absent, not-signed-in, or indeterminate subscription.
    public static func offer(
        from result: Result<HACloudStatus, WSError>,
        over connectionClass: ConnectionClass
    ) -> NabuCasaRemoteAccessOffer? {
        guard case .success(let status) = result,
              case .remoteDisabled(let domain) = classify(result)
        else { return nil }
        return NabuCasaRemoteAccessOffer(
            domain: domain,
            canEnable: canEnableRemoteAccess(status, over: connectionClass)
        )
    }

    /// The message shown when a re-probe after enabling still doesn't show remote access as
    /// available. Named so both the message itself and the fact that it is always the same one are
    /// each independently assertable in tests.
    ///
    /// Deliberately does **not** say "remote access is still switched off" — `evaluateEnableAttempt`
    /// reaches this for `.indeterminate` and a transport failure just as much as for a genuine
    /// `.remoteDisabled`, and a socket blip immediately after `cloud/remote/connect` is a realistic
    /// way to land here. Claiming a specific, confident cause we don't have evidence for is exactly
    /// this project's recurring mistake (see this file's own top-of-file documentation) — "Haven
    /// couldn't confirm it" is the only claim every one of those cases actually supports.
    public static let remoteAccessDidNotTakeEffectMessage =
        "Haven couldn't confirm that remote access turned on. Wait a moment and try again, or check Settings › Home Assistant Cloud directly on your Home Assistant."

    /// Verifies a `cloud/remote/connect` attempt rather than trusting the call's own success —
    /// exactly the discipline `HavenOnboardingFlow` applies to the restart step, where a `.success`
    /// result is HA merely *accepting* the request, never proof it happened.
    public static func evaluateEnableAttempt(reprobe: Result<HACloudStatus, WSError>) -> RemoteAccessEnableOutcome {
        if case .remoteAvailable(let url) = classify(reprobe) {
            return .succeeded(url)
        }
        return .didNotTakeEffect(message: remoteAccessDidNotTakeEffectMessage)
    }
}

extension HomeConnection {
    /// Asks the instance whether it has Nabu Casa remote access, and at what domain.
    ///
    /// Never throws — every failure mode (an HA-side error result, a dead socket, a payload that
    /// doesn't decode) folds into `Result.failure(WSError)` exactly as `fetchIntegrationInfo` does,
    /// so `NabuCasaRemoteAccessDetector.classify` has one failure shape to reason about. That
    /// matters more here than usual, because **one particular failure is not a failure at all**:
    /// an instance without the `cloud` component loaded answers `cloud/status` with Home
    /// Assistant's generic `unknown_command`, and that is the ordinary self-hosted user, not an
    /// error to show them.
    ///
    /// Uses a plain `JSONDecoder`, *not* `HACoding.decoder` — see `HACloudStatus`'s `CodingKeys`.
    public func fetchCloudStatus() async -> Result<HACloudStatus, WSError> {
        do {
            let v = try await client.request { WSCommand.cloudStatus(id: $0) }
            let data = try JSONEncoder().encode(v)
            let status = try JSONDecoder().decode(HACloudStatus.self, from: data)
            return .success(status)
        } catch {
            return .failure(Self.normalize(error))
        }
    }

    /// MUTATING. Turns on Nabu Casa remote access on this instance. The only path to this is
    /// `NabuCasaRemoteAccessOffer.confirmation` — `nil` unless the user has confirmed exactly this
    /// change, and unreachable at all when Home Assistant would refuse it outright (see
    /// `NabuCasaRemoteAccessOffer.canEnable`).
    ///
    /// A `.success` here means only that Home Assistant accepted the request — the same caveat
    /// `restartHomeAssistant` carries, and for the same reason: HA schedules the actual work and
    /// returns, so this is not evidence the tunnel came up. The caller must re-probe
    /// `fetchCloudStatus()` and pass the result to `NabuCasaRemoteAccessDetector.evaluateEnableAttempt`
    /// to find out what really happened.
    public func enableNabuCasaRemoteAccess() async -> Result<Void, WSError> {
        do {
            _ = try await client.request { WSCommand.cloudRemoteConnect(id: $0) }
            return .success(())
        } catch {
            return .failure(Self.normalize(error))
        }
    }
}

/// What `cloud/status` says about this instance's remote access, reduced to the one thing HavenApp
/// actually has to decide: can we reach this home from outside, and if not, what should we tell
/// the user? Produced only by `NabuCasaRemoteAccessDetector.classify`.
public enum NabuCasaRemoteAccess: Sendable, Equatable {
    /// The instance has an active subscription, remote access is not switched off, and it reported
    /// a domain — so `https://<domain>` is a usable remote address. This is the target experience:
    /// zero user input.
    ///
    /// Produced **regardless of `remote_connected`**. See `HACloudStatus.remoteConnected`: that
    /// field is current state, not intent, and a tunnel that is down at this instant may well be
    /// up by the time we actually need it. Adopting the URL costs nothing if it turns out to be
    /// unreachable — it is one candidate at a 2s deadline.
    ///
    /// The URL still has to survive the trust gate before it is *stored*; that is
    /// `NabuCasaRemoteAccessDetector.adoptableRemoteURL(from:learnedOver:)`, not this case.
    case remoteAvailable(URL)

    /// The instance has an active subscription and `prefs.remote_enabled` is explicitly `false` —
    /// the user has switched remote access off. This, and only this, is the state where offering
    /// to turn it on (`cloud/remote/connect`, Task 3) is correct.
    ///
    /// `domain` is optional because the *trigger* for this case is the preference alone. Requiring
    /// a domain here would quietly add a second, unstated precondition and route a genuinely
    /// switched-off user into `.indeterminate`, where nothing would be offered.
    /// `cloud/remote/connect` takes no domain argument, so the offer does not need one; it is
    /// carried purely so the UI can name what will be turned on when it happens to be known.
    case remoteDisabled(domain: String?)

    /// A Nabu Casa account is signed in but has no active subscription. Remote access needs either
    /// a subscription or the user's own externally-reachable URL (Task 6). Don't nag.
    case noSubscription

    /// `cloud/status` came back as Home Assistant's `unknown_command`: the `cloud` component isn't
    /// loaded at all.
    ///
    /// **This is not an error.** It is the ordinary self-hosted user — Tailscale, a reverse proxy,
    /// a plain HA OS install with cloud never set up — and the correct destination is the
    /// custom-URL path (Task 6). Treating it as a failure, or worse as "you need Nabu Casa", sends
    /// someone whose remote access already works perfectly into a dead end.
    case cloudNotLoaded

    /// No cloud account is signed in (`logged_in` is explicitly `false`). Also the custom-URL path.
    case notLoggedIn

    /// `cloud/status` answered, but not with enough to make any of the claims above honestly.
    ///
    /// Reached when the request failed for a reason *other* than `unknown_command` (a dropped
    /// socket, an undecodable payload), when `active_subscription` was absent, or when a
    /// subscription is active and remote access is not switched off yet no usable domain was
    /// reported — the last of which is what a tunnel mid-registration would look like.
    ///
    /// This case exists for the same reason `HavenIntegrationStatus.indeterminate` does: every
    /// alternative is a confident claim we cannot support. `.noSubscription` would tell a paying
    /// subscriber they aren't one; `.cloudNotLoaded` would tell them they're self-hosted;
    /// `.remoteDisabled` would invite them to mutate a Home Assistant that isn't misconfigured.
    /// "We couldn't determine this" is the only true statement available, and it is diagnosable.
    case indeterminate
}

/// The single pure function that turns a `cloud/status` result into a decision, plus the URL
/// derivation and trust gate that go with it.
///
/// No I/O, no actor isolation, no `App/` — `App/` has no test target, so a decision that lived
/// there would be an unverified claim about behaviour nobody exercises. Every case below is
/// exercised directly in `CloudStatusTests`; `App/` may only call this and render the result.
public enum NabuCasaRemoteAccessDetector {
    /// Classifies what `cloud/status` said. Total: every input produces exactly one case.
    ///
    /// ## The distinction that decides everything
    ///
    /// `prefs.remote_enabled` is **intent**; `remote_connected` is **current state**. Only the
    /// former can answer "has the user switched remote access off?", and only an explicit `false`
    /// answers it — a missing key does not. Branching on `remote_connected` instead would produce
    /// `.remoteDisabled` for a tunnel that is merely establishing or briefly dropped, and Task 3
    /// would then offer to "fix" a correctly-configured Home Assistant. `remote_connected` is
    /// therefore read by nothing in this function.
    ///
    /// - Parameter result: `HomeConnection.fetchCloudStatus()`'s result. A failure carrying HA's
    ///   `unknown_command` is the `cloud`-component-not-loaded case and is **not** an error; any
    ///   other failure is `.indeterminate`, because "we couldn't ask" must never be reported as
    ///   "you are self-hosted".
    public static func classify(_ result: Result<HACloudStatus, WSError>) -> NabuCasaRemoteAccess {
        let status: HACloudStatus
        switch result {
        case .failure(let error):
            // The one failure that is really an answer. Everything else — a dead socket, a
            // payload we couldn't decode (both of which arrive as `probe_failed`) — is unknown,
            // not "self-hosted": mapping those here would route a Nabu Casa subscriber whose
            // Wi-Fi blipped straight into the custom-URL path.
            return error.isUnknownCommand ? .cloudNotLoaded : .indeterminate
        case .success(let value):
            status = value
        }

        // Explicit `== false` throughout, never `!flag` — a missing key is not a `false`. See
        // `HACloudStatus`'s documentation.
        if status.loggedIn == false { return .notLoggedIn }
        if status.activeSubscription == false { return .noSubscription }
        guard status.activeSubscription == true else {
            // Absent, so we know neither that there is a subscription nor that there isn't.
            return .indeterminate
        }
        if status.prefs?.remoteEnabled == false {
            // Intent, explicitly off. The only state where offering `cloud/remote/connect` is right.
            return .remoteDisabled(domain: status.remoteDomain)
        }
        guard let url = remoteURL(fromDomain: status.remoteDomain) else {
            // Subscribed, not switched off, but no usable domain — nothing to adopt and nothing
            // honest to claim.
            return .indeterminate
        }
        return .remoteAvailable(url)
    }

    /// Derives the remote URL from `cloud/status`'s `remote_domain`. The **only** place this
    /// happens.
    ///
    /// `remote_domain` is a bare domain (`abc123.ui.nabu.casa`), so the URL is `https://` plus that
    /// domain — prepended exactly once, and `https` unconditionally, because a remote address is
    /// HTTPS-only always (design §1).
    ///
    /// A value that arrives already carrying a scheme, a path, or whitespace is **rejected**, not
    /// repaired. HA's contract here is "domain"; a URL-shaped value would mean that assumption has
    /// broken, and silently stripping a `https://` prefix would hide exactly the wire-shape
    /// surprise this codebase has been bitten by three times. Rejecting surfaces it as
    /// `.indeterminate`, which is visible.
    ///
    /// - Returns: `https://<domain>`, or `nil` if the value is absent, empty, or not a bare domain.
    public static func remoteURL(fromDomain rawDomain: String?) -> URL? {
        guard let trimmed = rawDomain?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              // Not a URL, not a path, not a spaced-out string: a domain. The `/` test is also
              // what rejects a scheme-bearing value — `https://x` contains slashes — so there is
              // no separate "strip the scheme" branch to get wrong.
              !trimmed.contains("/"),
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: "https://\(trimmed)"),
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    /// The trust gate, and the reason a `cloud/status` answered over a remote connection cannot
    /// teach us a new remote address.
    ///
    /// A remote URL may **only** be adopted when it was learned over a `.local` connection — the
    /// whole security design (spec §1). That rule is not re-implemented here: this delegates to
    /// `DiscoveredCandidateURLs.validating`, the same pure function `get_config`'s URLs already
    /// flow through, so there is exactly one place in the codebase that decides whether a
    /// self-reported address may be remembered. A second implementation of the same rule is a
    /// second place for it to drift.
    ///
    /// - Parameters:
    ///   - outcome: what `classify` said. Anything but `.remoteAvailable` yields `nil` — there is
    ///     no URL to adopt in the other cases.
    ///   - learnedOver: the class of the connection this `cloud/status` result arrived over,
    ///     derived from the socket's peer address (`ConnectionClass.observed(peerAddress:)`), never
    ///     from a hostname.
    /// - Returns: the URL to persist as this instance's remote address, or `nil` to persist
    ///   nothing.
    public static func adoptableRemoteURL(
        from outcome: NabuCasaRemoteAccess,
        learnedOver: ConnectionClass
    ) -> URL? {
        guard case .remoteAvailable(let url) = outcome else { return nil }
        return DiscoveredCandidateURLs.validating(
            rawInternalURL: nil,
            rawExternalURL: url,
            learnedOver: learnedOver
        ).externalURL
    }

    /// Whether a remote URL already stored for this instance has been **superseded** by what
    /// `cloud/status` now says, and should be forgotten.
    ///
    /// The case this exists for: a Nabu Casa subscription lapses. `classify` then returns
    /// `.noSubscription` (or `.notLoggedIn` if the account was removed), `adoptableRemoteURL`
    /// returns `nil`, and nothing writes — so the **dead** `*.ui.nabu.casa` URL sits in the slot
    /// indefinitely. It is deliberately ordered ahead of the user's custom remote URL, so someone
    /// who then sets up their own reverse proxy pays a connect deadline against a tunnel that will
    /// never answer, on every connect away from home, with nothing in the UI to remove it.
    ///
    /// Three conditions, all required:
    ///
    /// - **`learnedOver == .local`.** This *deletes* a candidate rather than adding one, so it is
    ///   the safe direction — but a remote connection still gets no say in what we remember about
    ///   how to reach the instance, in either direction. Keeping the rule symmetric means there is
    ///   one sentence to remember rather than two.
    /// - **The outcome is `.noSubscription` or `.notLoggedIn`.** These are positive evidence that
    ///   the tunnel is gone, not merely an absence of evidence. `.indeterminate` and
    ///   `.cloudNotLoaded` are excluded deliberately: a transport blip classifies `.indeterminate`,
    ///   and deleting a working remote address because one probe failed would strand the user next
    ///   time they leave home.
    /// - **The stored URL is a Nabu Casa host.** `ConnectionEndpoint.isNabuCasaHost` used for
    ///   exactly what it is for — classification, never trust (see its documentation and the C-1
    ///   incident). Without this the same slot's *other* occupant would be destroyed: `get_config`'s
    ///   `external_url`, which is written to this key first and belongs to a self-hosted user whose
    ///   HA has the cloud component loaded but no subscription — precisely the `.noSubscription`
    ///   user. Their reverse proxy address is not evidence about anybody's cloud account.
    public static func storedRemoteURLIsSuperseded(
        _ storedURL: URL?,
        by outcome: NabuCasaRemoteAccess,
        learnedOver: ConnectionClass
    ) -> Bool {
        guard learnedOver == .local, let storedURL else { return false }
        switch outcome {
        case .noSubscription, .notLoggedIn:
            return ConnectionEndpoint.isNabuCasaHost(storedURL)
        case .remoteAvailable, .remoteDisabled, .cloudNotLoaded, .indeterminate:
            return false
        }
    }

    /// Whether Home Assistant would accept `cloud/remote/connect` over a connection of this class.
    ///
    /// `PREF_REMOTE_ALLOW_REMOTE_ENABLE` (`prefs.remote_allow_remote_enable`), when `false`, makes
    /// HA refuse to enable remote access from a *remote* connection. HavenApp only ever offers that
    /// from a local one, so this should never bite — but it is decoded and answered here so Task 3
    /// can check it up front instead of meeting it as an opaque failure after the user taps.
    ///
    /// Deliberately does **not** feed `classify`: whether the offer is *shown* is Task 3's
    /// decision, and folding a permission into the classification would make `.remoteDisabled`
    /// mean two different things.
    ///
    /// A missing key answers `true` — HA's own default for this preference is permissive, and
    /// withholding an offer on a key we never saw would be the same "confident claim from an
    /// absent field" mistake in the other direction.
    public static func canEnableRemoteAccess(
        _ status: HACloudStatus,
        over connectionClass: ConnectionClass
    ) -> Bool {
        guard connectionClass == .remote else { return true }
        return status.prefs?.remoteAllowRemoteEnable != false
    }
}

extension NabuCasaRemoteAccess {
    /// What to tell the user about remote access for the outcomes that lead to the **custom remote
    /// URL** — their own externally-reachable address (Tailscale, a reverse proxy) instead of Nabu
    /// Casa. `nil` where there is nothing to say on that surface.
    ///
    /// Design §3's outcomes 3 and 4. Without this the four non-Nabu-Casa outcomes are classified,
    /// documented and unit-tested, and rendered nowhere at all — which is review finding I-2's
    /// second half, and is logic stranded where it cannot run. The copy lives here rather than in
    /// `App/` for the same reason `CustomRemoteURLError.message` does: `App/` has no test target,
    /// and the distinctions below are precisely the kind that erode into one generic sentence.
    ///
    /// Four genuinely different messages, and the differences are the point:
    ///
    /// - `.cloudNotLoaded` — the ordinary self-hosted user. **Not an error, and not a sales pitch
    ///   for Nabu Casa.** Someone whose Tailscale setup already works must not be told they need a
    ///   subscription.
    /// - `.notLoggedIn` — there is a cloud component but no account. Same destination, and the
    ///   subscription is named as *an* option rather than the fix.
    /// - `.noSubscription` — design §3's "don't nag": state the two ways to have remote access,
    ///   once, and stop.
    /// - `.indeterminate` — **claims nothing about the user's account**, because that is exactly
    ///   what we failed to establish. It says we couldn't tell, and that the custom address works
    ///   regardless.
    ///
    /// `.remoteAvailable` and `.remoteDisabled` return `nil`: the first needs no guidance, and the
    /// second is Task 3's offer, which owns its own copy.
    public var customRemoteURLGuidance: String? {
        switch self {
        case .remoteAvailable, .remoteDisabled:
            return nil
        case .cloudNotLoaded:
            return """
            This Home Assistant isn't set up with Home Assistant Cloud, which is completely normal. \
            If you reach it from outside your home another way, enter that address below and Haven \
            will use it when you're away.
            """
        case .notLoggedIn:
            return """
            No Home Assistant Cloud account is signed in on this Home Assistant. If you reach it \
            from outside your home another way, enter that address below — or sign in to Home \
            Assistant Cloud on your Home Assistant and Haven will pick it up automatically.
            """
        case .noSubscription:
            return """
            This Home Assistant Cloud account doesn't have an active subscription, so its remote \
            access isn't available. Remote access needs either that subscription or your own \
            address from outside your home — enter one below if you have it.
            """
        case .indeterminate:
            return """
            Haven couldn't tell whether this Home Assistant has remote access through Home \
            Assistant Cloud. If you reach it from outside your home some other way, entering that \
            address below works regardless.
            """
        }
    }
}
