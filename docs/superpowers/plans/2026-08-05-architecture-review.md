# Architecture & Design Review — 2026-08-05

**Scope:** the whole codebase at the functional milestone — `App/` and `Packages/HavenCore/`,
~35,500 lines of Swift including tests. Nothing has shipped, so schemas and data models are still
free to change. This review names what to change deliberately before more is stacked on top, and
what to leave alone on purpose. It succeeds `2026-07-27-architecture-review.md`, whose items are
all closed; nothing here re-litigates them.

**Baseline at review time (verified before any conclusion was written):**

| Suite | Command | Result |
|---|---|---|
| HavenCore | `swift test --package-path Packages/HavenCore` | 788 tests, 18 suites, passed in 8.1s |
| HavenApp | `xcodebuild test -scheme HavenApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` | 107 tests, 21 suites, **TEST SUCCEEDED** |

---

## Headline

**The load-bearing property still holds.** *Policy lives in HavenCore under test; `App/` glues and
renders* was the July review's headline, and three weeks of feature work — tile membership, sizes,
deferred save, batched history, composite devices, roles, the device model — have not eroded it.
HavenCore's internal layering is genuinely one-directional (`Support/Protocol` → `Networking` →
`Models` → `Domain` → `Session`), the domain model is value types throughout with actors only where
there is a live connection or in-flight work, and there is not a single `import SwiftUI` or
`import UIKit` in the package. The wire protocol, trust model, and dashboard schema are the three
most careful pieces of design in the codebase, and all three are the right kind of careful.

**The architecture is the right one; do not change it.** What the app practices is store-driven
SwiftUI (shared `@Observable` stores in the environment, no per-screen view models) over a
Clean-ish core package. Verdict against the alternatives: **fit.** TCA is ruled out by the
no-third-party-dependencies constraint and would re-house logic that already has a tested home;
per-screen MVVM would interpose objects between views and *shared live state* (every screen renders
the same `states` dictionary — a view model per screen would forward or copy it); MVI's
serialized-transition benefits are already delivered where they matter by the pure state machines
in Core (`HavenOnboardingFlow`, `NabuCasaRemoteAccessDetector`, `ConnectionClass`). The refactoring
exercise below is therefore **decomposition and lifetime work inside the existing pattern**, not a
pattern migration.

The debt is again concentrated, and again mostly in two files — the same two. `AppModel.swift`
(780 → 1,001 lines since July) and `HomeStore.swift` (560 → 880) have both regrown past their
reviewed sizes by accretion of exactly the feature work the specs describe. That is not a process
failure — the features landed with tests and their policy in Core — but it is the signal that the
next seams are due. And one structural problem exists that the July review could not have seen,
because the objects it lives in did not exist yet: **session lifetime is implicit** (F1), and it
has already produced one real, if small, bug.

---

## Findings

Ordered by severity × leverage. None were landed during this review; this document is the plan.

### F1 — Session lifetime is implicit; the live connection is copied into five nilable slots

When a candidate wins, `AppModel.attemptCandidate` builds `HomeConnection` (`App/AppModel.swift:662`)
and hands it out to five holders, each keeping its own `private var connection: HomeConnection?`:
`HomeStore` (`HomeStore.swift:25`), which forwards to `HistoryCache` (`HistoryCache.swift:68`) and
`HavenConfig` (`HavenConfig.swift:35`), plus `OnboardingModel` (`OnboardingModel.swift:36`) and
`RemoteAccessOfferModel` (`RemoteAccessOfferModel.swift:42`) attached directly. Alongside them,
`tokenProvider` and `imageLoader` (`AppModel.swift:166,190`) are two more per-session objects with
their own create/nil-out choreography in `beginSession`/`signOut`/`requireReauthentication`.

There is no single source of truth for "there is a live session." Every long-lived object instead
has an `attach(_:)`/`reset()` lifecycle, and correctness depends on every call site remembering
every step in the right order under cancellation. It has already been forgotten once:
`remoteAccessOffer.attach(home)` (`AppModel.swift:833`) is the only post-connect step in
`finishConnecting` with no preceding `!Task.isCancelled` check — its siblings at 802, 818, 828 and
854 all have one — so a connect cancelled mid-finish can leave `RemoteAccessOfferModel` holding a
connection for a session that was already torn down. That bug is not interesting; the *class* is.
Each new session-scoped feature (onboarding, remote access, image auth…) has added another slot and
another teardown step, and the next one will too.

> **Correction — 2026-08-05, from reading the code directly during execution.** Two claims above
> are overstated, and the July review's habit of recording its own corrections applies here.
>
> **"Five independently-nilable slots" overstates the sprawl.** There are five slots but only
> *three* `attach` call sites: `HomeStore.attach` (`HomeStore.swift:49-54`) fans out to
> `HistoryCache` and `HavenConfig` itself, at one call site, with a comment saying that is
> deliberate — "One call site rather than three, so a new seam cannot be left holding a stale
> connection from the previous session." The two genuinely separate attaches are `onboarding` and
> `remoteAccessOffer`, both in `finishConnecting`.
>
> **"No single atomic connected transition" implies teardown is unreliable; it is not.** All four
> children clear their own connection on reset — `HistoryCache.swift:73`, `HavenConfig.swift:44`,
> `OnboardingModel.swift:58`, `RemoteAccessOfferModel.swift:70` — and `HomeStore.reset` calls every
> one of them. Checked individually, not inferred.
>
> **What survives is real but smaller:** the missing `!Task.isCancelled` guard on line 833 (a
> one-line fix), and the genuine hand-maintenance of `baseURL` + `tokenProvider` + `imageLoader` +
> `hasConnectedSinceSignIn` across `beginSession`/`signOut`/`requireReauthentication`.
>
> **And one thing the review missed entirely: there are two lifetimes here, not one.** The
> *sign-in session* (token provider, image loader, `hasConnectedSinceSignIn`, and onboarding's
> accumulated knowledge) outlives the *connection*, which is replaced on every reconnect.
> `AppModel.onboarding`'s own doc comment (`AppModel.swift:86-90`) makes this a hard constraint:
> it is "created once and re-`attach`ed on every reconnect rather than rebuilt", because the
> restart step deliberately kills the socket and what the flow already knows has to survive it.
> **A `HomeSession` that conflates the two would break guided onboarding.** It must model the
> sign-in session, holding the connection as a property that changes beneath it.
>
> **Re-prioritise accordingly:** F1 drops from flagship to a modest cleanup plus a one-line bug
> fix. F2 and F5 become the highest-value remaining work.

**Proposal: make the session an object.** One type — call it `HomeSession` — created only after a
candidate wins, owning what exists exactly as long as a connection does: the `HomeConnection`, the
`TokenProvider`, the `AuthenticatedImageLoader`, and the session-scoped models. `AppModel.phase`
becomes the only place a session lives (`case ready(HomeSession)`), teardown becomes "stop
referencing it," and `attach`/`reset` disappear as a pattern. This is the same shape that already
worked once at smaller scale: `Navigation` is `@State` on `DashboardView` precisely so sign-out
destroys it in passing (July review, P3 — "the coupling disappears"). F1 is that idea applied to
everything else with a session lifetime.

This is the flagship refactor: highest leverage, and the one that gets harder with every feature
added. It touches the trust wiring in `finishConnecting`, so `AppModelTrustTests` must be
mutation-checked afterwards (drop `ssidMatch` from the call, watch it fail), and it changes what
views reach through the environment, so it is also the moment to decide `@Environment(HomeSession)`
vs. keeping the `AppModel` façade. Verification: `AppModelSessionTests`, `DisconnectSignalTests`,
`ConnectLoopTests`, plus sign-out / reauth / mid-session-reconnect exercised on a device.

### F2 — `HomeStore` has re-accreted three jobs (560 → 880 lines)

The July split left `HomeStore` holding two jobs: what Home Assistant said, and command dispatch
over it. Since then it has grown three more, each traceable to a feature arc:

| Job | Evidence | Arrived with |
|---|---|---|
| Device/composite directory | `device`, `deviceType`, `bindings`, `createDevice`, `removeDevice`, `setRole`, `bindableEntityIds`, `deviceState`, `roomEntityIds` (`HomeStore.swift:282–374,697–724`) | device model / roles / composite state (2026-08-04 specs) |
| Config façade | ~15 pass-throughs to `HavenConfig`: `nominate`, `setOrder`, `rename`, `span`, `stateStyle`, `applyTileConfig`, `setMembership`… (`143–275`) | tile membership / size / deferred save |
| Per-domain command surface | ~35 methods across lights, locks, covers, climate, media, scenes; three optimistic primitives (`optimistic` 417, `fireAndForget` 451, `optimisticState` 652) | accumulating since the spike |

**Proposal, in order of value:**

1. **Extract the device directory** (`DeviceDirectory`, owned by `HomeStore` the way `HistoryCache`
   is). It is the newest code, the most likely to keep growing (the device-model spec explicitly
   generalizes it), and self-contained: its tests (`AddableDeviceTests`,
   `RoleBindingPersistenceTests`, `CompositeStateTests`) map onto it one-to-one.
2. **Split the command surface by domain** into extensions of one type (or files:
   `HomeStore+Lights.swift`, …) and **consolidate the three optimistic primitives into one** with
   an explicit mode. The `unavailable`-guard comment at `HomeStore.swift:429–436` records that this
   consolidation is already half-done; finish it. `UnavailableCommandGuardTests` pins the guard in
   both directions and must stay red-capable.
3. **Leave the config façade alone.** The pass-throughs are boring, but they are the observation
   seam — views reading `store.span(of:)` observe through one object — and July's lesson stands:
   observation-granularity changes are the silent failure mode. Any move here extends
   `ObservationTests` first, per move, and the existing suite has proven it bites (one
   `@ObservationIgnored` turns exactly one test red).

### F3 — `AppModel` has re-accreted endpoint memory (780 → 1,001 lines)

The phase machine and candidate loop are fine — L3/P1 from July landed and held. What grew is
**URL/endpoint persistence policy**: `DefaultsKeys`, `storedURL`, `savedBaseURL`,
`rememberDiscoveredURLs`, `rememberNabuCasaRemoteAccess`, `saveCustomRemoteURL`,
`clearCustomRemoteURL`, `forgetDiscoveredURLs` (`AppModel.swift:7–19,859–1000`) — ~200 lines of
"which URLs do we remember, and on whose authority" sitting on the same object as connect
orchestration and OAuth.

**Proposal:** extract an `EndpointMemory` type owning the `DefaultsKeys` schema and every
remember/forget decision, constructed from the injected `defaults` and the Core validators it
already delegates to (`DiscoveredCandidateURLs.validating`, `NabuCasaRemoteAccessDetector`).
`AppModel` keeps the phase machine, the candidate loop, and auth. The trust property is unchanged —
the validators stay in Core — but `AppModelTrustTests` pins the wiring and gets the same
mutation check as F1.

### F4 — Two concurrency defects, one real and one structural

1. **`WebAuthPresenter.authenticate` can hang a task forever.** It wraps
   `ASWebAuthenticationSession` in `withCheckedThrowingContinuation` with no cancellation handler
   (`App/WebAuthPresenter.swift:7–19`); if the awaiting task is cancelled while the sheet is up,
   the continuation is never resumed. Fix outright with `withTaskCancellationHandler` cancelling
   the session (which fires the completion with an error). Small, standalone, first.
2. **Fire-and-forget command `Task`s outlive `reset()`.** `optimistic`, `fireAndForget`,
   `optimisticState`, `toggleLock`, `openCloseCover`, and `BulkActionRunner.run` each spawn an
   untracked `Task`; `reset()` cancels only `subscriptionTask` (`HomeStore.swift:111–123`). The
   rollback guards mean a late completion cannot write a *wrong* value, but nothing stops it
   writing into a store whose session ended. F1 gives these a natural home — command tasks scoped
   to the session object, cancelled by teardown — so fold this into F1 rather than fixing it
   separately. Respect the `BulkActionRunner` comment (`BulkActionRunner.swift:59–70`): its shape
   is a documented compiler-limitation workaround; do not "tidy" it.

### F5 — The UI duplication the tile pass didn't reach

July's P4 gave the tiles `TileLabel`/`TileEmphasis`, and its closing notes flagged the modals as
"the same shape, one layer up." That pass never happened, and the media/climate/composite arcs
have since added duplication of their own:

- **The drag-commit slider is implemented five times**: brightness and kelvin in
  `LightModal.swift:43–102`, cover position in `CoverModal.swift:28–50`, volume in
  `MediaPlayerTile.swift:287–319` and again in `MediaPlayerModal.swift:262–283` — the last pair
  kept in sync by a comment that says "written to match … line for line … so the two cannot
  drift." A comment doing a component's job. Extract one `CommitSlider` (drag state, commit on
  release, `accessibilityAdjustableAction`) and delete four copies.
- **The gesture/accessibility footer is copy-pasted across tiles**: `.contentShape` /
  `.onTapGesture` / `.onLongPressGesture(0.35) { navigation.open }` / `.accessibilityAction`
  identical but for the accent in `SwitchTile`, `LightTile`, `LockTile`, `CoverTile` (e.g.
  `LockTile.swift:32`, `CoverTile.swift:55`). One `tileInteraction(entityId:)` modifier.
- **`unavailable`/`unknown` pair extraction** copy-pasted with its explanatory comment into four
  modals (`LightModal.swift:32`, `ClimateModal.swift:20`, `LockModal.swift:37`,
  `CoverModal.swift:17`).
- **A business rule lives in two view files**: "turning climate on picks the first non-off mode,
  else heat" appears in `ClimateTile.swift:337–340` and `ClimateModal.swift:28`. That is a Core
  decision (`ClimateState.modeWhenTurningOn`) wanting one tested home — the exact migration this
  codebase has done a dozen times.
- **`rollupRow` is duplicated** between `RoomDetailView.swift:136–181` and
  `RoomSectionView.swift:146–183`, acknowledged by a "Mirrors…" comment.

Verification for all of the above is the July method: `TileGallery` rendered before and after,
compared by eye, both themes. It exists precisely for this.

### F6 — `DesignSystem/` is not the leaf layer its name claims

`ConfigurableTile` reads `@Environment(HomeStore.self)` and `@Environment(Navigation.self)`
(`DesignSystem/ConfigurableTile.swift:38–47`); `Theme.swift:33` switches on Core's `Domain` and
`ClimateState.Function`; half the directory imports HavenCore and traffics in `TileSpan`/entity
ids. Harmless today — but sub-project E (iOS surfaces: widgets, watch) will want the chrome
*without* `HomeStore`, and a WidgetKit extension cannot have one. **Proposal:** split the directory
into `DesignSystem/` (generic: `PipSlider`, `Chip`, `FlowRow`, `GlassTile`, `SegmentedControl`,
`FittedSheet`…) and `Renderers/Chrome/` (app-coupled: `ConfigurableTile`, `EntityPickerRow`,
`TileKindFilter`…), and treat "imports HomeStore" as the membership test. A file move plus
`xcodegen generate`; do it when F5 is already touching these files.

### F7 — Pre-ship liberties worth taking now (and the ones not worth taking)

The user-facing schemas are the one thing that becomes expensive the day something ships. Reviewed
with that lens:

- **The dashboard schema is in good shape — keep it.** Merge-don't-overwrite on a raw `JSONValue`,
  the `declaredSchema <= schema` write gate, and optimistic-concurrency-as-value
  (`HavenConfigWrite.versionConflict`) are the right bones for a multi-writer future. The decision
  *not* to make `DashboardDocument` Codable is load-bearing; the doc comment says why.
- **Delete the vestigial `bindingsKey`** (`DashboardDocument.swift:37`) — declared, never used, a
  leftover from the superseded `entities.<id>.bindings.<role>` storage design that
  `devices.<id>.inputs` replaced. Dead vocabulary in a schema file misleads precisely the person
  reading it to learn the schema.
- **`deviceState(of:)` contradicts its own comment.** The comment says it is "read when a modal
  opens rather than per frame" (`HomeStore.swift:697–713`), but `SwitchTile` and `CoverTile` call
  it in `body` (`SwitchTile.swift:19,29,36`), so it runs for every visible switch/cover tile on
  every state push. Either the comment is stale or the call sites are wrong; reconcile — and if
  the tier-flattening cost ever matters, this is where it will show.
- **HavenCore's public-by-default surface: accept, note, don't fix.** One consumer, exhaustive
  tests, heavy doc comments. An access-control pass would churn 65 files for no behavior change.
  Revisit only if the package gains a second consumer (widgets would be that moment).
- **Leave `states` as one dictionary.** The July correction stands, pinned by
  `ObservationTests.readingOneEntityObservesEveryOtherEntityToo`: bodies are cheap, SwiftUI diffs,
  and per-entity observables are a large change resting on an unmeasured assumption. Revisit with
  a profile, not a hunch.
- **Watch item, no action: `HomeConnection` as extension magnet.** Commands, History, Onboarding,
  Config and CloudStatus all extend the one actor. Today it is a façade with the implementations
  elsewhere and it reads well. The failure mode to watch for is state accreting on the actor
  itself; if that starts, split along the existing file seams.

---

## Sequence

Ordered so each step makes the next cheaper, with its verification named:

1. **F4.1** — `WebAuthPresenter` cancellation fix. Standalone; add the test that pins it
   (cancel during auth → throws, doesn't hang).
2. **F1 (+F4.2)** — `HomeSession`. The structural centerpiece; do it while everything is green and
   before more session-scoped features arrive. Command tasks move into session scope here.
   Mutation-check `AppModelTrustTests` after.
3. **F3** — `EndpointMemory` out of `AppModel`. Mechanically easier after F1 clarified what is
   session-scoped vs. app-scoped.
4. **F2** — `DeviceDirectory` out of `HomeStore`, then the command-surface split. Extend
   `ObservationTests` ahead of each move.
5. **F5 + F6** — the modal/tile dedup pass and the DesignSystem split, together, verified by
   `TileGallery` before/after in both themes.
6. **F7** — the small deliberate cleanups (`bindingsKey`, `deviceState` comment) ride along with
   whichever step touches their files.

Steps 1–4 are refactors netted by existing suites plus named extensions to them. Step 5 is the one
that needs eyes on pixels, which `TileGallery` provides without a live Home Assistant. Nothing here
requires a schema migration; F7 confirms the schemas are the part already built for the future.

## What was executed — 2026-08-05

Nine commits on `refactor/architecture-2026-08`. HavenCore 788 → 800 tests; HavenApp 107 → 110.
Both suites green before every commit, and the app exercised by hand afterwards.

| Item | Outcome |
|---|---|
| F4.1 web auth cancellation | **Done.** Resume-once gate + cancellation handler; tests pin both `cancel()` behaviours |
| F2 device resolution | **Done**, re-scoped — pure queries moved to Core rather than into a new App object |
| F2b command surface | **Done.** Three optimistic primitives → one `command(_:_:_:)` with an explicit write mode |
| F5a `CommitSlider` | **Done.** Five hand-written sliders → one component |
| F5b climate turn-on rule | **Done.** Out of two view files, into `ClimateState.modeWhenTurningOn(from:)` |
| F6 DesignSystem split | **Done**, re-scoped — two files moved, not eight |
| F7 dead `bindings` key | **Done.** `deviceState`'s stale comment corrected inside F2b |
| F1 cancellation guard | **Done** (follow-up). `remoteAccessOffer.attach` now checks cancellation like its four neighbours, pinned by a test watched to fail |
| F1 session teardown | **Done** (follow-up). `signOut`/`requireReauthentication` share `endSession()`; they differ only in whether the address survives |
| F1 `HomeSession` object | **Not landed, and should not be** — the two useful parts above were extracted without it. See the correction above: one object over two lifetimes would break onboarding's restart step |
| F5 tile gesture footer | **Done** (follow-up). One `TileInteraction` modifier; the four tiles no longer reference `Navigation` at all |

### Three things this document got wrong, and how they were found

Every correction came from reading the code; every error came from trusting a summary of it. This
review was assembled from subagent reports, and that is where its defects came from.

1. **F1 was overstated** — see the correction above. Executing it as written would have broken
   guided onboarding, because the sign-in session and the connection are two lifetimes and
   `OnboardingModel` must survive the restart step.
2. **F6's membership test was wrong.** "Imports HavenCore" would have moved eight files. HavenCore
   has no SwiftUI or UIKit, so an extension can link it; the real test is "reads the app's own
   `@Observable` objects", which is two files.
3. **The `bulkFlip` premise was stale.** This document repeated the July review's closing note that
   `bulkFlip` has no explicit unavailable guard. It has had one since — `HomeStore.swift:803`, with
   its own rationale. Caught by the agent that was told otherwise, which verified rather than
   complied.

### And one the test suite got wrong

`anEntityWithNoDeviceHasNoSiblings` passed with the guard it existed to pin removed: the fixture
held a single device-less entity, so there was no second one to wrongly match and the mutant was
equivalent on that data. **Third occurrence of this exact shape in this codebase.** The fixture now
carries two, and says why.

Two process notes worth keeping: a test that races a possibly-hung task inside `withTaskGroup`
hangs the whole run rather than failing, because the group awaits every child and `cancelAll()`
cannot free one blocked on an unresumed continuation — and it wedges the simulator for later runs
too. And `git checkout` restores a mutation only when the surrounding work is *committed*; on
uncommitted work it destroys it. Use a file copy.

## House rules that carry over

- **Comment loss is a failing check.** Most long comments encode a shipped bug and why the shape
  prevents its return. `BulkActionRunner.swift:59–70` is load-bearing; so are the two-decoder
  comments in Protocol and every `state != "unavailable"` (not `isUnavailable`) guard.
- **A new test is not finished until it has been watched to fail.** Twice now a test passed while
  proving nothing; both times mutation-checking caught it.
- **Both suites green before every commit**, and `TileGallery` compared for anything that touches
  a renderer.

## Review checklist for the refactoring PRs

- [ ] Does the change preserve *policy in Core under test, glue in App*? (No decision moved into a view; no SwiftUI import in Core.)
- [ ] If an `@Observable` gained/lost/moved a property: is there an `ObservationTests` case that goes red without the change's wiring?
- [ ] If a renderer changed: `TileGallery` compared before/after, light and dark?
- [ ] If session/connection wiring changed: `AppModelTrustTests` mutation-checked (drop `ssidMatch` or `candidate.isRemote`; a test must fail)?
- [ ] Every deleted comment either obsolete or relocated with its code — none silently dropped?
- [ ] New tests watched failing before the fix/refactor landed?
- [ ] No new `Task { }` without an owner that cancels it (session scope after F1)?
- [ ] Both suites green; commit is one refactor, not several?
