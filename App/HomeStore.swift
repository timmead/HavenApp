import SwiftUI
import HavenCore

@MainActor @Observable
final class HomeStore {
    var home = ResolvedHome(floors: [])
    var states: [String: EntityState] = [:]
    private var connection: HomeConnection?

    func attach(_ connection: HomeConnection) { self.connection = connection }

    func bootstrap() async throws {
        guard let connection else { return }
        home = try await connection.loadStructure()
        for s in try await connection.loadStates() { states[s.entityId] = s }
        let stream = try await connection.subscribeStateChanges()
        Task { for await s in stream { self.states[s.entityId] = s } }
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
