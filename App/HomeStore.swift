import SwiftUI
import HavenCore

@MainActor @Observable
final class HomeStore {
    var home = ResolvedHome(floors: [])
    var states: [String: EntityState] = [:]
    var historyByKey: [String: HistorySeries] = [:]
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
        presented = nil
        isResetting = false
    }

    func isOn(_ entityId: String) -> Bool { states[entityId]?.state == "on" }

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

    func setBrightness(_ id: String, percent: Int) {
        guard let connection else { return }
        Task { try? await connection.setBrightness(id, percent: percent) }
    }

    /// Fire-and-forget, matching `setBrightness` exactly: no optimistic write into `states`,
    /// since the light modal's own `dragKelvin` local state already covers the in-flight
    /// preview and committing an unconfirmed kelvin value here would need the same
    /// isOn-consistent rollback brightness deliberately doesn't do either.
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

    func setCoverPosition(_ id: String, percent: Int) {
        guard let connection else { return }
        Task { try? await connection.setCoverPosition(id, percent: percent) }
    }

    // MARK: - Media player

    /// Play ⇄ pause. Which service is sent follows from the state we just wrote optimistically, so
    /// the two can never disagree about which direction the tap was going.
    func mediaPlayPause(_ id: String) {
        guard let current = states[id] else { return }
        let wasPlaying = MediaPlayerState(current).isPlaying
        optimisticMedia(id, MediaPlayerOptimistic.playPause(current, now: Date())) { c in
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

    func setMediaVolume(_ id: String, percent: Int) {
        guard let current = states[id] else { return }
        optimisticMedia(id, MediaPlayerOptimistic.volume(current, percent: percent)) { c in
            try await c.setMediaVolume(id, percent: percent)
        }
    }

    func setMediaMuted(_ id: String, muted: Bool) {
        guard let current = states[id] else { return }
        optimisticMedia(id, MediaPlayerOptimistic.mute(current, muted: muted)) { c in
            try await c.setMediaMuted(id, muted: muted)
        }
    }

    func selectMediaSource(_ id: String, source: String) {
        guard let current = states[id] else { return }
        optimisticMedia(id, MediaPlayerOptimistic.source(current, source)) { c in
            try await c.selectMediaSource(id, source: source)
        }
    }

    /// Power, never play/pause — the modal only offers this where `supported_features` declares
    /// both halves.
    func setMediaPower(_ id: String, on: Bool) {
        guard let current = states[id] else { return }
        optimisticMedia(id, MediaPlayerOptimistic.power(current, on: on)) { c in
            try await c.setMediaPower(id, on: on)
        }
    }

    /// The media-player flavour of `optimistic(_:on:_:)`: the caller hands over an already-computed
    /// next `EntityState` rather than a single on/off, because a media command implies a *set* of
    /// attributes — pausing restamps the position so the progress bar doesn't jump backwards, and
    /// powering off clears the whole now-playing set. Those transforms are
    /// `MediaPlayerOptimistic`'s, in HavenCore with tests; nothing is decided here.
    ///
    /// Rollback compares the whole entity, not one field, and so is strictly safer than the on/off
    /// version: any state push that landed while the command was in flight leaves the comparison
    /// unequal and the rollback is skipped, exactly as intended.
    private func optimisticMedia(_ id: String, _ next: EntityState,
                                 _ work: @escaping @Sendable (HomeConnection) async throws -> Void) {
        guard let connection, let previous = states[id] else { return }
        states[id] = next
        Task {
            do { try await work(connection) }
            catch { if self.states[id] == next { self.states[id] = previous } }
        }
    }

    // MARK: - Room roll-ups + bulk actions

    func rooms() -> [RoomSection] { SectionBuilder.rooms(from: home) }

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

    /// Turns off every entity in the roll-up (e.g. "All off" for a room's lights).
    /// Reuses `setLight`, which is already the optimistic flip → command → rollback
    /// primitive for a single entity, so each entity's failure is isolated from the rest.
    /// Entities already off are skipped so this doesn't spam HA with redundant calls.
    func allOff(_ rollup: Rollup) {
        guard rollup.kind == .lights else {
            assertionFailure("allOff called with rollup.kind == \(rollup.kind), expected .lights")
            return
        }
        for id in rollup.targetEntityIds {
            guard states[id]?.state == "on" else { continue }
            setLight(id, on: false)
        }
    }

    /// Closes every cover in the roll-up (e.g. "Close all" for a room's covers). Covers use
    /// "open"/"closed" rather than "on"/"off", so this mirrors `openCloseCover(_:)`'s
    /// per-entity optimistic flip → command → rollback instead of the on/off helper.
    /// Already-closed (or closing) covers are skipped.
    func closeAll(_ rollup: Rollup) {
        guard rollup.kind == .covers else {
            assertionFailure("closeAll called with rollup.kind == \(rollup.kind), expected .covers")
            return
        }
        for id in rollup.targetEntityIds {
            let current = states[id]?.state
            guard current == "open" || current == "opening" else { continue }
            optimisticClose(id)
        }
    }

    /// Per-entity optimistic close for one cover: flip state immediately, run the command,
    /// roll back on failure. Isolated per entity so one failing cover doesn't undo the rest.
    /// Rollback only fires if the entity still holds the value we optimistically wrote, so a
    /// late failure can't clobber state that changed in the meantime.
    private func optimisticClose(_ id: String) {
        guard let connection, var s = states[id] else { return }
        let previous = s
        let optimisticValue = "closed"
        s.state = optimisticValue
        states[id] = s
        Task {
            do { try await connection.closeCover(id) }
            catch { if self.states[id]?.state == optimisticValue { self.states[id] = previous } }
        }
    }

    /// Cached read for a previously-loaded history series. `nil` means "not loaded yet"
    /// (or the load failed) — callers should render an empty/loading state, not crash.
    func history(_ entityId: String, _ range: HistoryRange) -> HistorySeries? {
        historyByKey["\(entityId)#\(range)"]
    }

    /// Fetches and caches a history series for `entityId`/`range`. Reuses the cache when
    /// already populated (a range switch always misses since the key changes); never
    /// caches a failure, so a transient error doesn't permanently block a later retry.
    func loadHistory(_ entityId: String, range: HistoryRange) async {
        let key = "\(entityId)#\(range)"
        guard historyByKey[key] == nil else { return }
        guard let connection else { return }
        do {
            historyByKey[key] = try await connection.history(entityId: entityId, range: range, now: Date())
        } catch {
            // Leave the cache untouched so a later attempt (e.g. reopening the modal) can retry.
        }
    }
}
