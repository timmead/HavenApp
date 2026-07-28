import SwiftUI
import HavenCore

/// Which sensor is a room's thermometer, and the shared configuration that decides it.
///
/// The third seam out of `HomeStore`, and the one with the most going on: it owns Haven's dashboard
/// document, resolves each room's nomination from it, and writes back the ones this device proposed
/// — including the version-conflict retry when two admins' phones bootstrap at once.
///
/// **It takes `home` and `states` as arguments rather than holding a reference back to the store.**
/// The dependency runs one way, which is what makes this a seam rather than a second name for the
/// same object: the store owns what Home Assistant said, this owns what the household configured,
/// and the join happens at the call site.
///
/// **`@Observable`, and load-bearing.** `RoomEnvironmentChips` renders from `byArea` by way of
/// `HomeStore.rooms()`, so the nominations must stay observable through the store's reference here.
@MainActor @Observable
final class EnvironmentCoordinator {
    static let dashboardKey = "dashboard"

    /// Each room's nominated temperature/humidity source, keyed by area id.
    ///
    /// Resolved once per structure load — deliberately *not* on every state change, even though
    /// candidacy reads `device_class` out of `states`. `rooms()` runs inside `DashboardView.body`,
    /// so anything derived from live state recomputes on every tick; a nomination recomputed there
    /// would silently switch a room to a different physical thermometer the moment the nominated
    /// one went unavailable and dropped its attributes. Which sensor is the room's is
    /// configuration; only the reading is live data.
    private(set) var byArea: [String: RoomEnvironment] = [:]

    /// Haven's dashboard definition, as loaded from the `havenapp` integration. Held so a write-back
    /// merges into what the household actually has rather than replacing it — see
    /// `DashboardDocument`.
    private var dashboard = DashboardDocument()
    private var connection: HomeConnection?

    func attach(_ connection: HomeConnection?) { self.connection = connection }

    func reset() {
        connection = nil
        byArea = [:]
        dashboard = DashboardDocument()
    }

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
    func load(home: ResolvedHome, states: [String: EntityState]) async {
        guard let connection else { return }
        do {
            let record = try await connection.loadConfig(scope: HavenConfigScope.shared,
                                                         key: Self.dashboardKey)
            dashboard = DashboardDocument(raw: record?.payload)
            resolve(home: home, states: states)
            await persistProposedNominations(baseVersion: record?.version ?? 0,
                                             home: home, states: states)
        } catch {
            havenLog.error("dashboard config unreadable, falling back to proposed nominations: \(error)")
            dashboard = DashboardDocument()
            resolve(home: home, states: states)
        }
    }

    /// Resolves every room's environment from the current registry, the current states and the
    /// loaded dashboard document.
    ///
    /// The `states` join is the App layer's job for the same reason it is in `cameraEvents()`:
    /// `device_class` lives on entity state, not in the entity registry (HA's
    /// `config/entity_registry/list` returns `as_partial_dict`, which omits it). Every rule about
    /// what may be nominated lives in `RoomEnvironmentResolver`; nothing is decided here.
    func resolve(home: ResolvedHome, states: [String: EntityState]) {
        byArea = RoomEnvironmentResolver.resolve(
            home: home,
            sources: states.mapValues(RoomEnvironmentSource.init),
            stored: dashboard.nominations,
            // A proposal is only worth *writing* if it currently reads. See the resolver: a stored
            // nomination is never re-picked, so a pick made while the room's real sensor happened
            // to be offline would be permanently wrong.
            isReadable: { sensor in
                EnvironmentReading.value(sensor, state: states[sensor.entityId]) != nil
            })
    }

    /// Writes this device's proposed nominations into the shared dashboard document.
    ///
    /// Skipped entirely when there is nothing new to say — a no-op write on every launch would
    /// churn the shared record's version and `updated_by` for nothing.
    private func persistProposedNominations(baseVersion: Int, isRetry: Bool = false,
                                            home: ResolvedHome,
                                            states: [String: EntityState]) async {
        guard let connection, dashboard.isWritable else { return }
        let proposals = byArea.compactMapValues(\.nominationsToPersist)
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
                resolve(home: home, states: states)
                await persistProposedNominations(baseVersion: current?.version ?? 0, isRetry: true,
                                                 home: home, states: states)
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
}
