# Connection & Remote Access Model — Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development to implement
> this plan task-by-task.

**Goal:** Implement the connection model in
`docs/superpowers/specs/2026-07-26-havenapp-connection-model-design.md` — local
network trusted, remote learned only over local, Nabu Casa bootstrap via
`cloud/status`, layered home detection.

**Architecture:** All *decisions* are pure functions in HavenCore (unit-tested);
`App/` only renders state and forwards intent. Branch: `feat/connection-model`.

**Tech Stack:** Swift 6 (strict concurrency `complete`), SwiftUI, iOS 26, Network.framework, Swift Testing.

## Global Constraints

- **Trust rule:** a remote URL may **only** be adopted when learned over a **local**
  connection. Never over a remote one. This is the whole security design.
- Local = `http` fine, tokens fine, HA responses genuine. Remote = **HTTPS always**.
- Wire shapes must be **verified against Home Assistant source**, never assumed.
  `cloud/status` fields are verified in the spec §3. Adding an unverified field to a
  decoder has caused three separate incidents in this project.
- No decision logic in `App/` — there is **no App-layer test target**, so anything
  there is unverifiable. Two overnight bugs shipped green because of this.
- **Never** contact a live Home Assistant. Unit tests against fakes only.
- No hardcoded colours (`App/DesignSystem/Theme.swift`); dark mode has regressed twice.
- Verify: `cd Packages/HavenCore && swift test`, then from repo root
  `xcodegen generate && xcodebuild -project HavenApp.xcodeproj -scheme HavenApp -sdk iphoneos26.5 -configuration Debug build CODE_SIGNING_ALLOWED=NO`.
  All 210 existing tests must keep passing. Run `xcodegen generate` after adding files under `App/`.
- Commit trailer: `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

---

## Task 1: The un-do — restore discovery, bound to local connections

**This is first because everything else depends on it, and it contains a silent-failure trap.**

**Files:** `Packages/HavenCore/Sources/HavenCore/Session/DiscoveredCandidateURLs.swift`,
`App/AppModel.swift`, `Packages/HavenCore/Tests/HavenCoreTests/ConnectionEndpointTests.swift`

**The trap — handle first.** `AppModel.purgeDiscoveredURLs()` is called at the top of
*every iteration* of `connect()`'s `while true` loop and unconditionally deletes
`discoveredInternalURL`, `discoveredExternalURL`, `lastWorkingURL`. Left in place
alongside re-enabled adoption it **wipes the URL just learned before the next round
reads it**, and the symptom is "remote never works" with no error. Replace it with a
**one-time migration** that clears overnight-era values once (a `UserDefaults` flag),
so a device upgrading from the overnight build re-learns cleanly.

**Steps:**
1. Rewrite `DiscoveredCandidateURLs.validating` to take the raw URLs **plus a
   connection-class parameter** (e.g. `learnedOver: ConnectionClass` — `.local`/`.remote`).
   Adopt `external_url` **only** when `learnedOver == .local`; force `https` on it.
   Adopt `internal_url` under the same rule. Returning nothing when learned remotely is
   the security property — document it as such.
2. Replace `purgeDiscoveredURLs()` with the one-time migration described above.
3. In `connect()`, pass the real stored values for `discoveredInternal`/`discoveredExternal`.
4. Restore `lastWorkingURL()`/`rememberWorkingURL()` and pass `preferredFirst`
   (removed in `c79f590` when there was only one candidate; there are several again).
   `ConnectionEndpoint.candidates` kept the parameter and tests.
5. Keep `forgetDiscoveredURLs()` on sign-out unchanged.
6. `ConnectionEndpoint.isNabuCasaHost` stays **classification only** (Nabu Casa ⇒ remote
   ⇒ forced HTTPS). It is **not** a trust check — that misuse was the C-1 incident.

**Tests:** external_url learned over `.local` is adopted and forced to https;
the identical URL learned over `.remote` is **not** adopted; internal_url same both ways;
migration clears overnight values exactly once; a hostile-looking host learned locally
*is* adopted (that is the accepted trust model — assert it deliberately so nobody
"re-fixes" it later).

---

## Task 2: `cloud/status` — Nabu Casa discovery

**Files:** create `Packages/HavenCore/Sources/HavenCore/Session/CloudStatus.swift`,
modify `Session/HomeConnection.swift`, `Protocol/WSMessages.swift`; tests alongside.

**Verified wire shape** (from `home-assistant/core`, `components/cloud/http_api.py`) —
command `cloud/status`, response fields used here: `logged_in` (Bool),
`active_subscription` (Bool), `remote_domain` (String?), `remote_connected` (Bool),
`prefs` (object). **`remote_domain` is a domain, not a URL** — the URL is
`https://<remote_domain>`. Decode defensively: missing keys must be distinguishable
from present-and-false (use optionals; do **not** default to `false`, that is the
`components: []` mistake again).

**Steps:**
1. `HACloudStatus: Decodable` with the fields above.
2. `WSCommand.cloudStatus(id:)` and `HomeConnection.fetchCloudStatus()` returning
   `Result<HACloudStatus, WSError>`.
3. A **pure** classifier. **Intent and state are different fields — do not conflate
   them.** Verified from `components/cloud/const.py`: `prefs.remote_enabled`
   (`PREF_ENABLE_REMOTE`) is *intent*; `remote_connected` is *current state*. So
   `remote_connected: false` does **not** mean remote is switched off — it is also
   the transient value while the tunnel is establishing or has dropped. Offering to
   "enable" an already-enabled tunnel would be wrong and confusing.

   Five cases:
   - `.remoteAvailable(URL)` — `active_subscription` && `prefs.remote_enabled` &&
     domain present. Adopt the URL **regardless of `remote_connected`** — a tunnel
     that is merely down right now may well be up by the time we need it.
   - `.remoteDisabled(domain: String)` — `active_subscription` &&
     **`prefs.remote_enabled == false`**. This, and only this, is Task 3's offer.
   - `.noSubscription` — logged in, no active subscription.
   - `.cloudNotLoaded` — `cloud/status` returned HA's `unknown_command`. **This is the
     self-hosted user, NOT an error** — it routes to the custom-URL path (Task 6).
     Getting this branch wrong sends a Tailscale user into a Nabu Casa dead end.
   - `.notLoggedIn` — `logged_in == false`. No cloud account at all; also Task 6.

   Also decode `prefs.remote_allow_remote_enable`
   (`PREF_REMOTE_ALLOW_REMOTE_ENABLE`): when false, HA refuses to enable remote
   access *from a remote connection*. We only ever offer it from a local one, so it
   should not bite — but decode and respect it rather than discovering it as an
   opaque failure.

**Tests:** all five outcomes; `unknown_command` maps to `.cloudNotLoaded` and never to
an error state; URL derivation prepends `https://` exactly once; missing `remote_domain`
with `active_subscription` true does not crash or produce a bogus URL; and specifically
**`remote_enabled: true` + `remote_connected: false` yields `.remoteAvailable`, not
`.remoteDisabled`** — the distinction that decides whether we offer to change the
user's Home Assistant configuration.

---

## Task 3: Offer to enable remote access

**Files:** `Session/CloudStatus.swift` (or sibling), `Protocol/WSMessages.swift`,
`App/Onboarding/` (reuse existing confirmation), tests.

`cloud/remote/connect` is a **mutating call against the user's Home Assistant.**
Route it through the **same confirmation component the guided installer already
uses** (`App/Onboarding/OnboardingModel.swift` — `confirmPendingMutation()` and the
`HavenOnboardingStep` confirmation copy). **Do not invent a second confirmation
pattern.** Read that code first and follow it.

**Steps:** add `WSCommand.cloudRemoteConnect(id:)`; add a step/mutation case for it
with confirmation copy naming exactly what will change; re-probe `cloud/status`
afterwards to verify it actually took effect rather than assuming success.

**Tests:** the mutation is unreachable without confirmation (mirror the existing
`mutatingStepsAlwaysRequireConfirmation` invariant test); a failed enable surfaces an
actionable message; success re-probes and advances.

---

## Task 4: Choosing local vs remote — three layers

**Files:** create `Packages/HavenCore/Sources/HavenCore/Session/ConnectionPreference.swift`,
modify `Networking/NWWebSocketConnection.swift`, `App/AppModel.swift`, plus a settings surface; tests.

**Steps:**
1. **Reduce the connect deadline from 8s to 2s** in `NWWebSocketConnection`
   (`deadline: Duration = .seconds(2)`). A LAN connect is sub-100ms; 8s was C2 review
   finding I-1 and is a dead spinner on foreign Wi-Fi. Update the existing timeout test.
2. **Pure candidate-ordering function** in `ConnectionPreference` taking: home-SSID match
   (`Bool?` — `nil` = unknown/not permitted), path class (`.wifi`/`.cellular`/`.other`),
   and the known URLs; returning the ordered candidate list. **All ordering logic lives
   here**, not in `AppModel`.
   - SSID matches home → local first.
   - SSID known and does not match → remote first.
   - SSID unknown + cellular → remote first (skip local).
   - SSID unknown + Wi-Fi → local first, then remote (the ~2s probe).
3. `NWPathMonitor` wrapper in `App/` reporting path class. Note it distinguishes Wi-Fi
   from cellular, **not home Wi-Fi from foreign Wi-Fi** — do not comment otherwise.
4. **SSID matching, optional and opt-in.** `NEHotspotNetwork.fetchCurrent()` needs
   Location Services authorization. **Never prompt during onboarding** — offer it in
   settings, framed as "connect faster at home." With permission absent the app must be
   fully correct via layers 2–3. Capture the home SSID automatically on a successful
   **local** connection (we know we were home), so the user never types it.
   Requires `NEHotspotNetwork` entitlement/capability — add to `project.yml` and
   `Info.plist` usage strings.

**Tests:** every branch of the ordering function; permission-absent behaves as
SSID-unknown; deadline change doesn't break the existing unreachable-host test.

---

## Task 5: Transport security

**Files:** `App/Resources/Info.plist`, `project.yml` if needed.

Replace blanket `NSAllowsArbitraryLoads` with **`NSAllowsLocalNetworking`**, making
"cleartext locally, HTTPS on the internet" OS-enforced rather than a convention.

**Known limitation — document clearly in the plist comment and the report.** ATS judges
the *hostname*, not the resolved IP: `NSAllowsLocalNetworking` covers unqualified
hostnames, `.local`, and private-range IP literals, but a FQDN like `hass.example.com`
resolving to `192.168.1.10` is treated as public and **would be blocked**. This cannot
be fully verified without a device — build must succeed; flag it as needing empirical
confirmation. If it proves to bite real setups, prefer a narrow exception over
reverting to arbitrary loads.

---

## Task 6: Custom remote URL (Tailscale / self-hosted)

**Files:** `App/` settings surface, `Session/` validation, tests.

Let the user enter their own externally-reachable URL. **HTTPS required** — reject
`http` with a clear explanation rather than silently upgrading. This is the destination
for `.cloudNotLoaded` and `.noSubscription` from Task 2.

**Tests:** `http` rejected with an actionable message; `https` accepted and classified
remote; a custom remote URL coexists with (and is ordered after) Nabu Casa if both exist.
