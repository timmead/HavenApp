import SwiftUI
import HavenCore

/// Which sensor is a room's thermometer.
///
/// The third seam out of `HomeStore`. It used to own Haven's dashboard document and its write path
/// as well; both moved to `HavenConfig` when configuration stopped being only about sensors, and
/// what is left here is the part that was always this type's own: **which sensor is the room's**,
/// which is a domain rule, resolved from whatever the document says.
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
    /// Each room's nominated temperature/humidity source, keyed by area id.
    ///
    /// Resolved once per structure load — deliberately *not* on every state change, even though
    /// candidacy reads `device_class` out of `states`. `rooms()` runs inside `DashboardView.body`,
    /// so anything derived from live state recomputes on every tick; a nomination recomputed there
    /// would silently switch a room to a different physical thermometer the moment the nominated
    /// one went unavailable and dropped its attributes. Which sensor is the room's is
    /// configuration; only the reading is live data.
    private(set) var byArea: [String: RoomEnvironment] = [:]

    func reset() { byArea = [:] }

    /// Resolves every room's environment from the current registry, the current states and the
    /// household's dashboard document.
    ///
    /// The document is a parameter rather than a stored property now that `HavenConfig` owns it:
    /// this type decides *which sensor is the room's*, which is a domain rule, and owns none of the
    /// storage that decision is read from or written to.
    ///
    /// The `states` join is the App layer's job for the same reason it is in `cameraEvents()`:
    /// `device_class` lives on entity state, not in the entity registry (HA's
    /// `config/entity_registry/list` returns `as_partial_dict`, which omits it). Every rule about
    /// what may be nominated lives in `RoomEnvironmentResolver`; nothing is decided here.
    func resolve(home: ResolvedHome, states: [String: EntityState], document: DashboardDocument) {
        byArea = RoomEnvironmentResolver.resolve(
            home: home,
            sources: states.mapValues(RoomEnvironmentSource.init),
            stored: document.nominations,
            // A proposal is only worth *writing* if it currently reads. See the resolver: a stored
            // nomination is never re-picked, so a pick made while the room's real sensor happened
            // to be offline would be permanently wrong.
            isReadable: { sensor in
                EnvironmentReading.value(sensor, state: states[sensor.entityId]) != nil
            })
    }

    /// Resolves against the household's document and writes back any nomination this device
    /// *proposed* — the auto-pick that primes a room the first time Haven sees it.
    ///
    /// **The mutation re-resolves rather than closing over a finished set of proposals**, because
    /// `HavenConfig.update` may hand it a *different* document on a conflict retry: another admin's
    /// phone may have nominated the same rooms first, and proposing over their picks would undo
    /// them. Re-resolving means the retry proposes only what is still unproposed — which is exactly
    /// what the previous version of this did by calling `resolve` again inside its own retry.
    ///
    /// Nothing here can fail a session. `HavenConfig.load` swallows its own read errors and
    /// `update` reports a refused write as an outcome rather than throwing, so a household member
    /// who is not an admin simply keeps the proposals on screen unwritten.
    func loadAndPropose(home: ResolvedHome, states: [String: EntityState],
                        config: HavenConfig) async {
        resolve(home: home, states: states, document: config.document)
        await config.update { [weak self] document in
            guard let self else { return document }
            self.resolve(home: home, states: states, document: document)
            let proposals = self.byArea.compactMapValues(\.nominationsToPersist)
            return proposals.isEmpty ? document : document.merging(proposals)
        }
    }
}
