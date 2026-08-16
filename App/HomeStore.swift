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

    /// Stores the order a room's tiles were arranged into **on one surface** — design decision 9.
    ///
    /// Written whole: a reorder is not a delta anyone would want merged, and two people rearranging
    /// one room should end with the last one winning — which the conflict retry already gives.
    ///
    /// The surface is the one the drag happened on, and it is the whole point: a drag can only
    /// persist the ids it can see, so an overview drag writing the room's single shared list used to
    /// destroy the arranged position of every tile that lives only in room detail. Now it writes
    /// `overview` and room detail's list is not its business.
    func setOrder(_ ids: [String], areaId: String,
                  on surface: HavenSurface) async -> HavenConfig.Outcome {
        await config.update { $0.settingOrder(ids, forRoom: areaId, on: surface) }
    }

    /// Forgets a room's arrangement **on both surfaces**, so it falls back to the default order.
    ///
    /// The only way out of an arrangement you dislike other than dragging your way out of it, which
    /// is exactly when dragging is least appealing.
    ///
    /// **Both, not the one you happened to be looking at**, and that is not laziness about plumbing
    /// a surface through. Clearing one surface alone does not restore the default: an unset surface
    /// *follows its sibling* (see `RoomSection.refs(for:)`), so a "reset" that cleared only the
    /// overview would make the dashboard adopt room detail's arrangement — a button labelled "Puts
    /// this room's tiles back in their default order" doing something else entirely. Clearing both
    /// is the only spelling under which that sentence is true. `RoomConfigView` carries an area and
    /// no surface, which is the same fact from the other end.
    ///
    /// One `update`, two mutations: two writes would be two conflict windows for one user action.
    func resetOrder(areaId: String) async -> HavenConfig.Outcome {
        await config.update {
            $0.settingOrder([], forRoom: areaId, on: .overview)
                .settingOrder([], forRoom: areaId, on: .roomDetail)
        }
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
            guard !showing.contains(ref.id) else { return nil }
            // **Composites are offerable too, and leaving them out stranded one.** This walked only
            // `.entity` refs, from when nothing constructed composites. A garage door the household
            // removed then vanished completely: hidden by its membership override, and absent from
            // this list because it was no longer a plain entity — off the dashboard with no way back
            // to it.
            //
            // Curation's `.hidden` still bars a plain entity, because that is Home Assistant's own
            // decision and it outranks ours. A composite has no tier: somebody made it deliberately.
            if case .entity(let id) = ref, room.tier(of: id) == .hidden { return nil }
            return ref.id
        }.sorted()
    }

    /// Sets or clears Haven's own name for a device. Never renames the entity in Home Assistant —
    /// HA stays the source of truth for structure, and this is Haven's layer on top.
    func rename(_ entityId: String, to name: String?) async -> HavenConfig.Outcome {
        await config.update { $0.settingDisplayName(name, for: entityId) }
    }

    /// Whether a two-state tile shows a glyph or a word. `.icon` unless the household said otherwise.
    func stateStyle(of entityId: String) -> TileStateStyle {
        config.document.tileStateStyles[entityId] ?? .icon
    }

    /// Commits everything one configuration sheet holds, in a **single** write.
    ///
    /// Not a convenience over `rename` and a state-style setter called in turn: each write bumps the
    /// shared record's version, so two writes are two conflict windows and two chances for another
    /// phone in the household to read a half-applied edit. One closure, one version, one retry.
    ///
    /// **No longer takes a size.** Per-entity sizing moved to the subsection sheet — see
    /// `applySubsectionConfig` — and `TileConfigView` has had no size control to pass one from since
    /// Task 6; Task 7 deleted `settingSize` from Core and this parameter with it, rather than leave a
    /// signature that could still express a decision nothing in the app makes any more.
    func applyTileConfig(_ entityId: String, name: String?,
                         stateStyle: TileStateStyle?? = nil,
                         bindings: [DeviceRole: String?]? = nil,
                         on surface: HavenSurface) async -> HavenConfig.Outcome {
        await config.update { document in
            var next = document.settingDisplayName(name, for: entityId)
            if let stateStyle {
                next = next.settingStateStyle(stateStyle, for: entityId)
            }
            // Roles live in the device's own inputs — one home for them, since choosing a type is
            // what creates the device they belong to.
            if let bindings, var stored = next.devices[entityId] {
                var inputs = stored.inputs
                for (role, target) in bindings {
                    if let target, !target.isEmpty { inputs[role] = [target] }
                    else { inputs.removeValue(forKey: role) }
                }
                stored = DashboardDocument.StoredDevice(id: stored.id, type: stored.type,
                                                        areaId: stored.areaId, inputs: inputs)
                next = next.settingDevice(stored, id: entityId)
            }
            return next
        }
    }

    // `device` through `roomEntityIds` below are pure functions of the document or the home, and now
    // live in HavenCore beside the types they read (`DashboardDocument.deviceRef(for:)` and friends,
    // `ResolvedHome.areaEntityIds(containing:)`), with `DeviceResolutionTests` on them. Their
    // reasoning moved with them; what stays here is the join, and the reason it stays is
    // observation: a view reading `store.device(id)` registers a dependency on `config.document`
    // exactly as it did when the lookup was written out here.

    /// The device behind an id — a stored composite, or the entity itself.
    func device(_ id: String) -> DeviceRef { config.document.deviceRef(for: id) }

    /// What kind of thing a device is.
    func deviceType(of id: String) -> DeviceType { config.document.deviceType(for: id) }

    /// Which entity plays which role for this device.
    func bindings(of id: String) -> [DeviceRole: String] { config.document.roleBindings(for: id) }

    /// Every entity in the room that holds `entityId` — the pool a shade group's followers come
    /// from.
    func roomEntityIds(containing entityId: String) -> [String] {
        home.areaEntityIds(containing: entityId)
    }

    /// Which subsections a room resolves into — see `Subsections.resolve`. Beside `device(_:)`
    /// above for the same observation reason: a view reading `store.subsections(_:on:)` must
    /// register a dependency on `config.document`.
    func subsections(_ room: RoomSection, on surface: HavenSurface) -> [RoomSubsection] {
        Subsections.resolve(room: room, surface: surface, document: config.document)
    }

    /// Commits one subsection's size **on one surface**, and its mode, in a single write —
    /// `applyTileConfig`'s reasoning applies unchanged: two settings, one closure, one version, one
    /// conflict window.
    ///
    /// `span` is on `surface` alone (decision 10) — the sheet is always opened from a surface and
    /// edits that surface's size, never the other one's, so this has no reason to take a second
    /// surface for the span it does not touch. `mode` stays per-kind, unaffected by which surface
    /// the sheet opened from.
    ///
    /// Both are `??`, like `applyTileConfig`'s `size`: `.some(nil)` writes an explicit "follow the
    /// default", `nil` leaves whatever is stored alone. `SubsectionConfigView` never has a reason to
    /// pass `nil` for span — its picker always holds a concrete choice — but the shape matches its
    /// sibling mutator rather than special-casing the one that happens not to use it yet.
    func applySubsectionConfig(_ kind: SubsectionKind, span: TileSpan??, mode: SubsectionMode??,
                               on surface: HavenSurface) async -> HavenConfig.Outcome {
        await config.update { document in
            var next = document
            if let span { next = next.settingSubsectionSpan(span, kind: kind, on: surface) }
            if let mode { next = next.settingSubsectionMode(mode, kind: kind) }
            return next
        }
    }

    /// The household's default subsection display mode — the middle link in the fallback chain: a
    /// per-kind override, then this, then the built-in `scroll` (see `Subsections.resolve`). `nil`
    /// clears it back to that built-in.
    func setDisplayMode(_ mode: SubsectionMode?) async -> HavenConfig.Outcome {
        await config.update { $0.settingDisplayMode(mode) }
    }

    /// Creates a composite: a device of `type` whose primary is `primary`, in `primary`'s room.
    ///
    /// **Its id is the primary's entity id**, which is the same rule a one-entity device follows —
    /// so there is exactly one id space in the app and it is entity ids. Every surface already
    /// renders a ref by its primary, and every stored name, size, style, membership and order is
    /// keyed that way, so a device that changes type keeps all of it.
    ///
    /// A generated id was the first attempt and was wrong in a way nothing caught: the room rendered
    /// the tile under the *primary's* id while the record lived under `haven:…`, so a garage door
    /// came back as a switch on the next launch and removing it wrote membership for an id the
    /// device was not stored under. The gallery's fixtures had keyed devices by entity id all along,
    /// which is why they rendered correctly and a real one did not.
    ///
    /// What this gives up is changing which entity is the primary — that would move the id and
    /// orphan the settings. Changing a device's primary is a different device, and nothing offers
    /// it.
    func createDevice(type: DeviceType, primary: String,
                      areaId: String) async -> String? {
        let device = DashboardDocument.StoredDevice(
            id: primary, type: type.id, areaId: areaId, inputs: [.primary: [primary]])
        switch await config.update({ $0.settingDevice(device, id: primary) }) {
        case .written, .unchanged: return primary
        case .notAuthorized, .failed: return nil
        }
    }

    /// Drops a composite back to the plain entity it was built around.
    func removeDevice(_ id: String) async -> HavenConfig.Outcome {
        await config.update { $0.settingDevice(nil, id: id) }
    }

    /// Sets or clears one role on a composite, leaving its other inputs alone.
    func setRole(_ role: DeviceRole, to entityIds: [String],
                 on deviceId: String) async -> HavenConfig.Outcome {
        await config.update { document in
            guard var stored = document.devices[deviceId] else { return document }
            var inputs = stored.inputs
            if entityIds.isEmpty {
                inputs.removeValue(forKey: role)
            } else {
                inputs[role] = entityIds
            }
            stored = DashboardDocument.StoredDevice(id: stored.id, type: stored.type,
                                                    areaId: stored.areaId, inputs: inputs)
            return document.settingDevice(stored, id: deviceId)
        }
    }

    /// The companions a role could be bound to: this device's own entities, minus the primary.
    /// See `ResolvedHome.siblingEntityIds(of:)` for the `device_id` join and why an empty one is
    /// not a device.
    func bindableEntityIds(for entityId: String) -> [String] {
        home.siblingEntityIds(of: entityId)
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

    /// A device's state — the entity being rendered, plus the companions that qualify it.
    ///
    /// Flattens the per-area tier maps on **every call, inside `body`**. An earlier version of this
    /// comment claimed the flatten was "read when a modal opens rather than per frame"; it is not.
    /// `SwitchTile` and `CoverTile` each call this three times inside `body`, so it runs several
    /// times over for every visible switch and cover tile every time a state push redraws the grid
    /// — the modal cards (`DeviceStateCard`, `DeviceContextCard`) are the *minority* of the call
    /// sites, not all of them.
    ///
    /// The map is still built here, where it is needed, rather than cached: a third source of truth
    /// to keep in step with `home` and `states` is the cost being avoided, and that reason stands
    /// whatever the call frequency turns out to be. What no longer stands is the claim that the
    /// frequency is low, so anyone measuring a slow grid should start here rather than trust the
    /// comment.
    ///
    /// **A camera's event sensors are excluded**, because `CameraModal` already draws them as chips
    /// with a curated kind and its own most-alarming-first ordering. That exclusion lives here and
    /// not in the resolver: which view draws what is a rendering fact, not a fact about the device.
    func deviceState(of entityId: String) -> DeviceState {
        var tiers: [String: CurationTier] = [:]
        for floor in home.floors {
            for area in floor.areas { tiers.merge(area.tiers) { _, new in new } }
        }
        let excluded: Set<String> = Domain.of(entityId) == .camera
            ? Set(cameraEvents(entityId).map(\.entityId))
            : []
        return CompositeState.resolve(primary: entityId,
                                      deviceId: home.registryInfo[entityId]?.deviceId,
                                      registry: home.registryInfo,
                                      tiers: tiers,
                                      states: states,
                                      type: deviceType(of: entityId),
                                      bindings: bindings(of: entityId),
                                      excluding: excluded)
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
                             devices: config.document.devices,
                             overrides: config.document.surfaceOverrides,
                             // Per surface now — see `RoomSection.refs(for:)` for the fallback
                             // chain that turns these into what each surface actually renders. A
                             // room with nothing stored, and one still carrying the pre-decision-9
                             // array shape, both arrive here as `[:]`.
                             orders: home.floors.flatMap(\.areas).reduce(into: [:]) { out, area in
                                 let orders = config.document.orders(forRoom: area.id)
                                 if !orders.isEmpty { out[area.id] = orders }
                             })
    }

    /// Flattens `surface`'s refs down to the plain entity ids `RoomRollups` needs.
    ///
    /// `refs(for: surface)` rather than a fixed one, so "3/5 lights on · All Off" counts and acts
    /// on exactly the tiles *that surface* shows — see `rollups(_:on:)` for why.
    ///
    /// That covers the household's own removals as well as curation's, and it follows from the
    /// same sentence rather than being a new rule: a tile a user took off a surface is one they
    /// cannot see there, so it drops out of that surface's count and out of that surface's action —
    /// while still counting and acting on the other surface, if it shows there.
    /// Only `.entity` refs carry a single id today; `.composite` refs aren't constructed
    /// anywhere yet, so they're skipped here. Once composites exist, this will need to
    /// expand each one into its constituent input entities instead of dropping it.
    private func deviceEntityIds(_ room: RoomSection, on surface: HavenSurface) -> [String] {
        room.refs(for: surface).compactMap { ref in
            if case .entity(let id) = ref { return id }
            return nil
        }
    }

    /// A room's roll-ups — "3/5 lights on", "2/2 shades open" — as `surface` sees them.
    ///
    /// **Household rule, and the reason this takes a surface at all: an "all off" or "close all"
    /// must reach only what the household can see when they tap it, or the button confuses more
    /// than it helps.** So both halves of a `Rollup` — the count and `targetEntityIds`, which
    /// `allOff`/`closeAll`/`bulkFlip` act on unchanged — are derived from the same
    /// `deviceEntityIds(_:on:)` call, scoped to `surface`. A room detail heading counts and acts on
    /// room detail's set; a dashboard heading counts and acts on the dashboard's — never each
    /// other's, and count and action can never disagree because they are the same list.
    func rollups(_ room: RoomSection, on surface: HavenSurface) -> [Rollup] {
        RoomRollups.compute(entityIds: deviceEntityIds(room, on: surface), states: states)
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
    /// caller is `SubsectionView`, rendering a heading whose kind it already
    /// knows, so a mismatch is a programming error and `assertionFailure` names the caller
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

// MARK: - Commands
//
// Everything Haven sends to Home Assistant, grouped by the domain it acts on. These were a flat run
// of thirty-odd methods in the class body above, over three near-identical private primitives; the
// primitives are now one `command(_:_:_:)` with an explicit mode, and each domain is an `extension`
// so that a light's rules sit with the other light rules rather than wherever the method happened to
// be added.
//
// They stay on `HomeStore`, reading and writing `states` directly, because the views observe this
// object: moving the command layer onto a child would move the observation dependency with it.

extension HomeStore {
    /// What a command writes locally while it is in flight — the one axis the three primitives this
    /// replaced actually differed on. Everything else about them (finding the connection, the
    /// unavailability guard, running the work in a `Task`, undoing a failure) was the same thing
    /// three times over.
    private enum OptimisticWrite {
        /// Write nothing, and so have nothing to roll back.
        ///
        /// *Why* each such command writes nothing is recorded on the individual methods, because the
        /// answer differs: a scene has no on/off of its own to predict; the next track is unknowable
        /// until the device says so; a kelvin value is a reading nothing on the grid displays. What
        /// is shared, and what lives here, is the guard on `command(_:_:_:)` below.
        case nothing

        /// Write one state string, and roll back only if that string still stands.
        ///
        /// The flip lights, switches, locks and the open/close tap all take. `toggle` delegates to
        /// `setLight`/`setSwitch` rather than duplicating the flip, and `toggleLock` and
        /// `openCloseCover` — which used to be this block written out a second and third time, each
        /// with its own copy of the rollback rule — now go through it too.
        case flip(to: String)

        /// Write a whole `EntityState`, and roll back only if it is still untouched.
        ///
        /// The caller hands over an already-computed next state rather than a single on/off, because
        /// most commands imply a *set* of attributes — pausing a player restamps the position so the
        /// progress bar doesn't jump backwards, powering one off clears the whole now-playing set,
        /// setting a cover's position changes whether it is open, and giving a light a brightness
        /// turns it on. Those transforms live in `MediaPlayerOptimistic`, `LightOptimistic` and
        /// `CoverOptimistic`, in HavenCore with tests; nothing is decided here.
        ///
        /// Its rollback compares the whole entity, not one field, and so is strictly safer than
        /// `.flip(to:)`'s: any state push that landed while the command was in flight leaves the
        /// comparison unequal and the rollback is skipped, exactly as intended. The two comparisons
        /// are deliberately not unified — `.flip(to:)` knows only the one field it wrote, and
        /// widening it to the whole entity would silently stop rolling back the case it exists for.
        ///
        /// Safer at rollback is not safer at the guard, and this mode is the one brightness, cover
        /// position, and media volume/mute/source/power all take: left unguarded, any of them could
        /// write a confident-looking `next` state over an unreachable device and send the matching
        /// command into the void.
        case whole(EntityState)
    }

    /// Runs one command against Home Assistant: write what we predict, send it, and undo the
    /// prediction if it fails — but only if the entity still holds the value we optimistically
    /// wrote, so a late failure can't clobber state that changed in the meantime (e.g. attributes
    /// from a WS push while in flight).
    ///
    /// **One primitive rather than three.** `optimistic(_:on:_:)`, `optimisticState(_:_:_:)` and
    /// `fireAndForget(_:_:)` differed only in what they wrote before sending, which is now
    /// `OptimisticWrite` above. Shared by every domain rather than copied per domain — the D spec
    /// already flagged five near-identical flip/command/rollback blocks in this file as wanting
    /// extraction, and adding a sixth and seventh for lights and covers would have been the wrong
    /// direction.
    ///
    /// **Guarded on `state == "unavailable"` alone, not `EntityState.isUnavailable`, which also
    /// covers `unknown`.** Both halves of that matter, and `UnavailableCommandGuardTests` pins both
    /// against the frames actually sent.
    ///
    /// The unreachable half is a defect that shipped. `optimistic(_:on:_:)` — the primitive `toggle`
    /// delegated to for lights, switches and input booleans — used to write
    /// `states[id].state = "on"` unconditionally: `isUnavailable` then read `false`, the strike
    /// vanished, and the tile looked exactly like a working light that was just switched on — and
    /// the command still went out to a device that cannot act on it. `toggleLock` and
    /// `openCloseCover` were the same class of bug at higher and lower stakes, and were guarded
    /// first — `optimistic(_:on:_:)` was the one gap those two didn't close.
    ///
    /// A command that writes nothing is not exempt. There is no optimistic write there to make an
    /// unreachable device *look* available, but the entity still has no business receiving a command
    /// it cannot act on, and Home Assistant will not tell us it didn't: `call_service` against an
    /// entity the integration cannot reach answers *success* and does nothing. That failure is
    /// invisible locally — nothing is written to `states`, so the store looks perfectly correct
    /// while the command goes out anyway — and the wire is the only place it shows.
    ///
    /// `unknown` is deliberately let through, in every mode: that entity **is** reachable and has
    /// simply not reported yet, so refusing it would remove the one interaction that could resolve
    /// it.
    ///
    /// Stating that guard exactly once is most of the point of the consolidation. It was previously
    /// hand-copied into ten separate fire-and-forget methods, which is ten independent chances to
    /// write the eleventh command without it.
    ///
    /// `.nothing` still acts on an entity that has no `states` entry at all, while the two writing
    /// modes need a previous state to roll back to and return when there is none. That asymmetry is
    /// how the three primitives already behaved; it is reproduced here on purpose rather than
    /// levelled out, since levelling it either way would change what some command does.
    private func command(_ id: String, _ write: OptimisticWrite,
                         _ work: @escaping @Sendable (HomeConnection) async throws -> Void) {
        guard let connection, states[id]?.state != "unavailable" else { return }
        switch write {
        case .nothing:
            Task { try? await work(connection) }
        case .flip(let value):
            guard var next = states[id] else { return }
            let previous = next
            next.state = value
            states[id] = next
            Task {
                do { try await work(connection) }
                catch { if self.states[id]?.state == value { self.states[id] = previous } }
            }
        case .whole(let next):
            guard let previous = states[id] else { return }
            states[id] = next
            Task {
                do { try await work(connection) }
                catch { if self.states[id] == next { self.states[id] = previous } }
            }
        }
    }
}

// MARK: - Lights and switches

extension HomeStore {
    // Optimistic on/off primitives. `toggle` DELEGATES to these — do not duplicate this logic later.
    func setLight(_ id: String, on: Bool) {
        command(id, .flip(to: on ? "on" : "off")) { c in try await c.setLight(id, on: on) }
    }

    func setSwitch(_ id: String, on: Bool) {
        command(id, .flip(to: on ? "on" : "off")) { c in try await c.setSwitch(id, on: on) }
    }

    func toggle(_ id: String) {
        let on = !(states[id]?.state == "on")
        Domain.of(id) == .light ? setLight(id, on: on) : setSwitch(id, on: on)
    }

    /// Brightness, optimistically. D spec §10b item 2 names this control by name as one that
    /// visibly snaps back between release and Home Assistant's echo; `LightOptimistic.brightness`
    /// is what removes the snap, and it writes `state` as well as `brightness` because a light
    /// given a brightness is on — the tile's tint, icon and name colour all read the former.
    func setBrightness(_ id: String, percent: Int) {
        guard let current = states[id] else { return }
        command(id, .whole(LightOptimistic.brightness(current, percent: percent))) { c in
            try await c.setBrightness(id, percent: percent)
        }
    }

    /// Writes nothing, and now deliberately *unlike* `setBrightness`, which gained an optimistic
    /// write when the tiles got a draggable brightness pip.
    ///
    /// Colour temperature has no tile control and no snap-back to remove: the light modal's own
    /// `dragKelvin` covers the in-flight preview, and it is the only place a kelvin value can be
    /// set. Writing one into `states` here would be inventing a reading for an attribute nothing
    /// on the grid displays, with a rollback to get right for no visible gain.
    func setColorTemp(_ id: String, kelvin: Int) {
        command(id, .nothing) { try await $0.setColorTemp(id, kelvin: kelvin) }
    }
}

// MARK: - Locks

extension HomeStore {
    /// Guarded on `state == "unavailable"` alone — not `EntityState.isUnavailable`, which also
    /// covers `unknown`. The guard itself is `command(_:_:_:)`'s now, but the reason it exists is
    /// this lock.
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
    /// `locked` is still computed from a state that may be `unavailable`, and that is harmless: the
    /// primitive withholds both the flip and the command before either use of it is reached.
    ///
    /// `unknown` is deliberately let through: that lock *is* reachable and has simply not reported
    /// a position, so refusing to command it would strand the user in the one state a tap could
    /// resolve — the same reasoning `LockModal.actionButton` already applies to a jammed lock.
    func toggleLock(_ id: String) {
        guard let current = states[id] else { return }
        let locked = current.state == "locked"
        command(id, .flip(to: locked ? "unlocked" : "locked")) { c in
            try await c.setLock(id, locked: !locked)
        }
    }
}

// MARK: - Covers

extension HomeStore {
    /// Same class of bug as `toggleLock`, at lower stakes, and guarded the same way — by
    /// `command(_:_:_:)`, keyed on `state == "unavailable"` alone, not `isUnavailable`, so an
    /// `unavailable` cover can no longer be optimistically flipped to "open"/"closed" with nothing
    /// left to correct it, while an `unknown` cover — reachable, just unreported — still responds to
    /// a tap.
    ///
    /// Which service is sent follows from the same `open` the flip is computed from, so the two can
    /// never disagree about which direction the tap was going.
    func openCloseCover(_ id: String) {
        guard let current = states[id] else { return }
        let open = current.state == "open" || current.state == "opening"
        command(id, .flip(to: open ? "closed" : "open")) { c in
            try await (open ? c.closeCover(id) : c.openCover(id))
        }
    }

    /// Open/stop/close, unlike `openCloseCover` and `setCoverPosition`, write nothing
    /// optimistically: where those two know the state they are heading for, a cover asked to
    /// *start* moving passes through `opening`/`closing` on its own schedule, and guessing at the
    /// intermediate would fight the position pushes that follow.
    func openCover(_ id: String) {
        command(id, .nothing) { try await $0.openCover(id) }
    }

    func stopCover(_ id: String) {
        command(id, .nothing) { try await $0.stopCover(id) }
    }

    func closeCover(_ id: String) {
        command(id, .nothing) { try await $0.closeCover(id) }
    }

    /// Cover position, optimistically — and the open/closed state with it. `CoverState` reads those
    /// two from different places (`current_position` versus the entity's `state` string), so
    /// writing only the position leaves a shade dragged half-open rendering as closed everywhere
    /// except the bar the user just moved, roll-up counts included. See `CoverOptimistic.position`.
    func setCoverPosition(_ id: String, percent: Int) {
        guard let current = states[id] else { return }
        command(id, .whole(CoverOptimistic.position(current, percent: percent))) { c in
            try await c.setCoverPosition(id, percent: percent)
        }
    }
}

// MARK: - Climate

extension HomeStore {
    func setClimateMode(_ id: String, mode: String) {
        command(id, .nothing) { try await $0.setClimateMode(id, mode: mode) }
    }

    func setClimateTemp(_ id: String, temp: Double) {
        command(id, .nothing) { try await $0.setClimateTemp(id, temp: temp) }
    }

    func setFanMode(_ id: String, mode: String) {
        command(id, .nothing) { try await $0.setFanMode(id, mode: mode) }
    }
}

// MARK: - Media player

extension HomeStore {
    /// Play ⇄ pause. Which service is sent follows from the state we just wrote optimistically, so
    /// the two can never disagree about which direction the tap was going.
    func mediaPlayPause(_ id: String) {
        guard let current = states[id] else { return }
        let wasPlaying = MediaPlayerState(current).isPlaying
        command(id, .whole(MediaPlayerOptimistic.playPause(current, now: Date()))) { c in
            try await wasPlaying ? c.mediaPause(id) : c.mediaPlay(id)
        }
    }

    /// No optimistic state: what the next track *is* is unknowable until the device says so, and
    /// blanking the title in the meantime would flash an empty now-playing card between two songs.
    func mediaNextTrack(_ id: String) {
        command(id, .nothing) { try await $0.mediaNextTrack(id) }
    }

    func mediaPreviousTrack(_ id: String) {
        command(id, .nothing) { try await $0.mediaPreviousTrack(id) }
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
        let next = MediaPlayerOptimistic.volume(current, percent: percent, unmuting: unmuting)
        command(id, .whole(next)) { c in
            if unmuting { try await c.setMediaMuted(id, muted: false) }
            try await c.setMediaVolume(id, percent: percent)
        }
    }

    func setMediaMuted(_ id: String, muted: Bool) {
        guard let current = states[id] else { return }
        command(id, .whole(MediaPlayerOptimistic.mute(current, muted: muted))) { c in
            try await c.setMediaMuted(id, muted: muted)
        }
    }

    func selectMediaSource(_ id: String, source: String) {
        guard let current = states[id] else { return }
        command(id, .whole(MediaPlayerOptimistic.source(current, source))) { c in
            try await c.selectMediaSource(id, source: source)
        }
    }

    /// Power, never play/pause — the modal only offers this where `supported_features` declares
    /// both halves.
    func setMediaPower(_ id: String, on: Bool) {
        guard let current = states[id] else { return }
        command(id, .whole(MediaPlayerOptimistic.power(current, on: on))) { c in
            try await c.setMediaPower(id, on: on)
        }
    }
}

// MARK: - Scenes, scripts and buttons

extension HomeStore {
    /// Fire-and-forget scene/script/button activation. No optimistic local state to update: a
    /// scene has no on/off of its own to predict, and a script's "running" is Home Assistant's to
    /// report.
    func run(_ id: String) {
        command(id, .nothing) { try await $0.activate(sceneOrScript: id) }
    }
}
