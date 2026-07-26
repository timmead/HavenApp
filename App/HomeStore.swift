import SwiftUI
import HavenCore

@MainActor @Observable
final class HomeStore {
    var home = ResolvedHome(floors: [])
    var states: [String: EntityState] = [:]
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

    /// Tear down the live session (used on sign-out).
    func reset() {
        subscriptionTask?.cancel(); subscriptionTask = nil
        connection = nil
        home = ResolvedHome(floors: [])
        states = [:]
    }

    func isOn(_ entityId: String) -> Bool { states[entityId]?.state == "on" }

    func toggleLightOptimistic(_ entityId: String) {
        guard let connection, var s = states[entityId] else { return }
        let previous = s
        s.state = (s.state == "on") ? "off" : "on"      // optimistic flip
        states[entityId] = s
        Task {
            do { try await connection.toggleLight(entityId: entityId) }
            catch { self.states[entityId] = previous }    // rollback
        }
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

    /// Flip local state immediately, run the command, roll back on failure.
    private func optimistic(_ id: String, on: Bool, _ work: @escaping @Sendable (HomeConnection) async throws -> Void) {
        guard let connection, var s = states[id] else { return }
        let previous = s
        s.state = on ? "on" : "off"
        states[id] = s
        Task { do { try await work(connection) } catch { self.states[id] = previous } }
    }

    func openCloseCover(_ id: String) {
        guard let connection, var s = states[id] else { return }
        let previous = s
        let open = s.state == "open" || s.state == "opening"
        s.state = open ? "closed" : "open"
        states[id] = s
        Task {
            do { try await (open ? connection.closeCover(id) : connection.openCover(id)) }
            catch { self.states[id] = previous }
        }
    }

    func toggleLock(_ id: String) {
        guard let connection, var s = states[id] else { return }
        let previous = s
        let locked = s.state == "locked"
        s.state = locked ? "unlocked" : "locked"
        states[id] = s
        Task {
            do { try await connection.setLock(id, locked: !locked) }
            catch { self.states[id] = previous }
        }
    }

    /// Fire-and-forget scene/script/button activation. No optimistic local state to update.
    func run(_ id: String) {
        guard let connection else { return }
        Task { try? await connection.activate(sceneOrScript: id) }
    }
}
