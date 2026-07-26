# Overnight run — morning report

Branch: `feat/overnight-c-onboarding-d2` (not merged — waiting on your review)

> **SUPERSEDED IN PART (2026-07-26, by user decision after reading this report).**
> §1's conclusion — "no URL from `get_config` is ever auto-adopted" — is **no longer
> the design.** The user has set the trust boundary at the network edge: the local
> network is trusted, remote-URL discovery happens there, and `get_config` /
> `cloud/status` responses learned over a local connection are treated as genuine.
> The threat this report hardened against (a LAN attacker injecting a remote URL)
> is accepted as out of scope. Read §1 as an incident history, not as current
> architecture. Anything implementing "adopt nothing" is implementing the old
> posture.

**All four tracks are complete, and the branch has been through an adversarial
whole-branch review with every finding either fixed or escalated to you.**
210 tests passing, app builds clean. Every test count and build result below I ran
myself rather than taking an agent's word for it.

The branch is **not merged** — that's your call, and I'd want you to read §1 and
§1b first.

### Suggested order when you sit down

1. **Answer the Nabu Casa question** (§1 below) — it's the only one that could
   invalidate work already done.
2. **Run the guided install live.** It's the one thing I deliberately never
   executed, and the whole onboarding track is unproven until you do.
3. **Ten minutes with VoiceOver on**, to check the accessibility pass is real
   rather than merely compiled.
4. **Read the Media/Camera design proposal** and answer the four questions in it.
5. Then decide on merging the branch.

---

## Read this first — three things need you

### 1. A security bug was found and fixed. It has a piece you must decide.

Reviewing the remote-access work turned up a real vulnerability in code I'd
written earlier the same night. Home Assistant's `get_config` returns an
`external_url`, and I was trusting it straight off the wire: persisting it and
then sending your **refresh token** to it. Because the default connection is
cleartext (`http://homeassistant.local:8123`) and the app allows arbitrary loads,
someone with temporary access to your LAN — a guest, a compromised IoT device —
could have injected their own URL and quietly received your Home Assistant
credentials later, once your phone was on cellular. A one-off network position
would have turned into lasting account access.

Partially fixed in a first round (commit `43043c2`): a discovered remote URL is
now auto-adopted only when it's a genuine `*.ui.nabu.casa` host, and URLs already
stored on disk are re-validated (an earlier build of tonight's branch could have
saved a hostile one).

**It took three rounds to actually close, and I got it wrong twice.** This is the
most useful thing in this report, so it's worth the detail:

- **Round 1** validated `external_url` — and missed that `get_config` returns
  *two* URLs from the same interceptable response. `internal_url` was persisted
  unchecked, read back unchecked, and treated as a local candidate regardless of
  what host it named, tried *ahead of the URL you typed yourself*. The attack
  still worked, slightly better, through the adjacent field. I caught that one.
- **Round 2** closed `internal_url`. I then audited the input set, satisfied
  myself it was complete, and told you the vulnerability was closed.
- **Round 3 — the final review broke my claim, and it was right.** The check I'd
  been relying on, `hasSuffix(".ui.nabu.casa")`, proves a host is **a** Nabu Casa
  instance. It does not prove it's **yours**. Nabu Casa is a cheap consumer
  subscription — so an attacker just buys one, injects *their own* perfectly
  genuine `<uuid>.ui.nabu.casa` address, and it sails through. I'd validated a
  category and treated it as an identity.

The real fix, now landed and verified by me (`310ac0c`): **no URL from `get_config`
is ever auto-adopted.**
Not the external one, not the internal one. There is no property of a URL arriving
over an attacker-controlled channel that proves it belongs to your instance — and
we can't check the instance's identity first, because the token goes out *before*
the socket opens. Trust has to come from outside that channel, which means from
you. Remote access comes only from a URL you entered.

Two things this cost, both worth internalising:

1. **My verification gap was the root cause, not the specific bug.** Round 1's
   tests exercised the host-check *function*, while the code deciding which URLs
   become connection candidates lived in `AppModel`, which has no test target. 107
   green tests never executed the fix. See §3.
2. **I twice declared this closed when it wasn't.** Both times I had a real
   argument for why. Treat my "this is now secure" with appropriate suspicion —
   the adversarial review found in one pass what I'd missed in two.

**What I need from you:** remote access now comes only from a URL you type.

- **Do you actually have a Nabu Casa subscription?** The product spec assumes it,
  but I can't find where you confirmed it. If you don't, the entire remote path is
  untested and unexercised.
- If you use a **custom** remote URL (DuckDNS, your own reverse proxy, Tailscale),
  it now works the same way as Nabu Casa — you enter it. That's the *only* trusted
  path, so the earlier "custom URLs are locked out" problem dissolves.

### 1b. A second security decision that is genuinely yours

The token-refresh work (C1) means your **refresh token now goes over the wire
roughly every 30 minutes**. On the default configuration that wire is cleartext
`http://homeassistant.local:8123`. Before this branch, `oauth.refresh` had no
caller at all, so the token never left the Keychain — this is a real regression
introduced by a feature you do want.

Anyone passively sniffing your LAN could capture it, and a refresh token is
long-lived. Three options, and I deliberately didn't pick one for you at 3am:

1. **Accept it** — it's your own LAN, and the official HA app is no better.
2. **Warn** — connect over cleartext but tell the user plainly what it means.
3. **Require HTTPS for token operations** — safest, but breaks the default
   out-of-box local setup unless you have TLS on your HA.

My recommendation is (2) now and (3) as a setting, but this is a product call
about your own network and I'd rather you made it.

### 2. Nothing was run against your live Home Assistant. On purpose.

I told you I wouldn't trigger a live HA restart or HACS install overnight, and I
didn't. The onboarding install flow is built and unit-tested against a fake
connection only. **The one live run is yours to make** — it downloads code and
restarts the server your house runs on.

### 3. A structural gap worth naming

There is **no App-layer test target**, so `AppModel` — which holds the entire
connection state machine — has zero automated coverage. `swift test` passing and
`BUILD SUCCEEDED` can both be true while a bug in that file ships. I worked
around it tonight by pushing logic down into HavenCore where it *is* testable
(that's why the security predicate lives in `ConnectionEndpoint`), but the gap is
real and will keep biting. Worth a small task to add the target.

---

## Shipped

**Sub-project C — the connection engine is now production-grade.** Six commits,
113 tests (up from 57), build green. I verified the tests and build myself rather
than taking the agents' word for it.

*C1 — token refresh and reconnection.* Access tokens now refresh automatically
before they expire, with concurrent callers coalescing into a single refresh
instead of stampeding. The old hard 5-try reconnect cap is gone — it meant a
router reboot longer than ~30s left the app permanently dead until you
force-quit it — replaced with unbounded backoff. Review caught two critical bugs
here: a socket leak that pinned ~120 sockets an hour during an outage, and a
cancelled connect loop that could overwrite a sign-out and wipe a
freshly-signed-in session's keychain. Both fixed.

*C2 — Nabu Casa remote access and local/remote failover.* The app now learns your
instance's remote URL, orders candidates local-first, and fails over to remote
when you're away — with an 8-second connect deadline so an unreachable LAN
address doesn't stall the whole thing. Plus the security work described above.

**Onboarding detection (ON-1) — done.** The app can now tell, precisely, why it
can't reach the `havenapp` integration, and say something actionable instead of
failing generically: HACS missing, integration not downloaded, downloaded but no
config entry (your known gotcha), integration too old, *app* too old, or you're
signed in as a non-admin. 38 new tests.

Two corrections I made to it are worth knowing about, because both were cases
where the first answer looked right:

- A non-admin household member with the integration missing would have been walked
  through a HACS install they *cannot perform* — HACS needs admin. The agent had
  concluded admin status was unknowable until the integration answers; it isn't,
  because HA's stock `auth/current_user` reports it to anyone signed in.
- **My own instruction caused a bug.** I asked for `components` to have "a safe
  default so existing tests don't break," which produced `[]`. But `[]` is
  indistinguishable from "the field wasn't there," and the whole gate is
  `components.contains("havenapp")` — so if our reading of `get_config` is wrong,
  *every correctly-installed user* would have been confidently told to go install
  HACS. No test could have caught it, since the tests supply that list directly.
  It's now an explicit "I couldn't determine this" state that logs loudly.

**Guided install (ON-2) — done, and never run.** The app now walks a user through
getting `havenapp` installed, re-probing after every step to confirm it actually
landed rather than claiming success on faith. Every step that changes anything on
your server — adding the repo to HACS, downloading it, restarting — sits behind an
explicit confirmation naming exactly what will happen. That's structural, not
convention: there's a single code path to the mutating calls and a test that fails
if any step bypasses it. 44 new tests.

Two real defects were caught building it, both worth knowing:

- **The app had no reconnect path at all.** Once connected, nothing watched for the
  socket dropping — so the restart step would have stranded you on "waiting for
  Home Assistant" with sign-out as the only escape. This was a latent bug in the
  existing code that the restart step merely exposed; it's now fixed properly by
  re-entering the normal backoff loop.
- **`hacs/repositories/list` returns everything HACS *knows about*, not what's
  downloaded.** Using it naively would have flipped the verdict to "just add the
  config entry" the instant the repo was added — sending you to a config-flow link
  for files that didn't exist yet.

**D.2, the already-approved half — done.** The light modal now has the
colour-temperature bar (bounds read from each light's own reported min/max kelvin
rather than hardcoded, so we don't send values HA silently clamps), and the
accessibility gap the D spec called out is closed: labels across tiles and modals
carrying *state in text* rather than only colour, `HavenSegmented` rebuilt on real
`Button`s so it has button traits, and adjustable actions on the sliders so a
VoiceOver user can actually change brightness, position and colour temperature
instead of just hearing them.

One caveat: **nobody has run VoiceOver against this on a device.** It builds and
the logic is unit-tested, but an accessibility pass verified only by compilation is
a claim, not a result. Worth ten minutes with VoiceOver on before we call it done.

Two smaller judgment calls I made and you may want to revisit: a rejected token
is no longer trusted from a *single* address (a rogue device on your LAN could
otherwise bait a sign-out), and `403`/`401` from a reverse proxy is no longer
treated as "your credentials are dead" — the old behaviour wiped your keychain
on what was often a transient proxy hiccup.

## Staged for your review

**Media Player + Camera renderer designs** —
`docs/superpowers/specs/2026-07-26-havenapp-d2-media-camera-design-proposal.md`

Written, **not built**. Both renderers break the shape you approved for the other
nine — a media player's primary action is play/pause rather than on/off, and a
camera has no controls at all — so they need your eye before code. Building first
would just buy rework.

Four questions in there, but the two that change the most:

- **Do you have cameras, and which integration?** If not, Camera drops well down
  the list and I'd rather spend that time on the entity-curation problem you
  raised — hundreds of entities showing by default affects every screen.
- **Do you group speakers (Sonos/AirPlay multi-room)?** I've *excluded* grouping
  from v1 as its own design problem, but if you group routinely that call is wrong
  — it'd be the most valuable part rather than a deferral.

I also flagged one deliberate deviation from the visual language: a camera showing
a live stream should say so. It's the only entity type where the user not knowing
it's active is a real problem rather than a cosmetic one.

**One prerequisite worth knowing about:** both renderers need authenticated image
loading, which the app has none of today — `AsyncImage` can't attach a bearer
token, so it would silently 401 and render a blank tile that looks like a working
camera with nothing to show. It also has to read its URL from `TokenProvider`
rather than capturing it once, or it'll point at the wrong host after tonight's
local/remote failover kicks in. That loader should be built and tested on its own,
first.

## Parked (blocked on you, not guessed)

- Custom (non-Nabu-Casa) remote URL support — needs a user-confirmation flow.
- Whether guided install should auto-add our repo as a HACS *custom repository*,
  or require you to add it manually. Auto-add is nicer but means the app writes
  to HACS's own configuration. **It's built, but never automatic** — it sits behind
  a confirmation stating plainly that HACS's own config will change and that no
  files are downloaded by that step. I still want your explicit yes/no before it
  ships.
- One wording call worth sanity-checking: I read "restart is the final step" as
  "the final *mutating call*", so the order is add → download → restart → *then*
  the config entry. Read the other way it can't work — Home Assistant won't offer a
  config flow for an integration it hasn't loaded, so the deep link would dead-end.
- The HACS docs link is the stable root `https://hacs.xyz` rather than a deep path
  I couldn't verify without network access. Swap in something more specific if you
  have one.

## A scope call I made on guided install — yours to revisit

You asked for "the whole flow including guided install." I've sequenced it so the
**guided deep-link flow comes first**: the app walks you through the steps,
re-probing after each one to verify it actually landed, and hands off the
privileged actions to Home Assistant's own UI via `my.home-assistant.io` redirects
rather than driving them itself.

That isn't a narrowing — it's the path the automated version needs as a fallback
anyway, since automation can't work for a non-admin user, an older HACS, or a
download that fails midway. Building it first is right regardless of how you want
the automated half to go.

I also **verified HACS's actual WebSocket command names and payloads from its
public source** rather than guessing them. That was worth doing: my own first
draft of the brief named the list command `hacs/repositories` — which doesn't
exist. The real ones are `hacs/repositories/list`, `hacs/repositories/add`, and
`hacs/repository/download` (note the singular/plural split, which would have been
a silent no-op). The list returns `full_name` and an `installed` flag, so
"downloaded but no config entry" is now precisely detectable rather than inferred.

Those verified shapes de-risk the automated install considerably. It's still your
call whether the app should write to HACS's own configuration to add our repo as a
custom repository — that's the parked question below.

## What the final review fixed (beyond the Critical in §1)

An adversarial whole-branch review found 1 Critical, 5 Important, 7 Minor. The
Critical is §1. Of the rest, four were fixed and one escalated to you (§1b):

- **Nothing watched for the connection dropping.** Once connected, a dropped socket
  left the dashboard silently frozen on stale state — *including lock status* —
  while commands quietly no-oped, and the new local/remote failover never engaged
  when you left the house. This was pre-existing, but the whole C2 track was
  predicated on it working.
- **A restart that succeeded could be recorded as failed**, if Home Assistant's
  shutdown beat the reply frame — stranding the app on a dead socket with no
  recovery path.
- **The "can't determine what's installed" screen blamed us for a dropped
  connection**, telling users to report a bug that was just a network blip.
- **A modal-header accessibility container likely produced duplicate VoiceOver
  stops** — the exact redundancy its own comment claimed to remove. The fix is
  verified against SwiftUI's documented semantics only; like the rest of the
  accessibility work, **nobody has confirmed it with VoiceOver or Accessibility
  Inspector on a device.**

The review also confirmed as genuinely sound: the three connection-loop concurrency
invariants, the confirmation gating on every mutating action (single call site,
nothing auto-runs on launch), and the continuation handling.

## Scope I did NOT get to

One item from the original three-track plan never ran, and I'd rather name it than
let it disappear:

- **C3 — deferred connection-robustness items**: subscription task cancellation,
  and the heartbeat id-echo stall. The reconnect fix from the final review
  (§"What the final review fixed") probably subsumes part of the first, but the
  **heartbeat id-echo stall is untouched**. Not deferred by decision — I ran out of
  night. Scaling scope down is your call, not mine, so it's yours to re-prioritise.

## Known follow-ups (found, deliberately not fixed overnight)

- **Revoked token while away from home leaves the app spinning.** Fixing the
  "rogue LAN device baits a sign-out" issue meant requiring *every* candidate to
  independently report an invalid token before actually signing you out. But when
  you're away from home, the local candidate fails by *timeout*, not by rejecting
  the token — so the count never completes, and a genuinely revoked token leaves
  the app retrying forever instead of asking you to sign in again. Reproducible:
  revoke the token in HA while off your LAN. It fails in the safe direction (it
  won't wipe your credentials on ambiguous evidence), so I left it rather than
  widening an in-flight security fix. Worth a small follow-up.
- **No App-layer test target** — see §3 above. This is the highest-value cleanup.

## Needs live verification by you

- The `havenapp` guided install + HA restart path (never run).
- Remote failover end-to-end — requires actually leaving the LAN.
- `get_config`'s wire shape for `internal_url`/`external_url`: I coded against
  the documented shape but never saw a live response. I added a warning log for
  the case where both decode to nil, so if my assumption is wrong it now fails
  loudly instead of silently doing nothing.
