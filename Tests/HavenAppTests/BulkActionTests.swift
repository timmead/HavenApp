import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// A bulk action that half-fails currently reverts the failed rows and says nothing — the user
/// sees three of five lights flick back on with no explanation. The count is what the roll-up row
/// renders.
@Suite @MainActor struct BulkActionTests {
    private func store(lightsOn ids: [String]) -> HomeStore {
        let s = HomeStore()
        for id in ids {
            s.states[id] = EntityState(entityId: id, state: "on", attributes: [:],
                                       lastUpdated: Date(timeIntervalSince1970: 0))
        }
        return s
    }

    @Test func aFreshStoreReportsNoFailures() {
        #expect(store(lightsOn: []).bulkFailureCount(for: .lights) == 0)
    }

    /// Recorded per kind, so a failed "All off" does not put a count on the Shades row.
    @Test func failuresAreRecordedPerKind() {
        let s = store(lightsOn: [])
        s.recordBulkFailures(2, for: .lights)
        #expect(s.bulkFailureCount(for: .lights) == 2)
        #expect(s.bulkFailureCount(for: .covers) == 0)
    }

    /// A later successful run must clear the previous complaint, or the row keeps accusing the
    /// user of a failure that has since been fixed.
    @Test func recordingZeroClearsAPreviousFailure() {
        let s = store(lightsOn: [])
        s.recordBulkFailures(3, for: .lights)
        s.recordBulkFailures(0, for: .lights)
        #expect(s.bulkFailureCount(for: .lights) == 0)
    }
}
