import SwiftUI
import HavenCore

@MainActor @Observable
final class HomeStore {
    var home = ResolvedHome(floors: [])
    var states: [String: EntityState] = [:]
    var historyByKey: [String: HistorySeries] = [:]
    private var connection: HomeConnection?
    private var subscriptionTask: Task<Void, Never>?

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
        }
    }

    /// Tear down the live session (used on sign-out). Clears history and any open modal
    /// too — otherwise signing into a different HA instance can show the previous
    /// account's chart data for a same-named sensor, or leave a stale modal presented.
    func reset() {
        subscriptionTask?.cancel(); subscriptionTask = nil
        connection = nil
        home = ResolvedHome(floors: [])
        states = [:]
        historyByKey = [:]
        presented = nil
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

    // MARK: - Room roll-ups + bulk actions

    func rooms() -> [RoomSection] { SectionBuilder.rooms(from: home) }

    /// Flattens a room's `deviceRefs` down to the plain entity ids `RoomRollups` needs.
    /// Only `.entity` refs carry a single id today; `.composite` refs aren't constructed
    /// anywhere yet, so they're skipped here. Once composites exist, this will need to
    /// expand each one into its constituent input entities instead of dropping it.
    private func deviceEntityIds(_ room: RoomSection) -> [String] {
        room.deviceRefs.compactMap { ref in
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
