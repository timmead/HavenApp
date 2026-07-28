# Foundation Architecture & Refactoring Review — 2026-07-27

**Scope:** everything built so far — `App/` (~4,400 lines), `Packages/HavenCore/` (~6,500 lines of
source, ~13,600 of tests). No feature work; this is a structural pass over the foundation before
more is stacked on it.

**Baseline at review time (both green, verified before any edit):**

| Suite | Command | Result |
|---|---|---|
| HavenCore | `swift test --package-path Packages/HavenCore` | 636 tests, 15 suites, passed in 8.0s |
| HavenApp | `xcodebuild test -scheme HavenApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` | 55 tests, 12 suites, **TEST SUCCEEDED** |

**Branch:** `refactor/foundation-review`, off `df4fb3c`.

---

## Headline

**The foundation is in good shape.** The single most important architectural property — *policy
lives in HavenCore under test; `App/` only glues and renders* — is genuinely observed, not merely
aspired to. Spot-checks across URL adoption, connection classification, optimistic state,
roll-ups, curation, camera events and room environment all found the decision in a pure, tested
function in `HavenCore` and only the join/dispatch in `App/`. That is the property that makes the
636-test core suite worth having, and it has not eroded.

Two things follow from that, and they shape every finding below:

1. **The comments are the design record.** Most long comment blocks in this codebase encode a bug
   that already shipped and the reason the current shape prevents it (`runBulk`: *"Do not 'tidy'
   this back into a task group"*; the 14 `state != "unavailable"` guards each documenting why they
   are deliberately **not** `isUnavailable`). A refactor that deletes rationale passes every test
   and is a real regression — the reasoning has to be re-derived from scratch by whoever hits the
   bug next. **Comment loss was treated as a failing check throughout this pass.**
2. **The structural debt is concentrated in two files**, both in `App/`, both grown by accretion
   rather than designed: `AppModel.swift` (780 lines) and `HomeStore.swift` (760 lines). Both were
   read in full. The next two largest files were read specifically to check that claim, and neither
   is debt:
   - `HavenCore/Session/CloudStatus.swift` (584) — **308 of those lines are comments.** ~276 lines
     of code covering one cohesive domain (the `cloud/status` wire type, the classification, the
     offer, and the URL-adoption rules), backed by a 654-line test suite. Long, not sprawling.
   - `App/Renderers/Modals/CameraModal.swift` (543, 197 of them comments) — the obvious suspicion
     is a lifecycle state machine wanting extraction, and it does not hold: the decision is
     *already* extracted as `CameraPlaybackPlan`, a pure `Equatable` value with its own tests, and
     what remains (`start`/`replace`/`teardown`/`stopPlayer`/`setMuted`/`releaseAudioSession`) is
     six small functions with one job each and carefully-reasoned audio-session ownership. See P6
     for the one small thing it *is* worth doing here.

   Everything else is proportionate.

---

## Findings

Ordered by severity × confidence. **L** = landed on this branch tonight. **P** = proposed, and
deliberately *not* landed — see "Why these were not landed" at the end.

### L1 — `HomeStore`: ten near-identical fire-and-forget command methods

`App/HomeStore.swift`. Ten methods were byte-for-byte the same but for the call they wrap:

```swift
func setColorTemp(_ id: String, kelvin: Int) {
    guard let connection, states[id]?.state != "unavailable" else { return }
    Task { try? await connection.setColorTemp(id, kelvin: kelvin) }
}
```

…repeated for `setClimateMode`, `setClimateTemp`, `setFanMode`, `openCover`, `stopCover`,
`closeCover`, `mediaNextTrack`, `mediaPreviousTrack`, `run`. The guard is the load-bearing part
(`state != "unavailable"` and specifically **not** `isUnavailable`, so `unknown` still commands),
and ten copies is ten chances for the eleventh to be written without it — which is precisely how
the `optimistic(_:on:_:)` gap that shipped came to exist.

**Risk before the change:** the app-layer suite covered the guard on `toggleLock`,
`openCloseCover` and `toggle` only. The other ten were unverified.

### L2 — `allOff` / `closeAll` were the same function twice

`App/HomeStore.swift`. Both: filter targets by state, build a `flips` dictionary, write the
optimistic state synchronously, call `runBulk` with a closure that rolls back on a whole-`EntityState`
comparison and rethrows. The only differences are the predicate, the flipped-to string, the
`assertionFailure` kind, and which connection method is called. The duplicated rollback comment in
both catch blocks is itself evidence: the same subtle whole-entity-comparison rule had to be
explained twice.

### L3 — `AppModel.connect()` is a 287-line function nested four deep

`App/AppModel.swift:350–636`. `while true` → `for candidate` → `while retryThisCandidate` → `do` +
six `catch` arms, with two round-level accumulators (`candidatesBlockedByATS`,
`candidatesWithPersistentAuthInvalid`) threaded through by mutation and `break candidateAttempt`
targeting a labelled inner loop. Every individual decision in it is correct and documented; the
problem is purely that no reader can hold it at once, and it is the function where a mistake costs
the most (it holds the security-relevant trust decision that feeds `ConnectionClass.observed`).

---

### P1 — `connect()` cannot be tested end to end, and the code says so twice

> **Update — the security-critical half of this is now closed (commit 7).** Lifting the candidate
> loop apart (L3) left `finishConnecting` taking `peerAddress` as a plain parameter rather than
> reading it from an inline `NWWebSocketConnection`, which made the fail-closed trust decision
> injectable *without* widening any protocol. It is now `internal` (same justification, same
> wording, as `rememberDiscoveredURLs` beside it) and `AppModelTrustTests` pins the wiring —
> including, by mutation, that dropping `candidate.isRemote` or `ssidMatch` from the call makes a
> test go red. **The seam design below is therefore no longer needed for the security property**;
> it is now only about covering the *candidate loop* (iteration order, the one-forced-refresh rule,
> the all-candidates-agree escalations), which is ordinary correctness rather than a silent
> vulnerability. Re-prioritise accordingly: this dropped from "highest value" to "worth doing".

`AppModel.swift:334-337` and `:132-137` both admit it: `NWWebSocketConnection` and `OAuthClient`
are constructed inline, so no test can drive the candidate loop with a fake transport. The
consequence is stated honestly in the comments — "ordering decisions belong in HavenCore, where
they are tested" — and that discipline is real. But the *loop itself* is untested: candidate
iteration, the one-forced-refresh-per-call rule, the all-candidates-agree escalations for ATS and
`auth_invalid`, and the cancellation checks are all verified by reading only.

**The seam is not free, and that is why it is proposed rather than landed.** `HavenCore` already
has a `WebSocketConnection` protocol with two conformers, but `connect()` needs
`NWWebSocketConnection.observedPeerAddress` — which is *not* on the protocol — because it feeds
`ConnectionClass.observed`, the fail-closed trust decision that decides whether a self-reported URL
may be persisted and later have a refresh token POSTed to it. Widening the protocol to carry
`observedPeerAddress` means every conformer (including any test fake) can now assert a peer
address, and a fake that returns a LAN-looking address is a test that *proves* adoption happens
over a connection that was never local. Getting that subtly wrong is a silent security regression
with a green suite.

**Suggested design, for review while awake:**

```swift
// HavenCore/Networking/WebSocketConnection.swift
public protocol PeerObservableConnection: WebSocketConnection {
    /// The address the kernel is actually sending bytes to, or nil if unavailable.
    /// Deliberately nil-by-default in any conformer that cannot observe it: unavailable
    /// ⇒ .remote ⇒ nothing adopted (see ConnectionClass.observed's fail-closed rule).
    var observedPeerAddress: String? { get }
}

// AppModel
typealias ConnectionFactory = @Sendable (URL) -> any PeerObservableConnection
init(..., makeConnection: @escaping ConnectionFactory = { NWWebSocketConnection(url: $0) })
```

The test-facing risk is contained by keeping `observedPeerAddress` **read-only and defaulted to
`nil`**, and by adding a HavenCore test that pins the fail-closed direction (a fake reporting a
private-IP literal must still not cause adoption unless the class resolves `.local` through the
existing pure function). L3 was landed first specifically to make this seam cheap: the extracted
per-candidate method is where the factory call lands, and it is now ~80 lines instead of buried at
depth four.

### P2 — `HomeStore` is six responsibilities in one `@Observable`

> **Update — the blocker is gone, and the first extraction is done (commits 12–13).**
>
> This was deferred because splitting an `@Observable` changes *observation granularity*, whose
> failure mode is "the view silently stops redrawing" — invisible to every test here, and
> **actively hidden by a SwiftUI preview**, which holds a fixed store and looks pixel-perfect while
> observation is dead.
>
> `Tests/HavenAppTests/ObservationTests.swift` closes that. `withObservationTracking` records
> exactly what SwiftUI records when it evaluates a `body` — the properties actually read — so
> "would this view redraw?" becomes a `#expect`. It is written against the accessors the views
> really call (`state(_:)`, `isOn`, `bulkFailureCount`, `rooms()`, `presented`, `history(...)`),
> plus a negative control so the suite cannot pass by reporting `true` unconditionally.
>
> Proven to bite: marking `bulkFailures` `@ObservationIgnored` — precisely the break a careless
> extraction causes — turns one test red while **the other 75 stay green**.
>
> `BulkActionRunner` is extracted on that footing and the observation test for its tally passes
> through the new child object. **Remaining: `HistoryCache` and `EnvironmentCoordinator`**, in that
> order. Both are now ordinary refactors rather than gambles. Note `HistoryCache` will need the
> `connection` forwarded to it on `attach`, and three test files read `historyByKey`/
> `stateChangesByEntity` directly, so they move with it.

760 lines, 48 methods, and these distinct jobs:

| Responsibility | Evidence |
|---|---|
| Connection lifecycle | `attach`, `bootstrap`, `reset`, `onDisconnected`, `isResetting` |
| Command dispatch + optimistic state | ~20 methods, `optimistic`, `optimisticState` |
| History / state-change cache | `historyByKey`, `historyInFlight`, `stateChangesByEntity`, `stateChangesFailed`, 6 methods |
| Bulk actions | `bulkFailures`, `BulkFailureKey`, `runBulk`, `allOff`, `closeAll` |
| Room environment config layer | `environment`, `dashboard`, `loadDashboardConfig`, `resolveEnvironment`, `persistProposedNominations` |
| Camera joins | `cameraStreamPath`, `cameraEvents` |
| **Navigation state** | `presented: String?` — see P3 |

The seams are clean and the extraction is obvious (`HistoryCache`, `BulkActionRunner`,
`EnvironmentCoordinator` are all self-contained, with existing test files that map one-to-one onto
them: `HistoryCacheKeyTests`, `StateChangesCacheTests`, `BulkActionTests`,
`RoomEnvironmentStickinessTests`, `DashboardConfigWriteBackTests`).

**Why it was not landed overnight:** splitting an `@Observable` into child objects changes
*observation granularity*. SwiftUI tracks reads per-object; moving `historyByKey` into a child
object that a view reaches through `store.history.byKey` is fine, but moving it behind a
**non-`@Observable`** holder, or reading it through a computed property that doesn't touch the
child's stored property, silently stops the view redrawing. The failure mode is "the chart no
longer updates" — invisible to all 691 tests, since none of them render a view. This needs the
person who can look at the running app.

**Recommended order when landed:** `BulkActionRunner` first (it is the most self-contained and its
only observable output, `bulkFailures`, is read through an accessor method rather than directly),
then `HistoryCache`, then `EnvironmentCoordinator`. Command dispatch should stay on `HomeStore` —
it is the store's actual job.

### P3 — modal routing lives in the data store

`HomeStore.presented: String?` — an entity id — is navigation state on the object that holds
Home Assistant's entity states, written from 11 tile views (`store.presented = entityId`) and read
by `DashboardView`'s sheet binding. It also has to be cleared in `reset()` alongside the caches,
which is the tell: sign-out has to remember to close a sheet.

`DashboardView` already owns `path` and `showingConnectionSettings` as `@State`. `presented` is the
same kind of thing and belongs with them (or in a small `Navigation` observable), leaving
`HomeStore` to hold only what Home Assistant told us. Deferred with P2 for the same
observation-granularity reason, and because it touches 11 view files that no test renders.

### P4 — eleven tiles repeat the same chrome

Every tile in `App/Renderers/Tiles/` opens with the same four lines and closes with the same
accessibility block:

```swift
let e = store.state(entityId)
let unavailable = e?.isUnavailable ?? false      // 11 occurrences across App/
GlassTile(active:accent:unavailable:) { Image(...).foregroundStyle(unavailable ? .secondary : ...)
                                        Text(TileName.of(entityId, e)).foregroundStyle(unavailable ? .secondary : ...) }
```

The `unavailable ? .secondary : …` pattern in particular was applied tile-by-tile in commits
`5e67b60`/`6a3bebc`/`e6ebe54`, and `SensorTile`'s comment records that it was the one that *had no
`foregroundStyle` at all* — i.e. the sweep already missed a tile once. A `TileLabel(icon:name:
active:unavailable:accent:)` component would make that impossible to miss again.

**Not landed** because nothing in either suite renders a view, so a visual regression here would
ship silently. This is the highest-value *proposed* item after P1 — it removes a whole class of
"the sweep missed one" defect — but it wants a person looking at the screen.

### P6 — two general-purpose pieces live in one modal's file

`App/Renderers/Modals/CameraModal.swift` ends with `PlayerLayerView` (a generic
`UIViewRepresentable` wrapping `AVPlayerLayer`) and `FlowRow` (a general-purpose `Layout` that
wraps chips onto multiple lines). Neither is camera-specific; `FlowRow` in particular is what any
future chip row would want, and the second caller who needs it will either import it from a camera
modal or write it again.

They belong in `App/DesignSystem/`. This is the smallest item in this document and the only reason
it is not landed is the rule below: moving a file under `App/` requires `xcodegen generate`, and a
file move is a poor thing to leave unattended when no test renders either type. Ten-minute job.

### P5 — minor, no action needed

- **`UserDefaults` key ownership is already correct.** `DefaultsKeys` in `AppModel` aliases the
  Core constants (`DiscoveredURLMigration.discoveredInternalURLKey` etc.) rather than redeclaring
  them, so the migration and the accessors cannot drift. Only `baseURL` is App-local and only App
  reads it. Verified, not a finding — recorded so the next reviewer doesn't re-flag it.
- **Two loggers (`havenLog`, `havenCoreLog`) is deliberate** and documented in `Support/Log.swift`
  (a second top-level `havenLog` in the package would collide at the import site). Correct as is.
- **`.gitignore` is complete.** `build/` (which matches both the repo-root and the
  `Packages/HavenCore/` build directories), `domika_analysis/`, `.superpowers/` and the generated
  `HavenApp.xcodeproj/` are all covered; `git status` is clean at baseline. Checked because a
  generated project directory or a stale `build/` is the classic thing to commit by accident with
  `git add -A`. No action needed.

---

## Why the P-items were not landed

The instruction was to use best judgement to remain unblocked overnight. The line drawn was:

**Landed:** behavior-preserving transformations netted by tests that exist *and that were confirmed
to cover the code being moved first* — with missing coverage added as its own commit ahead of the
refactor.

**Not landed:** anything whose failure mode is invisible to the test suites. That is precisely P1
(a security decision whose wrong version still goes green), P2/P3 (SwiftUI observation, which no
test observes) and P4 (rendering, which no test renders). Landing those unattended would produce
exactly the shape this codebase's comments keep warning about — a change that is green and wrong.

## Commits on this branch

Each is one refactor, with both suites run and green before the commit. See `git log
main..refactor/foundation-review`.

1. `test(app): cover the unavailable guard on every fire-and-forget command` — the safety net for
   commit 2, added first. Ten methods went from unverified to pinned, in both directions
   (`unavailable` ⇒ no state change *and* no frame on the wire; `unknown` ⇒ commands normally).
   Confirmed to bite by removing `stopCover`'s guard and watching it fail.
2. `refactor(app): one guard for every fire-and-forget command` — L1. Hand-written guards in
   `HomeStore`: 14 → 5, all five now in primitives.
3. `refactor(app): allOff and closeAll are one bulk flip` — L2, plus a test for `closeAll`'s own
   arguments, which nothing covered.
4. `refactor(app): lift one candidate's connect attempt out of the loop` — L3. `connect()`
   287 lines → ~100, plus `attemptCandidate` and `finishConnecting`.
5. `docs:` this document, updated with what the work itself taught.
6. `test(app): pin the trust decision's wiring, not just its parts` — the security half of P1,
   which L3 made reachable. See the update on that section.

### Two things worth knowing that came out of doing the work

**A test that passes is not a test that pins.** The first version of the `closeAll` test used a room
of open, opening and closed covers, and it passed under the exact mutation it claimed to catch
(`!= "closed"` excludes closed covers too — the mutant was equivalent on that data). The room now
also holds a `closing` and an `unavailable` cover, and fails on three assertions under that
mutation. Both new tests on this branch were checked this way, by breaking the production code and
watching them go red. **This is worth making the house habit** — a green new test proves nothing
about the mutation it was written for until you have seen it fail.

**`bulkFlip` has no explicit unavailable guard**, unlike `fireAndForget` and `optimisticState`,
which both carry one. An unreachable light or cover is excluded from a bulk action only because the
string `"unavailable"` is neither `"on"` nor `"open"`/`"opening"` — i.e. correct, but *incidentally*
so, falling out of the target predicates rather than being decided. This is not a defect today and
was deliberately not "fixed" overnight (adding a redundant guard changes nothing observable and
would need its own justification). It is recorded on the new test, and it is the thing to remember
if either predicate is ever rewritten as a deny-list.

**Verification of L3 could not come from the tests**, since nothing drives `connect()`. It was
checked by inventory instead: identical set of `havenLog` call sites before and after, 18
cancellation checks in both, 3 `requireReauthentication()` calls in both, and each of the six catch
arms traced by hand to the same successor state. That is weaker than a test, which is exactly why
P1 is the recommendation it is.

## Second session — what was done, 2026-07-28

Working through the list below. `git log main..refactor/foundation-review` has the detail.

| Item | Status |
|---|---|
| **P4** tile chrome | **Done.** `TileEmphasis` (Core, tested) + `TileLabel`; no tile hand-writes the guard now |
| **P6** move `FlowRow`/`PlayerLayerView` | **Done.** CameraModal 543 → 467 lines |
| **P1** connection seam | **Done.** `PeerObservableConnection` + injected factory; six loop tests |
| **P2** HomeStore split | **Done.** All three seams out; HomeStore 760 → 560 lines |
| **P3** navigation state | **Done.** `Navigation`, owned by `DashboardView` |

**P4 got real visual verification, which the plan said it needed and assumed it could not have.**
Xcode's preview canvas renders without a Home Assistant, so `App/Renderers/TileGallery.swift`
(DEBUG-only) shows every tile in every state — including the four this document called out as
having historically been got wrong. Baseline captured before any edit, compared after: **pixel
identical in both halves.** That gallery is now the standing answer to "did every tile get it".

**Two tests were written wrong first, and mutation testing is the only reason anyone knows.** Both
in `ConnectLoopTests`, both the same shape: the interesting candidate placed *second*, where the
first already succeeded, so the code under test never ran and the test passed while proving
nothing. This is the second session running in which that has happened, which promotes it from an
anecdote to a house rule — **a new test is not finished until you have watched it fail.**

### Everything on this list is now done

`HomeStore` went from 760 lines holding six jobs to 560 holding two: what Home Assistant said
(`home`, `states`) and the command dispatch that writes optimistic state over it. The other four
moved out — `BulkActionRunner`, `HistoryCache`, `EnvironmentCoordinator`, `Navigation` — and the
views' call sites are untouched, because the store still forwards.

**P3 landed better than this document predicted.** The plan assumed the sign-out coupling would
*move* to `AppModel` (something must still close the sheet). It does not have to: `Navigation` is
`@State` on `DashboardView`, which only exists while `phase == .ready`, so sign-out,
reauthentication and a mid-session reconnect all destroy it in passing. The coupling disappears.

**A correction to what this document said about observation.** The negative control originally
claimed that reading one entity does not depend on another, and that this is what stops a
forty-tile floor re-evaluating on every push. **That is false.** `states` is one dictionary, so
granularity is per-property: any push invalidates every tile that read it. This is fine today — a
`body` is cheap and SwiftUI diffs before touching the render tree — but it is now pinned by a test
of its own, because the obvious "optimisation" of per-entity observables would be a large change
resting on an assumption nobody had checked.

## Recommended next steps, in order

Every item in this document is now closed. What is worth doing next is not on it:

1. **Look at the branch on a real instance.** Nothing here has run against a live Home Assistant.
   The suites and the gallery cover a great deal, but "the dashboard still works" is not something
   either can assert.
2. **Consider whether the modals want the same pass the tiles got.** Six of them still hand-write
   `accent: unavailable ? .secondary : accent` into `ControlModalScaffold`. That is consistent and
   correct today, so it was left alone — but it is the same shape as the tile finding, one layer
   up, and `TileEmphasis` already exists to express it.
3. **Leave `states` as one dictionary** until something measurably wants otherwise — see the
   observation correction above.

## Verification summary

| Suite | Baseline | After session 1 | After session 2 |
|---|---|---|---|
| HavenCore | 636 passed | 636 passed | **638 passed** |
| HavenApp | 55 passed | 63 passed | **78 passed** |

Plus one form of verification neither suite provides: `TileGallery`, rendered before and after the
tile refactor and compared by eye, both halves.

Both suites were run and green before every commit on this branch. `App/AppModel.swift` and
`App/HomeStore.swift` were each restored to a byte-identical state after every mutation check, and
`git diff` was used to confirm it rather than memory. Nothing in `HavenCore/` was modified.
