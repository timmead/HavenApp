import SwiftUI
import HavenCore

/// A device's configuration. Today: what it is called.
///
/// The name is **Haven's own**, never a rename of the Home Assistant entity — HA stays the source of
/// truth for structure and Haven layers on top. That has a consequence this sheet is obliged to make
/// visible: an override shadows HA permanently, so renaming the entity in Home Assistant afterwards
/// will not show up here. Hence the line naming what HA calls the device, and the reset beside it.
///
/// **Nothing here writes until the sheet closes.** Every control edits a draft and `commit()` is the
/// only write, which is what lets one sheet hold several settings without a Save button per section
/// — and what keeps a multi-setting edit to a single write, so the shared document's version moves
/// once rather than once per control.
///
/// Two asymmetries follow from that, both deliberate:
///
/// - **Done waits and can report a failure; a swipe cannot.** A dismissed sheet has nowhere to put an
///   error, so a swipe commits fire-and-forget. Discarding a typed name instead was the alternative,
///   and silent loss with no Cancel on screen to warn of it is the worse of the two.
/// - **Remove discards pending edits**, because the tile is leaving this surface and a name written
///   on its way out is work nobody asked for.
///
/// Sub-project 6 adds which entities feed a tile.
struct TileConfigView: View {
    let entityId: String
    /// Which surface this was opened from — what "remove" removes it from. See `HavenSurface`.
    let surface: HavenSurface
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// The field's live text. Seeded once from the current *override* — deliberately not bound
    /// straight through to the store, which would write on every keystroke.
    @State private var draft: String = ""
    @State private var failure: String?
    /// True once this sheet has written, so a dismissal cannot write a second time.
    @State private var committed = false
    /// The chosen size, seeded from what is stored or the surface's default. A draft like the name:
    /// nothing is written until the sheet closes.
    @State private var span: TileSpan = TileSpan(columns: 1, rows: 1)
    /// Whether this device's tile shows its state as a glyph or a word. A draft, like the rest.
    @State private var stateStyle: TileStateStyle = .icon
    /// Which companion plays which role. Drafts, like the rest — nothing writes until Done.
    @State private var bindings: [DeviceRole: String] = [:]

    private var storedOverride: String? { store.config.document.displayNames[entityId] }

    var body: some View {
        let e = store.state(entityId)
        let haName = e?.attributes["friendly_name"]?.asString
        VStack(alignment: .leading, spacing: 12) {
            ModalHeader(systemImage: IconMap.symbol(domain: Domain.of(entityId),
                                                    deviceClass: e?.deviceClass),
                        title: store.displayName(of: entityId),
                        subtitle: entityId,
                        accent: HavenColor.domain(Domain.of(entityId)), unavailable: false,
                        accessory: AnyView(ModalDoneButton {
                            Task { if await commit() { dismiss() } }
                        }))
            FacetCard(title: "Name") {
                VStack(alignment: .leading, spacing: 9) {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                        .onSubmit { Task { if await commit() { dismiss() } } }
                    // What Home Assistant calls it, so an override reads as an override rather than
                    // as a mystery — and so the user can see what a reset would give them back.
                    Text(haName.map { "Home Assistant calls this “\($0)”" }
                         ?? "Home Assistant has no name for this device")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if let failure {
                        Text(failure).font(.system(size: 12)).foregroundStyle(HavenColor.warning)
                    }
                    // **Reset clears the field rather than writing.** An empty draft *is* "no
                    // override" — see `DisplayName.override(from:)` — so reset and commit are one
                    // mechanism instead of two paths to the same outcome, and resetting can be
                    // reconsidered before Done like every other edit on this sheet.
                    if storedOverride != nil {
                        Button("Reset to Home Assistant's name") { draft = "" }
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
            }
            // Only where there is a choice — a domain with one rendering shows no card at all. See
            // `TileSpan.isResizable`.
            if TileSpan.isResizable(Domain.of(entityId)) {
                FacetCard(title: "Size") {
                    VStack(alignment: .leading, spacing: 9) {
                        TileSizePicker(options: TileSpan.available(for: Domain.of(entityId)),
                                       selection: $span)
                        // Named because the sheet is reachable from both surfaces and the choice is
                        // stored for the one it was opened from — a household that widens a tile on
                        // the dashboard has said nothing about the room.
                        Text(sizeScopeNote)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            // Only for the devices that *have* two states to show — a thermostat or a camera has
            // nothing this would mean. See `TileState.isTwoState`.
            if TileState.isTwoState(Domain.of(entityId)) {
                FacetCard(title: "Show state as") {
                    VStack(alignment: .leading, spacing: 9) {
                        Picker("Show state as", selection: $stateStyle) {
                            Text("Icon").tag(TileStateStyle.icon)
                            Text("Label").tag(TileStateStyle.label)
                        }
                        .pickerStyle(.segmented)
                        // Unlike the size, this is one answer for the device rather than one per
                        // surface: whether a word is easier to read than a picture is a fact about
                        // the reader, and asking it twice for the same door would be strange.
                        Text("On the dashboard and in the room.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            // Only for the domains with a role worth binding — see `DeviceRole.roles(for:)`. A
            // garage's two limit sensors describe a state the cover entity cannot: partly open.
            // **The type's roles, not the domain's.** A garage door has limit sensors because it is
            // a garage door, not because it is a cover — a plain shade is a cover too and has none.
            // Only a composite has roles to bind, because choosing a type is what created it.
            let roles = store.deviceType(of: entityId).roles.filter { $0.role != .primary }
            if !roles.isEmpty {
                FacetCard(title: "Sensors") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(roles, id: \.role) { typeRole in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(typeRole.role.label)
                                    .font(.system(size: 12, weight: .semibold))
                                Picker(typeRole.role.label, selection: Binding(
                                    get: { bindings[typeRole.role] ?? "" },
                                    set: { bindings[typeRole.role] = $0.isEmpty ? nil : $0 })) {
                                        Text("None").tag("")
                                        ForEach(candidates(for: typeRole), id: \.self) { id in
                                            Text(store.displayName(of: id)).tag(id)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                            }
                        }
                        Text(roleHint)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            FacetCard {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task { await remove() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                            Text(removeTitle).font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(HavenColor.destructive))
                    }
                    .buttonStyle(.plain)
                    // The button says what it does; this says what it does *not*. Red is right —
                    // this is the destructive action on this screen — but the sentence is what stops
                    // someone believing they have deleted a device out of their home.
                    Text("The device stays in Home Assistant. Add it back with the + in \(surfaceNoun).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        // Seeded from the *override*, not from the resolved name: pre-filling with Home Assistant's
        // name would turn every "let me look at this device" into a rename the moment the user hit
        // Save, and the household would fill up with overrides nobody chose.
        .onAppear {
            draft = storedOverride ?? ""
            span = store.span(of: entityId, on: surface)
            stateStyle = store.stateStyle(of: entityId)
            bindings = store.bindings(of: entityId)
        }
        // **Swiping the sheet away commits too**, because there is no Cancel here and discarding a
        // typed name without warning is worse than a write the user cannot watch. Fire-and-forget by
        // necessity: a sheet that has gone has nowhere to put an error. Done is the path that waits
        // and can tell you.
        .onDisappear {
            guard !committed, hasChanges else { return }
            let name = DisplayName.override(from: draft)
            let size = sizeEdit
            let style = stateStyleEdit
            let bound = bindingEdits
            let surface = surface
            committed = true
            Task {
                _ = await store.applyTileConfig(entityId, name: name, size: size,
                                                stateStyle: style, bindings: bound, on: surface)
            }
        }
    }

    /// **"Remove", never "Delete".** It takes a tile off one Haven surface; Haven deletes nothing in
    /// Home Assistant, and a button labelled delete would promise otherwise.
    private var removeTitle: String {
        switch surface {
        case .overview: return "Remove from dashboard"
        case .roomDetail: return "Remove from this room"
        }
    }

    private var surfaceNoun: String {
        switch surface {
        case .overview: return "this room on the dashboard"
        case .roomDetail: return "this room"
        }
    }

    /// What could fill a role: **everything in the room** the role's domains accept.
    ///
    /// **Not restricted to the primary's own Home Assistant device**, which is what the first
    /// version did and which made this unusable for the commonest garage: a relay opener and a pair
    /// of contact sensors are three separate devices in Home Assistant, so the pickers came back
    /// empty for exactly the household that needed them.
    ///
    /// That restriction was a heuristic — "a limit sensor is part of the opener" — applied to the
    /// one feature whose entire justification is *not* inferring these relationships. If Haven could
    /// work out which sensor was the closed limit, it would not be asking.
    ///
    /// Ordered by how likely each is to be the right answer: the primary's own device first, then
    /// its room, then the rest of the home. **The tail matters** — a household that has not assigned
    /// its contact sensors to an area in Home Assistant still has to be able to point at them, and
    /// a picker that is empty for that household is the bug this replaced.
    private func candidates(for typeRole: DeviceTypeRole) -> [String] {
        guard let primary = store.device(entityId).primaryEntityId else { return [] }
        let sameDevice = Set(store.bindableEntityIds(for: primary))
        let sameRoom = Set(store.roomEntityIds(containing: primary))
        func rank(_ id: String) -> Int {
            sameDevice.contains(id) ? 0 : (sameRoom.contains(id) ? 1 : 2)
        }
        return store.allEntityIds
            .filter { $0 != primary && typeRole.accepts($0) }
            .sorted { a, b in rank(a) == rank(b) ? a < b : rank(a) < rank(b) }
    }

    private var roleHint: String {
        let anyCandidates = store.deviceType(of: entityId).roles
            .filter { $0.role != .primary }
            .contains { !candidates(for: $0).isEmpty }
        return anyCandidates
            ? "Nearest first: this device, then this room, then the rest of the home."
            : "Nothing in this home can fill these roles."
    }

    /// Roles whose binding differs from what is stored. `nil` for a role clears it.
    private var bindingEdits: [DeviceRole: String?]? {
        let stored = store.bindings(of: entityId)
        var out: [DeviceRole: String?] = [:]
        for typeRole in store.deviceType(of: entityId).roles where typeRole.role != .primary {
            let now = bindings[typeRole.role]
            if now != stored[typeRole.role] { out[typeRole.role] = now }
        }
        return out.isEmpty ? nil : out
    }

    private var sizeScopeNote: String {
        switch surface {
        case .overview: return "On the dashboard. This device's size in the room is separate."
        case .roomDetail: return "In this room. This device's size on the dashboard is separate."
        }
    }

    /// Whether the size differs from what is stored — or, when nothing is stored, from the default.
    ///
    /// `.some(nil)` clears a stored choice back to the default rather than storing the default as
    /// though it were chosen: a household that widens a tile and puts it back has made no decision,
    /// and the document should not carry one.
    private var sizeEdit: TileSpan?? {
        guard TileSpan.isResizable(Domain.of(entityId)) else { return nil }
        let stored = store.config.document.tileSizes[entityId]?[surface]
        guard span != stored else { return nil }
        return span == TileSpan.default(for: Domain.of(entityId), on: surface)
            ? .some(nil)
            : .some(span)
    }

    /// No confirmation dialog, deliberately: one tap on the same screen's + puts it back, and a
    /// confirmation on a reversible action is how people learn to dismiss confirmations unread.
    private func remove() async {
        switch await store.setMembership(entityId, on: surface, to: .hidden) {
        // Removing discards whatever was typed: the tile is leaving this surface, and writing a name
        // for it on the way out is work nobody asked for.
        case .written, .unchanged: committed = true; dismiss()
        case .notAuthorized: failure = "Only Home Assistant admins can change the household dashboard."
        case .failed: failure = "Couldn't save that. Check your connection and try again."
        }
    }

    /// Whether committing would change anything. Compared against the stored override rather than
    /// against the resolved name, and trimmed, so re-typing the same name with a stray space is not
    /// an edit — and so a sheet merely opened and closed writes nothing at all.
    /// Whether the state style differs from what is stored — `.some(nil)` to clear a stored choice
    /// back to the default rather than storing the default as though it had been chosen.
    private var stateStyleEdit: TileStateStyle?? {
        guard TileState.isTwoState(Domain.of(entityId)) else { return nil }
        let stored = store.config.document.tileStateStyles[entityId]
        guard stateStyle != stored else { return nil }
        return stateStyle == .icon ? .some(nil) : .some(stateStyle)
    }

    private var hasChanges: Bool {
        DisplayName.override(from: draft) != storedOverride
            || sizeEdit != nil || stateStyleEdit != nil || bindingEdits != nil
    }

    /// The one write this sheet performs. Returns whether the sheet may close.
    ///
    /// **Exactly once per sheet, whichever way it closes.** Done and a swipe both end in
    /// `onDisappear`, so without `committed` a tap on Done would write, dismiss, and write again.
    ///
    /// Plan 4 widens this to carry the chosen size. It is a single function for that reason: the
    /// sheet gains a control, not a second write path.
    private func commit() async -> Bool {
        guard !committed else { return true }
        guard hasChanges else { committed = true; return true }
        committed = true
        switch await store.applyTileConfig(entityId, name: DisplayName.override(from: draft),
                                           size: sizeEdit, stateStyle: stateStyleEdit,
                                           bindings: bindingEdits, on: surface) {
        case .written, .unchanged:
            return true
        case .notAuthorized:
            failure = "Only Home Assistant admins can change the household dashboard."
        case .failed:
            failure = "Couldn't save that. Check your connection and try again."
        }
        // A failed write leaves the sheet open holding the edit, so the next Done can try again —
        // and leaves `committed` false so that it actually does.
        committed = false
        return false
    }
}

#if DEBUG
private struct TileConfigPreviewHost: View {
    let entityId: String
    var surface: HavenSurface = .overview
    @State private var store: HomeStore

    init(entityId: String, overridden: Bool, surface: HavenSurface = .overview) {
        self.entityId = entityId
        self.surface = surface
        _store = State(initialValue: TileConfigPreviewHost.populatedStore(overridden: overridden))
    }

    var body: some View {
        TileConfigView(entityId: entityId, surface: surface).padding(16).environment(store)
    }

    @MainActor
    private static func populatedStore(overridden: Bool) -> HomeStore {
        let store = HomeStore()
        store.states["light.kitchen"] = EntityState(
            entityId: "light.kitchen", state: "on",
            attributes: ["friendly_name": .string("Kitchen Light")],
            lastUpdated: Date(timeIntervalSince1970: 0))
        // A relay opener and two contact sensors on **three different Home Assistant devices** —
        // the shape that made the role pickers come back empty.
        store.states["switch.opener"] = EntityState(
            entityId: "switch.opener", state: "off",
            attributes: ["friendly_name": .string("Garage Opener")],
            lastUpdated: Date(timeIntervalSince1970: 0))
        for (id, name) in [("binary_sensor.g_closed", "Garage Closed"),
                           ("binary_sensor.g_open", "Garage Open")] {
            store.states[id] = EntityState(
                entityId: id, state: "off",
                attributes: ["friendly_name": .string(name), "device_class": .string("door")],
                lastUpdated: Date(timeIntervalSince1970: 0))
        }
        store.home = ResolvedHome(
            floors: [ResolvedFloor(id: "f", name: "Ground", level: 0, areas: [
                ResolvedArea(id: "garage", name: "Garage",
                             entityIds: ["switch.opener", "binary_sensor.g_closed",
                                         "binary_sensor.g_open"],
                             tiers: ["switch.opener": .primary,
                                     "binary_sensor.g_closed": .secondary,
                                     "binary_sensor.g_open": .secondary])])],
            registryInfo: ["switch.opener": EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: "relay"),
                           "binary_sensor.g_closed": EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: "contact-a"),
                           "binary_sensor.g_open": EntityRegistryInfo(platform: nil, uniqueId: nil, deviceId: "contact-b")])
        store.config.seedForTesting(store.config.document.settingDevice(
            DashboardDocument.StoredDevice(id: "switch.opener", type: "garage_door",
                                           areaId: "garage",
                                           inputs: [.primary: ["switch.opener"]]),
            id: "switch.opener"))
        store.states["sensor.hall_temp"] = EntityState(
            entityId: "sensor.hall_temp", state: "21.4",
            attributes: ["friendly_name": .string("Hall Temperature"),
                         "device_class": .string("temperature"),
                         "unit_of_measurement": .string("°C")],
            lastUpdated: Date(timeIntervalSince1970: 0))
        if overridden {
            store.config.seedForTesting(
                DashboardDocument().settingDisplayName("Reading Lamp", for: "light.kitchen"))
        }
        return store
    }
}

/// The field is pre-filled only in the renamed case — a device you have merely opened must not
/// arrive holding Home Assistant's name, or Save silently converts it into an override.
#Preview("Tile config — renamed") { TileConfigPreviewHost(entityId: "light.kitchen", overridden: true) }
#Preview("Tile config — not renamed") { TileConfigPreviewHost(entityId: "light.kitchen", overridden: false) }
/// **A device that can be more than one size**, which a light cannot — so the size card is absent
/// from every preview above and its presence here is the only thing that shows it exists at all.
#Preview("Tile config — resizable") {
    TileConfigPreviewHost(entityId: "sensor.hall_temp", overridden: false)
}

/// **A garage door whose limit sensors are on other Home Assistant devices**, which is the shape
/// that made these pickers come back empty — the restriction to the primary's own device was a
/// heuristic applied to the one feature that exists because heuristics do not work here.
#Preview("Tile config — garage door roles") {
    TileConfigPreviewHost(entityId: "switch.opener", overridden: false)
}

/// The other surface, where both the button and its explanation change wording.
#Preview("Tile config — room detail") {
    TileConfigPreviewHost(entityId: "light.kitchen", overridden: false, surface: .roomDetail)
}
#endif
