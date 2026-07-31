import SwiftUI
import HavenCore

@MainActor @Observable
final class HomeStore {
    /// What Home Assistant said — the structure and the live entity states. After three seams came
    /// out (`BulkActionRunner`, `HistoryCache`, `EnvironmentCoordinator`) this is close to all the
    /// storage this type has left of its own, which is the point: it owns what HA told us, and the
    /// three children own jobs that merely need a connection.
    var home = ResolvedHome(floors: [])
    var states: [String: EntityState] = [:]

    /// Fetched history series and recent state-change lists — see `HistoryCache`. Named
    /// `historyCache`, not `history`, because `history(_:_:attribute:)` below is the read the views
    /// already call and that name is worth keeping for them.
    let historyCache = HistoryCache()
    /// Which sensor is each room's — see `EnvironmentCoordinator`. It no longer owns the document
    /// those nominations are stored in; `config` does.
    let environmentCoordinator = EnvironmentCoordinator()
    /// Haven's own configuration document, and the only writer of it — see `HavenConfig`.
    let config = HavenConfig()
    /// Bounded execution and the per-room failure tally for bulk actions — see `BulkActionRunner`.
    let bulk = BulkActionRunner()

    private var connection: HomeConnection?
    private var subscriptionTask: Task<Void, Never>?
    /// True only while `reset()` is deliberately tearing a live connection down (sign-out,
    /// reauth, or `AppModel`'s own reconnect already replacing it). Guards `onDisconnected`
    /// below: without it, `reset()`'s own teardown of `subscriptionTask` would look — from
    /// inside that task — identical to the socket dying on its own, and fire a reconnect nobody
    /// asked for on top of a teardown already in progress.
    private var isResetting = false
    /// Fired when the state-change subscription's stream ends *without* `reset()` having been
    /// the cause — i.e. the underlying WebSocket actually dropped (Wi-Fi lost, Home Assistant
    /// restarted, anything else), not a deliberate sign-out/reconnect already under way.
    ///
    /// Before this existed, nothing in the app observed a socket drop once `phase == .ready`:
    /// `connect()` returns for good the moment it succeeds, so walking out of Wi-Fi range left
    /// the dashboard rendering stale `states` forever (including lock status), every command
    /// silently no-op'd (the optimistic flip's `try?`'d call fails quietly and rolls back), and
    /// C2's whole local/remote candidate failover never got a chance to engage — the one
    /// scenario it exists for. `AppModel` wires this to the same reconnect it already runs after
    /// `OnboardingModel`'s restart step, generalized to any drop.
    var onDisconnected: (() -> Void)?

    /// Points this store — and the three children that need a connection of their own — at a live
    /// session. One call site rather than three, so a new seam cannot be left holding a stale
    /// connection from the previous session (or none at all, which reads as "no data" forever).
    func attach(_ connection: HomeConnection) {
        subscriptionTask?.cancel(); subscriptionTask = nil
        self.connection = connection
        historyCache.attach(connection)
        config.attach(connection)
    }

    func bootstrap() async throws {
        guard let connection else { return }
        home = try await connection.loadStructure()
        var initial: [String: EntityState] = [:]
        for s in try await connection.loadStates() { initial[s.entityId] = s }
        states = initial
        let stream = try await connection.subscribeStateChanges()
        subscriptionTask?.cancel()
        subscriptionTask = Task { [weak self] in
            for await s in stream { self?.states[s.entityId] = s }
            // **Three ways to arrive here, and only one of them is a disconnection.**
            //
            // `onDisconnected` drives a full reconnect in `AppModel`, which cancels whatever
            // connect loop is running and starts a new one. So a spurious fire does not just waste
            // work — it aborts an attempt that may have been about to succeed.
            //
            // 1. This task was cancelled, because `attach` is replacing it with the subscription
            //    for a new connection. Deliberate, and *not* a drop — reporting it as one makes
            //    the act of connecting trigger a reconnect. This check is what stops that; it was
            //    missing, and `DisconnectSignalTests` is what noticed.
            // 2. `reset()` tore it down, in which case `isResetting` is still true.
            // 3. The stream genuinely finished because the socket's receive loop ended. That is
            //    the one the reconnect exists for.
            if Task.isCancelled { return }
            guard let self, !self.isResetting else { return }
            self.onDisconnected?()
        }
        // Deliberately after the subscription is established, not before: `subscribe_events`
        // never replays, so any state change landing in the gap between `loadStates()` and the
        // subscription taking effect is lost until that entity next changes. The config load below
        // is a config get (and possibly a write-back) round trip with no bearing on that
        // subscription — nothing here depends on it running before the socket is subscribed — so
        // putting it after shrinks that window instead of widening it with a config round trip.
        // A config failure still can't fail `bootstrap()` itself: `EnvironmentCoordinator.load`
        // swallows its own errors (see its doc comment) and there is nothing after it in this
        // function that could turn a config problem into a thrown one.
        // Config first, then resolve-and-propose against it. `HavenConfig.load` swallows its own
        // errors (see its doc comment), so a configuration problem still cannot fail `bootstrap()`.
        await config.load()
        await environmentCoordinator.loadAndPropose(home: home, states: states, config: config)
    }

    /// Tear down the live session (used on sign-out, and on any reconnect). Clears history too —
    /// otherwise signing into a different HA instance can show the previous account's chart data
    /// for a same-named sensor.
    ///
    /// It no longer has to close an open modal: that moved to `Navigation`, which `DashboardView`
    /// owns as `@State` and which therefore dies with the dashboard whenever `phase` leaves
    /// `.ready` — see that type for why the coupling disappears rather than moves.
    ///
    /// Disconnects the underlying `HomeConnection` before dropping it — nothing else in the app
    /// retains the `HAWebSocketClient` once this reference goes away, so skipping this would
    /// leak the socket and its heartbeat timer for the rest of the process's lifetime, exactly
    /// like the abandoned-clients-in-`connect()` bug this mirrors, just triggered by a sign-out
    /// of a *working* connection instead of a failed attempt.
    func reset() async {
        isResetting = true
        subscriptionTask?.cancel(); subscriptionTask = nil
        await connection?.disconnect()
        connection = nil
        home = ResolvedHome(floors: [])
        states = [:]
        historyCache.reset()
        environmentCoordinator.reset()
        config.reset()
        bulk.reset()
        isResetting = false
    }

    // MARK: - Room environment (the dashboard config layer)
    //
    // Storage, the dashboard document, the resolver call and the version-conflict write-back all
    // moved to `EnvironmentCoordinator`, together with their reasoning. What stays here is the
    // join: that coordinator takes `home` and `states` as arguments rather than holding a
    // reference back to this store, so the dependency runs one way.

    /// Each room's nominated temperature/humidity source, keyed by area id. Read inside
    /// `DashboardView.body` by way of `rooms()`, so this must stay a live read of the
    /// coordinator's storage rather than a copy taken at some earlier moment.
    var environment: [String: RoomEnvironment] { environmentCoordinator.byArea }

    /// Nominates one sensor as a room's temperature or humidity source, and writes it to the
    /// household's dashboard document.
    ///
    /// Re-resolves after a successful write so the room's pills change immediately rather than at
    /// the next structure load — `byArea` is deliberately not recomputed from live state (see
    /// `EnvironmentCoordinator`), so nothing else would notice the document had changed.
    func nominate(_ sensor: UpliftedSensor, areaId: String) async -> HavenConfig.Outcome {
        let outcome = await config.update { document in
            var override = document.nominations[areaId] ?? RoomEnvironmentOverride()
            override[sensor.role] = sensor
            return document.merging([areaId: override])
        }
        if outcome == .written { resolveEnvironment() }
        return outcome
    }

    /// Stores the order a room's tiles were arranged into.
    ///
    /// Written whole: a reorder is not a delta anyone would want merged, and two people rearranging
    /// one room should end with the last one winning — which the conflict retry already gives.
    func setOrder(_ ids: [String], areaId: String) async -> HavenConfig.Outcome {
        await config.update { $0.settingOrder(ids, forRoom: areaId) }
    }

    /// Forgets a room's arrangement, so it falls back to the default order.
    ///
    /// The only way out of an arrangement you dislike other than dragging your way out of it, which
    /// is exactly when dragging is least appealing.
    func resetOrder(areaId: String) async -> HavenConfig.Outcome {
        await config.update { $0.settingOrder([], forRoom: areaId) }
    }

    /// What a device is called: Haven's override if the user set one, otherwise Home Assistant's
    /// name, otherwise the entity id as words. The rule is `DisplayName`'s, in HavenCore with tests.
    ///
    /// **Every surface must go through here** rather than reading `friendly_name` itself, or a
    /// renamed device would keep its old name wherever the sweep was missed. `TileName.of` was
    /// deleted to make that grep-checkable.
    func displayName(of entityId: String) -> String {
        DisplayName.resolve(override: config.document.displayNames[entityId],
                            friendlyName: states[entityId]?.attributes["friendly_name"]?.asString,
                            entityId: entityId)
    }

    /// Takes a device off a Haven surface, puts one on it, or clears the decision so curation
    /// decides again.
    ///
    /// Never touches Home Assistant: this is Haven's own layer, and the entity is exactly as it was
    /// in HA afterwards — see `SurfaceMembership`.
    func setMembership(_ entityId: String, on surface: HavenSurface,
                       to membership: SurfaceMembership?) async -> HavenConfig.Outcome {
        await config.update { $0.settingMembership(membership, for: entityId, on: surface) }
    }

    /// What the `+` on `surface` offers: every entity in the room that surface is not currently
    /// showing.
    ///
    /// Entities Home Assistant hid are absent, and that is a deliberate ceiling rather than an
    /// oversight — `SurfaceMembership.shows` refuses to show them at all, so offering one would mean
    /// offering a tap that does nothing. A user who wants such a device on their dashboard un-hides
    /// it where they hid it.
    ///
    /// Ordered by entity id so the sheet does not reshuffle between openings.
    func addableEntityIds(in room: RoomSection, on surface: HavenSurface) -> [String] {
        let showing = Set(room.refs(for: surface).map(\.id))
        return room.deviceRefs.compactMap { ref -> String? in
            guard case .entity(let id) = ref, !showing.contains(id),
                  room.tier(of: id) != .hidden else { return nil }
            return id
        }.sorted()
    }

    /// Sets or clears Haven's own name for a device. Never renames the entity in Home Assistant —
    /// HA stays the source of truth for structure, and this is Haven's layer on top.
    func rename(_ entityId: String, to name: String?) async -> HavenConfig.Outcome {
        await config.update { $0.settingDisplayName(name, for: entityId) }
    }

    /// Re-resolves every room's nomination against the current registry and states.
    func resolveEnvironment() {
        environmentCoordinator.resolve(home: home, states: states, document: config.document)
    }

    func isOn(_ entityId: String) -> Bool { states[entityId]?.state == "on" }

    /// Forwarded rather than reached through by the views, so the roll-up rows keep asking
    /// `HomeStore` for everything and this stays an implementation detail. Reading it inside a
    /// `body` registers a dependency on the runner's own storage, which is what keeps those rows
    /// redrawing — `ObservationTests` holds this to that.
    func bulkFailureCount(for kind: Rollup.Kind, in areaId: String) -> Int {
        bulk.failureCount(for: kind, in: areaId)
    }

    func recordBulkFailures(_ count: Int, for kind: Rollup.Kind, in areaId: String) {
        bulk.record(count, for: kind, in: areaId)
    }

    func state(_ id: String) -> EntityState? { states[id] }

    // Optimistic on/off primitives. `toggle` DELEGATES to these — do not duplicate this logic later.
    func setLight(_ id: String, on: Bool) { optimistic(id, on: on) { c in try await c.setLight(id, on: on) } }
    func setSwitch(_ id: String, on: Bool) { optimistic(id, on: on) { c in try await c.setSwitch(id, on: on) } }
    func toggle(_ id: String) {
        let on = !(states[id]?.state == "on")
        Domain.of(id) == .light ? setLight(id, on: on) : setSwitch(id, on: on)
    }

    /// Flip local state immediately, run the command, roll back on failure — but only if the
    /// entity still holds the value we optimistically wrote, so a late failure can't clobber
    /// state that changed in the meantime (e.g. attributes from a WS push while in flight).
    ///
    /// Guarded on `state == "unavailable"` alone, not `isUnavailable` — same class of bug as
    /// `toggleLock`/`openCloseCover`, and this is the primitive `toggle` (lights, switches, input
    /// booleans) delegates to, so it was the one gap those two didn't close. Without this, a tap
    /// on an unreachable light wrote `states[id].state = "on"` unconditionally: `isUnavailable`
    /// then read `false`, the strike vanished, and the tile looked exactly like a working light
    /// that was just switched on — and the command still went out to a device that cannot act on
    /// it. `unknown` is deliberately let through: that entity is reachable and simply hasn't
    /// reported yet, and a tap is the one thing that might resolve it.
    private func optimistic(_ id: String, on: Bool, _ work: @escaping @Sendable (HomeConnection) async throws -> Void) {
        guard let connection, var s = states[id], s.state != "unavailable" else { return }
        let previous = s
        let optimisticValue = on ? "on" : "off"
        s.state = optimisticValue
        states[id] = s
        Task {
            do { try await work(connection) }
            catch { if self.states[id]?.state == optimisticValue { self.states[id] = previous } }
        }
    }

    /// The third primitive, alongside `optimistic(_:on:_:)` above and `optimisticState` below: a
    /// command that writes **no** optimistic state and only has to be withheld from an entity Home
    /// Assistant cannot reach. Every fire-and-forget command in this file routes through here.
    ///
    /// Which commands those are, and *why* each writes nothing, is recorded on the individual
    /// methods — the answer differs (a scene has no state to predict; the next track is unknowable
    /// until the device says so; a kelvin value nothing on the grid displays). What is shared, and
    /// what lives here, is the guard, previously hand-copied into ten separate methods:
    ///
    /// Keyed on `state == "unavailable"` alone, **not** `EntityState.isUnavailable`, which also
    /// covers `unknown`. There is no optimistic write here to make an unreachable device look
    /// available — that was the `optimistic(_:on:_:)`/`toggleLock` defect — but an unreachable
    /// entity still has no business receiving a command it cannot act on, and Home Assistant will
    /// not tell us it didn't: `call_service` against an entity the integration cannot reach answers
    /// *success* and does nothing. `unknown` is deliberately let through: that entity **is**
    /// reachable and has simply not reported yet, so refusing it would remove the one interaction
    /// that could resolve it.
    ///
    /// Ten copies of that guard was ten independent chances to write the eleventh command without
    /// it, and the local failure is invisible — nothing is written to `states`, so the store looks
    /// perfectly correct while the command goes out anyway. `UnavailableCommandGuardTests` pins
    /// both halves against the frames actually sent.
    private func fireAndForget(_ id: String, _ work: @escaping @Sendable (HomeConnection) async throws -> Void) {
        guard let connection, states[id]?.state != "unavailable" else { return }
        Task { try? await work(connection) }
    }

    /// Same class of bug as `toggleLock`, at lower stakes, and guarded the same way: keyed on
    /// `state == "unavailable"` alone, not `isUnavailable`, so an `unavailable` cover can no longer
    /// be optimistically flipped to "open"/"closed" with nothing left to correct it, while an
    /// `unknown` cover — reachable, just unreported — still responds to a tap.
    func openCloseCover(_ id: String) {
        guard let connection, var s = states[id], s.state != "unavailable" else { return }
        let previous = s
        let open = s.state == "open" || s.state == "opening"
        let optimisticValue = open ? "closed" : "open"
        s.state = optimisticValue
        states[id] = s
        Task {
            do { try await (open ? connection.closeCover(id) : connection.openCover(id)) }
            catch { if self.states[id]?.state == optimisticValue { self.states[id] = previous } }
        }
    }

    /// Guarded on `state == "unavailable"` alone — not `EntityState.isUnavailable`, which also
    /// covers `unknown`.
    ///
    /// An `unavailable` lock accepts `call_service` without throwing (Home Assistant's integration
    /// fails quietly) and pushes no state update to correct a wrong guess, since an unreachable
    /// entity reports nothing at all. Writing the optimistic flip anyway — as this used to,
    /// computing `locked = (state == "locked")`, `false` for `unavailable` exactly as for a
    /// genuinely unlocked door — claimed "Locked" the instant the button was tapped and left that
    /// claim standing forever: the only rollback path is `setLock` throwing, and nothing here
    /// ever does that for a device HA merely cannot reach. See `LockModal`'s matching guard on the
    /// button that fires this.
    ///
    /// `unknown` is deliberately let through: that lock *is* reachable and has simply not reported
    /// a position, so refusing to command it would strand the user in the one state a tap could
    /// resolve — the same reasoning `LockModal.actionButton` already applies to a jammed lock.
    func toggleLock(_ id: String) {
        guard let connection, var s = states[id], s.state != "unavailable" else { return }
        let previous = s
        let locked = s.state == "locked"
        let optimisticValue = locked ? "unlocked" : "locked"
        s.state = optimisticValue
        states[id] = s
        Task {
            do { try await connection.setLock(id, locked: !locked) }
            catch { if self.states[id]?.state == optimisticValue { self.states[id] = previous } }
        }
    }

    /// Fire-and-forget scene/script/button activation. No optimistic local state to update: a
    /// scene has no on/off of its own to predict, and a script's "running" is Home Assistant's to
    /// report.
    func run(_ id: String) {
        fireAndForget(id) { try await $0.activate(sceneOrScript: id) }
    }

    /// Brightness, optimistically. D spec §10b item 2 names this control by name as one that
    /// visibly snaps back between release and Home Assistant's echo; `LightOptimistic.brightness`
    /// is what removes the snap, and it writes `state` as well as `brightness` because a light
    /// given a brightness is on — the tile's tint, icon and name colour all read the former.
    func setBrightness(_ id: String, percent: Int) {
        guard let current = states[id] else { return }
        optimisticState(id, LightOptimistic.brightness(current, percent: percent)) { c in
            try await c.setBrightness(id, percent: percent)
        }
    }

    /// Fire-and-forget, and now deliberately *unlike* `setBrightness`, which gained an optimistic
    /// write when the tiles got a draggable brightness pip.
    ///
    /// Colour temperature has no tile control and no snap-back to remove: the light modal's own
    /// `dragKelvin` covers the in-flight preview, and it is the only place a kelvin value can be
    /// set. Writing one into `states` here would be inventing a reading for an attribute nothing
    /// on the grid displays, with a rollback to get right for no visible gain.
    func setColorTemp(_ id: String, kelvin: Int) {
        fireAndForget(id) { try await $0.setColorTemp(id, kelvin: kelvin) }
    }

    func setClimateMode(_ id: String, mode: String) {
        fireAndForget(id) { try await $0.setClimateMode(id, mode: mode) }
    }

    func setClimateTemp(_ id: String, temp: Double) {
        fireAndForget(id) { try await $0.setClimateTemp(id, temp: temp) }
    }

    func setFanMode(_ id: String, mode: String) {
        fireAndForget(id) { try await $0.setFanMode(id, mode: mode) }
    }

    /// Open/stop/close, unlike `openCloseCover` and `setCoverPosition`, write nothing
    /// optimistically: where those two know the state they are heading for, a cover asked to
    /// *start* moving passes through `opening`/`closing` on its own schedule, and guessing at the
    /// intermediate would fight the position pushes that follow.
    func openCover(_ id: String) {
        fireAndForget(id) { try await $0.openCover(id) }
    }

    func stopCover(_ id: String) {
        fireAndForget(id) { try await $0.stopCover(id) }
    }

    func closeCover(_ id: String) {
        fireAndForget(id) { try await $0.closeCover(id) }
    }

    /// Cover position, optimistically — and the open/closed state with it. `CoverState` reads those
    /// two from different places (`current_position` versus the entity's `state` string), so
    /// writing only the position leaves a shade dragged half-open rendering as closed everywhere
    /// except the bar the user just moved, roll-up counts included. See `CoverOptimistic.position`.
    func setCoverPosition(_ id: String, percent: Int) {
        guard let current = states[id] else { return }
        optimisticState(id, CoverOptimistic.position(current, percent: percent)) { c in
            try await c.setCoverPosition(id, percent: percent)
        }
    }

    // MARK: - Media player

    /// Play ⇄ pause. Which service is sent follows from the state we just wrote optimistically, so
    /// the two can never disagree about which direction the tap was going.
    func mediaPlayPause(_ id: String) {
        guard let current = states[id] else { return }
        let wasPlaying = MediaPlayerState(current).isPlaying
        optimisticState(id, MediaPlayerOptimistic.playPause(current, now: Date())) { c in
            try await wasPlaying ? c.mediaPause(id) : c.mediaPlay(id)
        }
    }

    /// No optimistic state: what the next track *is* is unknowable until the device says so, and
    /// blanking the title in the meantime would flash an empty now-playing card between two songs.
    func mediaNextTrack(_ id: String) {
        fireAndForget(id) { try await $0.mediaNextTrack(id) }
    }

    func mediaPreviousTrack(_ id: String) {
        fireAndForget(id) { try await $0.mediaPreviousTrack(id) }
    }

    /// Sets the level, and clears mute when a volume change implies it.
    ///
    /// Whether it implies it is `MediaPlayerState.volumeChangeShouldUnmute`, in HavenCore with
    /// tests — not decided here. The short version: dragging a volume control on a muted speaker
    /// otherwise changes a number and produces no audible difference at all, which reads as a
    /// broken slider. `volume_mute` goes first so the level lands on an already-unmuted player
    /// rather than the two racing.
    func setMediaVolume(_ id: String, percent: Int) {
        guard let current = states[id] else { return }
        let unmuting = MediaPlayerState(current).volumeChangeShouldUnmute
        optimisticState(id, MediaPlayerOptimistic.volume(current, percent: percent, unmuting: unmuting)) { c in
            if unmuting { try await c.setMediaMuted(id, muted: false) }
            try await c.setMediaVolume(id, percent: percent)
        }
    }

    func setMediaMuted(_ id: String, muted: Bool) {
        guard let current = states[id] else { return }
        optimisticState(id, MediaPlayerOptimistic.mute(current, muted: muted)) { c in
            try await c.setMediaMuted(id, muted: muted)
        }
    }

    func selectMediaSource(_ id: String, source: String) {
        guard let current = states[id] else { return }
        optimisticState(id, MediaPlayerOptimistic.source(current, source)) { c in
            try await c.selectMediaSource(id, source: source)
        }
    }

    /// Power, never play/pause — the modal only offers this where `supported_features` declares
    /// both halves.
    func setMediaPower(_ id: String, on: Bool) {
        guard let current = states[id] else { return }
        optimisticState(id, MediaPlayerOptimistic.power(current, on: on)) { c in
            try await c.setMediaPower(id, on: on)
        }
    }

    /// The whole-state flavour of `optimistic(_:on:_:)`: the caller hands over an already-computed
    /// next `EntityState` rather than a single on/off, because most commands imply a *set* of
    /// attributes — pausing a player restamps the position so the progress bar doesn't jump
    /// backwards, powering one off clears the whole now-playing set, setting a cover's position
    /// changes whether it is open, and giving a light a brightness turns it on. Those transforms
    /// live in `MediaPlayerOptimistic`, `LightOptimistic` and `CoverOptimistic`, in HavenCore with
    /// tests; nothing is decided here.
    ///
    /// Shared by every domain rather than copied per domain — the D spec already flags five
    /// near-identical flip/command/rollback blocks in this file as wanting extraction, and adding
    /// a sixth and seventh for lights and covers would have been the wrong direction.
    ///
    /// Rollback compares the whole entity, not one field, and so is strictly safer than the on/off
    /// version: any state push that landed while the command was in flight leaves the comparison
    /// unequal and the rollback is skipped, exactly as intended.
    ///
    /// Guarded on `state == "unavailable"` alone, not `isUnavailable` — same reasoning as
    /// `optimistic(_:on:_:)` above, and this is the primitive brightness, cover position, and
    /// media volume/mute/source/power all route through. Left unguarded, any of them could write
    /// a confident-looking `next` state over an unreachable device and send the matching command
    /// into the void. `unknown` still goes through: that entity is reachable and simply hasn't
    /// reported, so refusing to command it would remove the one interaction that could resolve it.
    private func optimisticState(_ id: String, _ next: EntityState,
                                 _ work: @escaping @Sendable (HomeConnection) async throws -> Void) {
        guard let connection, let previous = states[id], previous.state != "unavailable" else { return }
        states[id] = next
        Task {
            do { try await work(connection) }
            catch { if self.states[id] == next { self.states[id] = previous } }
        }
    }

    // MARK: - Camera

    /// Asks Home Assistant to start a stream for a camera and returns the playlist path it minted,
    /// or `nil` when there is none to be had.
    ///
    /// `nil` covers every failure identically — no session, the camera has no stream, the command
    /// errored, the socket dropped — because the caller does the same thing for all of them: fall
    /// back to refreshing the still (`CameraStreamSource.snapshotRefresh`). That is a working live
    /// view, just a slower one, and surfacing an error over it would replace something usable with
    /// something that only looks broken.
    ///
    /// Returns the raw path rather than a resolved URL for the reason on
    /// `HomeConnection.cameraStreamPath`: resolution belongs to `CameraStream.source`, against
    /// whichever base URL is live when the player is actually built.
    func cameraStreamPath(_ id: String) async -> String? {
        guard let connection else { return nil }
        return try? await connection.cameraStreamPath(entityId: id)
    }

    /// The binary sensors that belong with a camera, for the modal's **Events** card.
    ///
    /// This is the App half of the join and holds no policy: it turns the two things the store has
    /// (`registryInfo`, keyed by entity id, and `states`, which is where `device_class` lives) into
    /// candidates and hands them to `CameraEvents`, which decides what is related and what counts
    /// as an event. Every rule — same-device before name-stem, which device classes qualify, how
    /// short a stem is too short — is over there, under test.
    func cameraEvents(_ id: String) -> [CameraEventSensor] {
        let candidates = home.registryInfo.compactMap { entityId, info -> CameraEventCandidate? in
            guard entityId.hasPrefix("binary_sensor.") else { return nil }
            return CameraEventCandidate(entityId: entityId, deviceId: info.deviceId,
                                        deviceClass: states[entityId]?.deviceClass)
        }
        return CameraEvents.related(cameraId: id,
                                    cameraDeviceId: home.registryInfo[id]?.deviceId,
                                    candidates: candidates)
    }

    // MARK: - Room roll-ups + bulk actions

    /// The rooms as rendered: Home Assistant's structure, Haven's sensor nominations, and the
    /// household's per-surface decisions about which devices each surface shows.
    func rooms() -> [RoomSection] {
        SectionBuilder.rooms(from: home, environment: environment,
                             overrides: config.document.surfaceOverrides,
                             orders: home.floors.flatMap(\.areas).reduce(into: [:]) { out, area in
                                 let order = config.document.order(forRoom: area.id)
                                 if !order.isEmpty { out[area.id] = order }
                             })
    }

    /// Flattens a room's overview refs down to the plain entity ids `RoomRollups` needs.
    ///
    /// `refs(for: .overview)` rather than raw, so "3/5 lights on · All Off" counts and acts on
    /// exactly the tiles the user can see — a bulk action that silently reaches entities curation
    /// hid would be worse than no bulk action.
    ///
    /// That now covers the household's own removals as well as curation's, and it follows from the
    /// same sentence rather than being a new rule: a tile a user took off the dashboard is one they
    /// cannot see, so it drops out of the count and out of the action.
    /// Only `.entity` refs carry a single id today; `.composite` refs aren't constructed
    /// anywhere yet, so they're skipped here. Once composites exist, this will need to
    /// expand each one into its constituent input entities instead of dropping it.
    private func deviceEntityIds(_ room: RoomSection) -> [String] {
        room.refs(for: .overview).compactMap { ref in
            if case .entity(let id) = ref { return id }
            return nil
        }
    }

    func rollups(_ room: RoomSection) -> [Rollup] {
        RoomRollups.compute(entityIds: deviceEntityIds(room), states: states)
    }

    /// Turns off every light in the roll-up.
    func allOff(_ rollup: Rollup, in areaId: String) {
        bulkFlip(rollup, in: areaId, expecting: .lights,
                 isTarget: { $0.state == "on" }, flippingTo: "off") { connection, id in
            try await connection.setLight(id, on: false)
        }
    }

    /// Closes every open cover in the roll-up. `opening` counts as a target: a cover on its way up
    /// is one the user asking for "close all" plainly means to include.
    func closeAll(_ rollup: Rollup, in areaId: String) {
        bulkFlip(rollup, in: areaId, expecting: .covers,
                 isTarget: { $0.state == "open" || $0.state == "opening" }, flippingTo: "closed") { connection, id in
            try await connection.closeCover(id)
        }
    }

    /// One room's roll-up, flipped optimistically and then commanded in bounded batches.
    ///
    /// `allOff` and `closeAll` were this function twice, differing only in the four things now
    /// passed in: which kind of roll-up is expected, which entities are targets, what state they
    /// are flipped to, and which command is sent. Everything else — and it is the part that is
    /// subtle — was duplicated, including the rollback rule, which had to be explained in both
    /// copies.
    ///
    /// Every target's `states` entry is flipped **synchronously, here**, before anything is
    /// batched — see `BulkActionRunner.run`'s doc comment for why the flip must not live inside the batched
    /// work — then the commands run at most `bulkConcurrency` at a time and however many refuse
    /// are recorded against this room.
    ///
    /// The `expecting` check is an internal-consistency assertion, not input validation: the
    /// callers are `RoomSectionView`/`RoomDetailView` rendering a row whose kind they already
    /// know, so a mismatch is a programming error and `assertionFailure` names the caller
    /// (`#function` at the call site) rather than this shared helper.
    /// Internal rather than private **so a test can call it with a predicate the shipped callers
    /// never use** — see `bulkActionsSkipUnreachableEntitiesWhateverThePredicateSays`. The
    /// unreachability guard below is redundant against today's two allow-list predicates, and
    /// therefore unprovable through `allOff`/`closeAll`; the only way to hold it to anything is to
    /// hand it a predicate that would otherwise let an unreachable entity through.
    func bulkFlip(_ rollup: Rollup, in areaId: String, expecting kind: Rollup.Kind,
                  isTarget: (EntityState) -> Bool, flippingTo flipped: String,
                  caller: String = #function,
                  _ command: @escaping @MainActor (HomeConnection, String) async throws -> Void) {
        guard rollup.kind == kind else {
            assertionFailure("\(caller) called with rollup.kind == \(rollup.kind), expected \(kind)")
            return
        }
        // **Unreachable entities are excluded here, deliberately, before the caller's predicate is
        // consulted at all.**
        //
        // They were already excluded, but only as a side effect: `allOff` targets `state == "on"`
        // and `closeAll` targets `"open"`/`"opening"`, and the string `"unavailable"` is none of
        // those. Correct, and true by accident. Rewrite either predicate as a deny-list — `!=
        // "closed"` is the obvious "simplification", and was tried during review — and every
        // unreachable cover in the room silently becomes a target: flipped to a state it is not in,
        // and sent a command Home Assistant answers *success* to without doing anything.
        //
        // So the guard is stated rather than inherited, matching `fireAndForget` and
        // `optimisticState`, which is where a reader looking for this rule will expect to find it.
        // Keyed on `state == "unavailable"` alone and not `EntityState.isUnavailable` for the same
        // reason as those two: an `unknown` entity is reachable and simply has not reported.
        let targets = rollup.targetEntityIds.filter { id in
            guard let state = states[id], state.state != "unavailable" else { return false }
            return isTarget(state)
        }
        var flips: [String: (previous: EntityState, flipped: EntityState)] = [:]
        for id in targets {
            guard let s = states[id] else { continue }
            var next = s; next.state = flipped
            flips[id] = (previous: s, flipped: next)
            states[id] = next
        }
        guard let connection else { return }
        bulk.run(targets, kind: rollup.kind, in: areaId) { [weak self] id in
            guard let self else { return }
            do { try await command(connection, id) }
            catch {
                // Whole-entity comparison, not just `state`: a WebSocket push that lands mid-flight
                // and happens to also report the flipped-to state would satisfy a state-only check
                // and overwrite the pushed reading (and its now-stale attributes/lastUpdated) with
                // the tap-time snapshot. Comparing the whole `EntityState` — which carries
                // `lastUpdated` — means any genuine push no longer compares equal, so the rollback
                // correctly stays out.
                if let flip = flips[id], self.states[id] == flip.flipped { self.states[id] = flip.previous }
                throw error
            }
        }
    }

    // `runBulk` moved to `BulkActionRunner.run`, together with the whole of its reasoning —
    // including the note about why this must not be "tidied" back into a task group.
    // MARK: - History
    //
    // The caches, the in-flight guard, the cache-lifetime rules and the never-cache-a-failure
    // reasoning all moved to `HistoryCache`. These forward, so the views and their tests keep the
    // call sites they had — and, because each read happens through this store inside a `body`, the
    // observation dependency still lands on the cache's own storage. `ObservationTests` pins that.

    static func historyKey(_ entityId: String, _ range: HistoryRange, _ attribute: String?) -> String {
        HistoryCache.key(entityId, range, attribute)
    }

    func history(_ entityId: String, _ range: HistoryRange, attribute: String? = nil) -> HistorySeries? {
        historyCache.series(entityId, range, attribute: attribute)
    }

    func loadHistory(_ entityId: String, range: HistoryRange, attribute: String? = nil) async {
        await historyCache.load(entityId, range: range, attribute: attribute)
    }

    func stateChanges(_ entityId: String) -> [StateChange]? { historyCache.stateChanges(entityId) }

    func stateChangesLoadFailed(_ entityId: String) -> Bool { historyCache.loadFailed(entityId) }

    func loadStateChanges(_ entityId: String, force: Bool = false) async {
        await historyCache.loadStateChanges(entityId, force: force)
    }
}
