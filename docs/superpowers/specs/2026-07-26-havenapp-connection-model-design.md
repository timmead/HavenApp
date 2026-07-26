# HavenApp — Connection & Remote Access Model — DESIGN

Supersedes the connection posture in
`docs/superpowers/2026-07-26-overnight-run-report.md` §1 ("no URL from `get_config`
is ever auto-adopted"), which was a security position adopted overnight and has
since been **reversed by product decision**. That report remains accurate as
incident history; it is no longer the architecture.

Extends: `2026-07-25-havenapp-product-definition-design.md`.

---

## 1. Trust model

**Trust is bound to *where* a fact was learned, not to *what it says*.**

- The **local network is trusted.** Home Assistant's default is cleartext HTTP; we
  support that as a first-class configuration, not a degraded one. Tokens may cross
  it. Responses from HA over it (`get_config`, `cloud/status`) are treated as
  genuine. LAN-based man-in-the-middle is explicitly **out of scope**.
- The **internet is not trusted.** Remote connections are HTTPS-only, always.
- **Therefore: a remote URL may only ever be learned over a local connection.**

That last line is the whole security design. It is stronger than validating a URL's
shape, because it never requires us to determine *whose* Nabu Casa account a
hostname belongs to — a question that has no answer, and whose absence caused the
C-1 incident. A remote URL discovered while already remote is **never adopted**.

Encouraging users toward HTTPS locally is a future nicety. It must never block.

---

## 2. URL sources

| Source | Learned how | Scheme | Trusted because |
|---|---|---|---|
| **Local** | User types it during onboarding | `http` fine | They typed it |
| **Nabu Casa** | `cloud/status` → `remote_domain`, **local connection only** | `https` forced | Learned in the trusted zone |
| **Custom remote** | User types it (Tailscale, own reverse proxy) | `https` **required** | They typed it |

`internal_url` from `get_config` may also be adopted under the same
local-connection-only rule. Low value (the user already typed a local URL) but it
helps when their typed address is a DHCP-assigned IP that later moves. Optional.

---

## 3. Nabu Casa bootstrap — the happy path

Onboarding runs on the local network. Once connected and bootstrapped, issue
`cloud/status` (verified against Home Assistant core's
`homeassistant/components/cloud/http_api.py`).

Relevant response fields: `logged_in`, `active_subscription`, `remote_domain`,
`remote_connected`, `prefs`, `http_use_ssl`.

`remote_domain` is a **domain, not a URL** — the remote URL is
`https://<remote_domain>`.

Four outcomes, and they are genuinely different:

1. **`active_subscription` + `remote_connected`** → adopt `https://<remote_domain>`.
   Zero user input. This is the target experience.
2. **`active_subscription`, remote access disabled** (`remote_connected: false`) →
   the domain exists but the tunnel will refuse connections. Offer a one-tap fix via
   **`cloud/remote/connect`**, routed through the *same confirmation component the
   guided installer already uses* — it is a mutating call against the user's Home
   Assistant and must never run silently. Do not invent a second confirmation
   pattern.
3. **`logged_in` but no active subscription** → don't nag. Explain remote access
   needs either a subscription or a custom URL, and offer the custom-URL path.
4. **`cloud` component not loaded** → `cloud/status` returns HA's `unknown_command`.
   **This is not an error.** It is the self-hosted user, and the custom-URL path is
   the correct destination.

---

## 4. Choosing local vs remote

Three layers, each a fallback for the one above. **No layer is required for
correctness** — they trade latency for permissions.

### Layer 1 — Wi-Fi SSID match (optional, opt-in)

The mechanism the official companion app uses. On a matched home SSID → go straight
to local. Otherwise → straight to remote.

On iOS this needs Location Services authorization to read the current SSID
(`NEHotspotNetwork.fetchCurrent`). **It is offered as an optional upgrade, never as
an onboarding gate** — a permission prompt during first-run costs more than the
latency it saves, and "Always location" sits badly beside a local-first, privacy-led
product. Ask for it later, in settings, framed as "connect faster at home."

The home SSID is captured automatically on a successful local connection (we know we
were home), so the user never has to type it.

*Deferred:* BSSID matching for multi-AP networks with a shared SSID.

### Layer 2 — Network path class

`NWPathMonitor` (no permissions). On cellular → skip local entirely, go remote.

**This does not solve the general case** and must not be described as if it does: it
distinguishes Wi-Fi from cellular, *not* home Wi-Fi from a café's. On any foreign
Wi-Fi it still says "try local."

### Layer 3 — Fast local probe, then fail over

The universal fallback. Try local, then remote.

**Reduce the connect deadline from 8s to ~2s.** A LAN connect is sub-100ms; 8
seconds was the substance of C2 review finding I-1 and is a dead spinner on foreign
Wi-Fi. At ~2s the worst case becomes a brief stall.

---

## 5. Transport security

Replace the blanket `NSAllowsArbitraryLoads` in `Info.plist` with
**`NSAllowsLocalNetworking`**. This makes "cleartext on the local network, HTTPS on
the internet" an **OS-enforced property** rather than a convention our own code has
to remember — which is precisely the §1 trust model, checked by the platform.

**Known limitation, verify on device before relying on it.** ATS judges the
*hostname*, not the resolved address. `NSAllowsLocalNetworking` covers unqualified
hostnames, `.local`, and private-range IP literals — but a fully-qualified name like
`hass.example.com` that resolves to `192.168.1.10` is judged as a public host and
**would be blocked**. Confirm empirically; if it bites real setups, keep a narrow
exception rather than reverting to arbitrary loads.

Refresh tokens follow the same rule for free: cleartext locally is accepted (§1),
and cleartext to a public host becomes impossible rather than merely discouraged.

---

## 6. What must be UN-DONE from the overnight branch

The overnight work implemented the *opposite* posture. This is the concrete
reversal list. **The first item is a silent-failure trap** and must be handled
first.

1. **`AppModel.purgeDiscoveredURLs()` — delete, or reduce to a one-time migration.**
   It is currently called at the top of *every iteration* of `connect()`'s
   `while true` loop and unconditionally deletes `discoveredInternalURL`,
   `discoveredExternalURL` and `lastWorkingURL`. Left in place alongside
   re-enabled adoption, **it wipes the URL we just learned before the next round
   reads it** — and the symptom is "remote never works," with no error anywhere.
2. **`DiscoveredCandidateURLs.validating`** currently adopts nothing by
   construction. This is where the new rule belongs — it is the pure, tested
   function, and the `learnedOverLocalConnection` flag is exactly the kind of
   decision that must not live in untested `AppModel`.
3. **`AppModel.connect()`** passes `discoveredInternal: nil, discoveredExternal: nil`
   — restore real values.
4. **`lastWorkingURL` / `preferredFirst`** (removed in `c79f590` as vestigial) —
   becomes useful again once there is more than one candidate.
   `ConnectionEndpoint.candidates` kept the parameter and its tests for this.
5. **`ConnectionEndpoint.isNabuCasaHost` — keep, but only for *classification***
   (a Nabu Casa host is remote, therefore forced HTTPS). It is **not** a trust
   check; that misuse was the C-1 finding. Its documentation already says so.
6. **`forgetDiscoveredURLs()` on sign-out — keep.** Still correct.

**Migration:** a device that ran the overnight build may hold URLs written under the
old rules. Treat stored values as needing one re-learn over a local connection
rather than trusting them; simplest is to clear once on upgrade and re-discover.

---

## 7. Testing

Everything in §1–§4 that constitutes a *decision* goes in HavenCore as pure
functions and is unit-tested. `App/` has no test target; logic placed there is
unverifiable, which is how two overnight bugs shipped green.

Specifically testable: the adopt/reject rule keyed on connection class; the four
`cloud/status` outcomes of §3, including `unknown_command`; candidate ordering
under each of the three §4 layers; and URL derivation from `remote_domain`.

**Wire shapes are verified against HA source, not assumed** — `cloud/status` from
`cloud/http_api.py`. Do not add a field to a decoder without checking it exists;
that error class has cost this project three separate incidents.

---

## 8. Open items

- Empirical check of the `NSAllowsLocalNetworking` FQDN case (§5).
- BSSID matching for shared-SSID multi-AP homes (§4.1).
- Prompting users toward local HTTPS (§1) — non-blocking, later.
