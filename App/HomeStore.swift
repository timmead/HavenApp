import SwiftUI
import HavenCore

@MainActor @Observable
final class HomeStore {
    var home = ResolvedHome(floors: [])
    var states: [String: EntityState] = [:]
    var historyByKey: [String: HistorySeries] = [:]
    /// Recent state changes per entity, for the binary-sensor modal. Keyed by entity id alone —
    /// unlike `historyByKey` there is one range (Day) and no attribute variant to disambiguate.
    var stateChangesByEntity: [String: [StateChange]] = [:]
    /// Each room's nominated temperature/humidity source, keyed by area id.
    ///
    /// Resolved once per structure load — deliberately *not* on every state change, even though
    /// candidacy reads `device_class` out of `states`. `rooms()` runs inside `DashboardView.body`,
    /// so anything derived from live state recomputes on every tick; a nomination recomputed there
    /// would silently switch a room to a different physical thermometer the moment the nominated
    /// one went unavailable and dropped its attributes. Which sensor is the room's is
    /// configuration; only the reading is live data.
    private(set) var environment: [String: RoomEnvironment] = [:]
    /// Haven's dashboard definition, as loaded from the `havenapp` integration. Held so a write-back
    /// merges into what the household actually has rather than replacing it — see
    /// `DashboardDocument`.
    private var dashboard = DashboardDocument()
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

    func attach(_ connection: HomeConnection) {
        subscriptionTask?.cancel(); subscriptionTask = nil
        self.connection = connection
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
            // The stream only ends when the underlying socket's receive loop does — either
            // `reset()` deliberately tore it down (in which case `isResetting` is still true; see
            // its documentation), or it dropped on its own and nobody has been told yet.
            guard let self, !self.isResetting else { return }
            self.onDisconnected?()
        }
        // Deliberately after the subscription is established, not before: `subscribe_events`
        // never replays, so any state change landing in the gap between `loadStates()` and the
        // subscription taking effect is lost until that entity next changes. `loadDashboardConfig`
        // is a config get (and possibly a write-back) round trip with no bearing on that
        // subscription — nothing here depends on it running before the socket is subscribed — so
        // putting it after shrinks that window instead of widening it with a config round trip.
        // A config failure still can't fail `bootstrap()` itself: `loadDashboardConfig` swallows
        // its own errors (see its doc comment) and there is nothing after it in this function that
        // could turn a config problem into a thrown one.
        await loadDashboardConfig()
    }

    /// Tear down the live session (used on sign-out, and on any reconnect). Clears history and
    /// any open modal too — otherwise signing into a different HA instance can show the previous
    /// account's chart data for a same-named sensor, or leave a stale modal presented.
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
        historyByKey = [:]
        stateChangesByEntity = [:]
        environment = [:]
        dashboard = DashboardDocument()
        presented = nil
        isResetting = false
    }

    // MARK: - Room environment (the dashboard config layer)

    /// Loads Haven's dashboard definition, resolves each room's nomination from it, and writes back
    /// any this device proposed.
    ///
    /// A failure to read the configuration must never take the dashboard down with it: an
    /// unreachable integration leaves `dashboard` empty, which falls through to proposals, and the
    /// user still sees their home. Hence this swallows rather than rethrows: `bootstrap()` is
    /// `throws`, so letting the error out would fail the whole session over a pill.
    ///
    /// Note the difference between a `nil` record and a throw: `nil` is "no dashboard configured
    /// yet", the ordinary first-run state and the cue to propose one. A throw is "we could not find
    /// out", and proposing over a document we failed to read would overwrite it.
    private func loadDashboardConfig() async {
        guard let connection else { return }
        do {
            let record = try await connection.loadConfig(scope: HavenConfigScope.shared,
                                                         key: Self.dashboardKey)
            dashboard = DashboardDocument(raw: record?.payload)
            resolveEnvironment()
            await persistProposedNominations(baseVersion: record?.version ?? 0)
        } catch {
            havenLog.error("dashboard config unreadable, falling back to proposed nominations: \(error)")
            dashboard = DashboardDocument()
            resolveEnvironment()
        }
    }

    static let dashboardKey = "dashboard"

    /// Resolves every room's environment from the current registry, the current states and the
    /// loaded dashboard document.
    ///
    /// The `states` join is the App layer's job for the same reason it is in `cameraEvents()`:
    /// `device_class` lives on entity state, not in the entity registry (HA's
    /// `config/entity_registry/list` returns `as_partial_dict`, which omits it). Every rule about
    /// what may be nominated lives in `RoomEnvironmentResolver`; nothing is decided here.
    func resolveEnvironment() {
        environment = RoomEnvironmentResolver.resolve(
            home: home,
            sources: states.mapValues(RoomEnvironmentSource.init),
            stored: dashboard.nominations,
            // A proposal is only worth *writing* if it currently reads. See the resolver: a stored
            // nomination is never re-picked, so a pick made while the room's real sensor happened
            // to be offline would be permanently wrong.
            isReadable: { [states] sensor in
                EnvironmentReading.value(sensor, state: states[sensor.entityId]) != nil
            })
    }

    /// Writes this device's proposed nominations into the shared dashboard document.
    ///
    /// Skipped entirely when there is nothing new to say — a no-op write on every launch would
    /// churn the shared record's version and `updated_by` for nothing.
    private func persistProposedNominations(baseVersion: Int, isRetry: Bool = false) async {
        guard let connection, dashboard.isWritable else { return }
        let proposals = environment.compactMapValues(\.nominationsToPersist)
        guard !proposals.isEmpty else { return }
        let merged = dashboard.merging(proposals)
        guard merged != dashboard else { return }

        do {
            switch try await connection.saveConfig(scope: HavenConfigScope.shared,
                                                   key: Self.dashboardKey,
                                                   baseVersion: baseVersion, payload: merged.raw) {
            case .ok:
                dashboard = merged
            case .versionConflict(let current):
                // Another admin's phone wrote first. Reapply onto what they wrote and retry once;
                // both devices are proposing the same deterministic picks, so this converges
                // immediately. A second conflict is left for the next bootstrap rather than spun
                // on — there is nothing time-critical about a pill.
                guard !isRetry else { return }
                dashboard = DashboardDocument(raw: current?.payload)
                resolveEnvironment()
                await persistProposedNominations(baseVersion: current?.version ?? 0, isRetry: true)
            }
        } catch let error as WSError where error.isNotAuthorized {
            // Only HA admins curate the shared dashboard. For everyone else in the household this
            // is the expected steady state, not a fault — and they already have the right pills on
            // screen, since the proposals render whether or not they were written.
            havenLog.debug("not an HA admin; leaving the shared dashboard config to one")
        } catch {
            havenLog.error("could not write dashboard config: \(error)")
        }
    }

    func isOn(_ entityId: String) -> Bool { states[entityId]?.state == "on" }

    /// How many entities the last bulk action of each kind failed to change. Surfaced on the
    /// roll-up row; see `recordBulkFailures`.
    private(set) var bulkFailures: [Rollup.Kind: Int] = [:]

    /// At most this many commands in flight during one bulk action. A forty-light room otherwise
    /// opens forty concurrent WebSocket requests, which is both rude to Home Assistant and a good
    /// way to have several of them time out and *become* the failures this task surfaces.
    private static let bulkConcurrency = 6

    func bulkFailureCount(for kind: Rollup.Kind) -> Int { bulkFailures[kind] ?? 0 }

    /// Records the outcome of a bulk action. Always called, including with zero — a successful run
    /// has to clear the previous run's complaint, or the row goes on accusing the user of a
    /// failure they have already fixed.
    func recordBulkFailures(_ count: Int, for kind: Rollup.Kind) {
        bulkFailures[kind] = count > 0 ? count : nil
    }

    var presented: String?                                   // entityId whose modal is open
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
    private func optimistic(_ id: String, on: Bool, _ work: @escaping @Sendable (HomeConnection) async throws -> Void) {
        guard let connection, var s = states[id] else { return }
        let previous = s
        let optimisticValue = on ? "on" : "off"
        s.state = optimisticValue
        states[id] = s
        Task {
            do { try await work(connection) }
            catch { if self.states[id]?.state == optimisticValue { self.states[id] = previous } }
        }
    }

    func openCloseCover(_ id: String) {
        guard let connection, var s = states[id] else { return }
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

    func toggleLock(_ id: String) {
        guard let connection, var s = states[id] else { return }
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

    /// Fire-and-forget scene/script/button activation. No optimistic local state to update.
    func run(_ id: String) {
        guard let connection else { return }
        Task { try? await connection.activate(sceneOrScript: id) }
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
        guard let connection else { return }
        Task { try? await connection.setColorTemp(id, kelvin: kelvin) }
    }

    func setClimateMode(_ id: String, mode: String) {
        guard let connection else { return }
        Task { try? await connection.setClimateMode(id, mode: mode) }
    }

    func setClimateTemp(_ id: String, temp: Double) {
        guard let connection else { return }
        Task { try? await connection.setClimateTemp(id, temp: temp) }
    }

    func setFanMode(_ id: String, mode: String) {
        guard let connection else { return }
        Task { try? await connection.setFanMode(id, mode: mode) }
    }

    func openCover(_ id: String) {
        guard let connection else { return }
        Task { try? await connection.openCover(id) }
    }

    func stopCover(_ id: String) {
        guard let connection else { return }
        Task { try? await connection.stopCover(id) }
    }

    func closeCover(_ id: String) {
        guard let connection else { return }
        Task { try? await connection.closeCover(id) }
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
        guard let connection else { return }
        Task { try? await connection.mediaNextTrack(id) }
    }

    func mediaPreviousTrack(_ id: String) {
        guard let connection else { return }
        Task { try? await connection.mediaPreviousTrack(id) }
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
    private func optimisticState(_ id: String, _ next: EntityState,
                                 _ work: @escaping @Sendable (HomeConnection) async throws -> Void) {
        guard let connection, let previous = states[id] else { return }
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

    func rooms() -> [RoomSection] { SectionBuilder.rooms(from: home, environment: environment) }

    /// Flattens a room's overview refs down to the plain entity ids `RoomRollups` needs.
    /// Curated (`overviewRefs`) rather than raw, so "3/5 lights on · All Off" counts and acts
    /// on exactly the tiles the user can see — a bulk action that silently reaches entities
    /// curation hid would be worse than no bulk action.
    /// Only `.entity` refs carry a single id today; `.composite` refs aren't constructed
    /// anywhere yet, so they're skipped here. Once composites exist, this will need to
    /// expand each one into its constituent input entities instead of dropping it.
    private func deviceEntityIds(_ room: RoomSection) -> [String] {
        room.overviewRefs.compactMap { ref in
            if case .entity(let id) = ref { return id }
            return nil
        }
    }

    func rollups(_ room: RoomSection) -> [Rollup] {
        RoomRollups.compute(entityIds: deviceEntityIds(room), states: states)
    }

    /// Turns off every light in the roll-up, at most `bulkConcurrency` at a time, and records how
    /// many refused.
    func allOff(_ rollup: Rollup) {
        guard rollup.kind == .lights else {
            assertionFailure("allOff called with rollup.kind == \(rollup.kind), expected .lights")
            return
        }
        runBulk(rollup, targets: rollup.targetEntityIds.filter { states[$0]?.state == "on" }) {
            [weak self] connection, id in
            guard let self else { return }
            let previous = self.states[id]
            if var s = previous { s.state = "off"; self.states[id] = s }
            do { try await connection.setLight(id, on: false) }
            catch {
                if self.states[id]?.state == "off" { self.states[id] = previous }
                throw error
            }
        }
    }

    /// Closes every open cover in the roll-up, same bounding and counting as `allOff`.
    func closeAll(_ rollup: Rollup) {
        guard rollup.kind == .covers else {
            assertionFailure("closeAll called with rollup.kind == \(rollup.kind), expected .covers")
            return
        }
        let open = rollup.targetEntityIds.filter {
            let s = states[$0]?.state; return s == "open" || s == "opening"
        }
        runBulk(rollup, targets: open) { [weak self] connection, id in
            guard let self else { return }
            let previous = self.states[id]
            if var s = previous { s.state = "closed"; self.states[id] = s }
            do { try await connection.closeCover(id) }
            catch {
                if self.states[id]?.state == "closed" { self.states[id] = previous }
                throw error
            }
        }
    }

    /// Runs `work` over `targets` in bounded batches, then records how many threw.
    ///
    /// Each entity keeps its own optimistic flip and rollback, so one failure never disturbs the
    /// rest — that property predates this and must survive it. What is new is that the failures
    /// are counted rather than discarded.
    ///
    /// **The isolation here is fiddly and was arrived at by compiling, not by reasoning.** Two
    /// shapes that look obviously right do not build under `SWIFT_STRICT_CONCURRENCY: complete`:
    ///
    /// - A `@Sendable` closure cannot touch `states`, which is `@MainActor` — so `work` is
    ///   `@MainActor`, and only the `await` on the connection actually suspends. That is enough:
    ///   MainActor tasks interleave at suspension points, so the network round-trips still overlap.
    /// - `withTaskGroup` + `group.addTask { @MainActor in … }` fails with *"pattern that the
    ///   region-based isolation checker does not understand how to check. Please file a bug"* —
    ///   a compiler limitation, not a mistake in the code. Plain child `Task`s collected into an
    ///   array avoid it entirely and read more simply.
    ///
    /// Do not "tidy" this back into a task group.
    private func runBulk(_ rollup: Rollup, targets: [String],
                         _ work: @escaping @MainActor (HomeConnection, String) async throws -> Void) {
        guard let connection else { return }
        recordBulkFailures(0, for: rollup.kind)
        Task { @MainActor in
            var failed = 0
            var index = 0
            while index < targets.count {
                let slice = Array(targets[index..<min(index + Self.bulkConcurrency, targets.count)])
                index += slice.count
                let running = slice.map { id in
                    Task { @MainActor in
                        do { try await work(connection, id); return true } catch { return false }
                    }
                }
                for task in running {
                    if await task.value == false { failed += 1 }
                }
            }
            recordBulkFailures(failed, for: rollup.kind)
        }
    }

    /// The cache key for one series.
    ///
    /// `attribute` is part of it because a thermostat-only room reads two series off a single
    /// entity at a single range — `current_temperature` and `current_humidity`. Keyed on entity
    /// and range alone those collide, and the room's chart plots one series twice under two
    /// labels, which looks like data rather than like a bug.
    ///
    /// Internal rather than private so the cache's separation can be asserted directly; the
    /// alternative is a test that drives a live connection to prove a dictionary key.
    static func historyKey(_ entityId: String, _ range: HistoryRange, _ attribute: String?) -> String {
        "\(entityId)#\(attribute ?? "")#\(range)"
    }

    /// Cached read for a previously-loaded history series. `nil` means "not loaded yet"
    /// (or the load failed) — callers should render an empty/loading state, not crash.
    func history(_ entityId: String, _ range: HistoryRange, attribute: String? = nil) -> HistorySeries? {
        historyByKey[Self.historyKey(entityId, range, attribute)]
    }

    /// Fetches and caches a history series for `entityId`/`range`/`attribute`. Reuses the cache
    /// when already populated (a range or attribute switch always misses, since the key changes);
    /// never caches a failure, so a transient error doesn't permanently block a later retry.
    func loadHistory(_ entityId: String, range: HistoryRange, attribute: String? = nil) async {
        let key = Self.historyKey(entityId, range, attribute)
        guard historyByKey[key] == nil else { return }
        guard let connection else { return }
        do {
            historyByKey[key] = try await connection.history(entityId: entityId, attribute: attribute,
                                                             range: range, now: Date())
        } catch {
            // Leave the cache untouched so a later attempt (e.g. reopening the modal) can retry.
        }
    }

    /// Cached recent state changes. `nil` means "not loaded yet" — render a placeholder, not an
    /// empty list, which would read as "nothing has happened".
    func stateChanges(_ entityId: String) -> [StateChange]? { stateChangesByEntity[entityId] }

    /// Fetches and caches recent state changes. Never caches a failure, so reopening the modal
    /// retries.
    func loadStateChanges(_ entityId: String) async {
        guard stateChangesByEntity[entityId] == nil, let connection else { return }
        do {
            stateChangesByEntity[entityId] =
                try await connection.stateChanges(entityId: entityId, range: .day, now: Date())
        } catch {
            // Leave the cache untouched so a later attempt can retry.
        }
    }
}
