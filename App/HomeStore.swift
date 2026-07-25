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
}
