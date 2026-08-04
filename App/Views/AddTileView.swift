import SwiftUI
import HavenCore

/// What this surface could show and isn't.
///
/// **The first version was a flat alphabetical list, and it did not survive a real home.** One UniFi
/// camera contributes eight `binary_sensor.*_detected` entities; two cameras put eighteen rows in
/// front of anything a person would want, interleaved alphabetically with everything else. Three
/// changes, in the order they do the work:
///
/// 1. **Grouped by device.** Eight detection sensors become one collapsed row saying "36th Street
///    Camera · 8". This attacks the cause rather than making a long list nicer to scan.
/// 2. **Searchable**, matching name and entity id — the reliable escape hatch at any length.
/// 3. **Filterable by kind**, behind a link that expands a section in place rather than seven chips
///    permanently above the list — the problem was too much on screen, and a filter that is only
///    there when asked for costs nothing when it is not.
///
/// **No checkmarks on the rows**, unlike the room's sensor picker: nothing here is selected — that
/// is what makes it addable — so a checkmark column would promise a state that cannot occur.
struct AddTileView: View {
    let areaId: String
    let surface: HavenSurface
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Kinds the user has unticked. Empty — everything shown — every time the sheet opens; see
    /// `TileKindFilter` for why this is not persisted.
    @State private var excluded: Set<TileCategory> = []
    /// Whether the kinds section is expanded. It was a *sheet*, which made this one dismiss and
    /// re-present around it — see `TileKindFilter`.
    @State private var isFilteringByKind: Bool
    /// Which device groups are open. Collapsed by default, which is the entire point of grouping.
    @State private var expanded: Set<String> = []
    @State private var failure: String?
    /// The entity awaiting a type, or nil. **A second step, not a second sheet**: a sheet-in-sheet
    /// dismisses and re-presents its parent, which this file's kind filter already records as
    /// disruptive enough to have been redesigned away.
    @State private var choosingTypeFor: String?

    /// `filteringByKindForPreview` exists so a preview can render the expanded state, which is
    /// otherwise only reachable by tapping — and an unrendered state is one nobody has looked at.
    init(areaId: String, surface: HavenSurface, filteringByKindForPreview: Bool = false,
         choosingTypeForPreview: String? = nil) {
        self.areaId = areaId
        self.surface = surface
        _isFilteringByKind = State(initialValue: filteringByKindForPreview)
        _choosingTypeFor = State(initialValue: choosingTypeForPreview)
    }

    var body: some View {
        let room = store.rooms().first { $0.areaId == areaId }
        let candidates = room.map { store.addableEntityIds(in: $0, on: surface) } ?? []
        let groups = AddTileGrouping.groups(candidates: candidates, query: query,
                                            excluded: excluded, store: store)
        VStack(alignment: .leading, spacing: 12) {
            ModalHeader(systemImage: "plus.circle",
                        title: "Add to \(room?.name ?? "room")",
                        subtitle: subtitle,
                        accent: HavenColor.domain(.cover), unavailable: false,
                        accessory: AnyView(ModalDoneButton { dismiss() }))
            if let entityId = choosingTypeFor {
                typeChooser(entityId)
            } else {
            searchAndFilter(candidates: candidates)
            if isFilteringByKind {
                TileKindFilter(available: AddTileGrouping.categories(of: candidates),
                               excluded: $excluded)
            }
            if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(HavenColor.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            FacetCard {
                if candidates.isEmpty {
                    // Not an error: a room can genuinely be showing everything it has.
                    Text("Everything in this room is already here.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if groups.isEmpty {
                    // Distinct from the above on purpose: there *are* things to add, and the search
                    // or the filter is why none are visible. Saying "nothing to add" here would be a
                    // lie the user could not act on.
                    Text("Nothing matches. Try a different search, or check the filter.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(groups) { group in
                            groupRows(group)
                        }
                    }
                }
            }
            }
        }
    }

    // MARK: - Search and filter

    @ViewBuilder
    private func searchAndFilter(candidates: [String]) -> some View {
        // Both are hidden below a handful of candidates: a search field over four rows is furniture,
        // and this sheet's whole problem was too much of that.
        if candidates.count > 5 {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("Search", text: $query)
                        .font(.system(size: 14))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Capsule().fill(HavenColor.glassFill))

                Button { isFilteringByKind.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 13, weight: .semibold))
                        // The count is the only cue that a filter is on at all once the section is
                        // collapsed; without it an unticked kind is a device that silently vanished.
                        Text(excluded.isEmpty ? "Filter" : "Filter (\(excluded.count))")
                            .font(.system(size: 13, weight: .semibold))
                        // Says which way the tap goes, since tapping again is how it closes.
                        Image(systemName: isFilteringByKind ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(HavenColor.domain(.cover))
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func groupRows(_ group: AddTileGrouping.Group) -> some View {
        // A device contributing one entity is drawn as a plain row: a disclosure holding a single
        // child is a tap that reveals what it already said.
        if group.entityIds.count == 1, let entityId = group.entityIds.first {
            entityRow(entityId)
        } else {
            let isExpanded = expanded.contains(group.id)
            Button {
                if isExpanded { expanded.remove(group.id) } else { expanded.insert(group.id) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name).font(.system(size: 15, weight: .semibold))
                        Text("\(group.entityIds.count) things")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.name), \(group.entityIds.count) things")
            .accessibilityHint(isExpanded ? "Collapses" : "Expands")

            if isExpanded {
                ForEach(group.entityIds, id: \.self) { entityId in
                    entityRow(entityId).padding(.leading, 24)
                }
            }
        }
    }

    private func entityRow(_ entityId: String) -> some View {
        Button {
            // **Only ask when there is a question.** A light has one way to be rendered, so offering
            // a chooser with a single row would be a step that teaches nothing. A cover has three.
            let types = DeviceTypes.candidates(for: entityId)
            if types.count > 1 {
                choosingTypeFor = entityId
            } else {
                Task { await add(entityId) }
            }
        } label: {
            EntityPickerRow(title: store.displayName(of: entityId),
                            entityId: entityId,
                            isSelected: false)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 7)
    }

    private var subtitle: String {
        switch surface {
        case .overview: return "In this room, but not on the dashboard"
        case .roomDetail: return "In this room, but not shown here"
        }
    }

    private func add(_ entityId: String) async {
        switch await store.setMembership(entityId, on: surface, to: .shown) {
        case .written, .unchanged: dismiss()
        case .notAuthorized: failure = "Only Home Assistant admins can change the household dashboard."
        case .failed: failure = "Couldn't save that. Check your connection and try again."
        }
    }

    /// The second step: what kind of device this entity should be.
    ///
    /// Replaces the list in place rather than pushing or presenting, for the reason the kind filter
    /// records — a sheet over this sheet dismisses and re-presents the one underneath, which reads
    /// as the app losing its place.
    @ViewBuilder
    private func typeChooser(_ entityId: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How should “\(store.displayName(of: entityId))” be shown?")
                .font(.system(size: 15, weight: .semibold))
            ForEach(DeviceTypes.candidates(for: entityId)) { type in
                Button {
                    Task { await add(entityId, as: type) }
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(type.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(describe(type))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
            Button("Back") { choosingTypeFor = nil }
                .font(.system(size: 13, weight: .semibold))
        }
    }

    /// What choosing a type gets you, in one line — a name alone does not say why a "Garage door" is
    /// different from a "Shade".
    private func describe(_ type: DeviceType) -> String {
        let extra = type.roles.filter { $0.role != .primary }
        guard !extra.isEmpty else { return "On its own, as Home Assistant reports it." }
        switch type.id {
        case "garage_door":
            return "With sensors for fully open and fully closed, so it can say when it is part-way."
        case "shade_group":
            return "With other shades, controlled together as one tile."
        default:
            return "With " + extra.map { $0.role.label.lowercased() }.joined(separator: " and ") + "."
        }
    }

    /// Adding as a composite **creates a device**; adding as a one-entity type is the membership
    /// change it always was.
    private func add(_ entityId: String, as type: DeviceType) async {
        guard type.roles.count > 1 else {
            await add(entityId)
            return
        }
        guard let id = await store.createDevice(type: type, primary: entityId, areaId: areaId) else {
            failure = "Couldn't save that. Check your connection and try again."
            return
        }
        // Straight into its configuration: a shade group with no followers is a shade with a
        // different label, and the roles are the reason the type was chosen.
        navigation.presented = .tileConfig(entityId: id, surface: surface)
    }
}

/// Turning a room's addable entity ids into the picker's rows: filtered, searched, and gathered by
/// device.
///
/// Separate from the view because it is the part with rules in it — which device an entity belongs
/// to, what a search matches, how groups are ordered — and a view is a poor place to keep rules.
enum AddTileGrouping {
    struct Group: Identifiable {
        /// The device id, or the entity id for something with no device.
        let id: String
        let name: String
        let entityIds: [String]
    }

    /// The kinds present among `candidates`, in `TileCategory`'s own order, so the filter sheet
    /// offers only what this room could actually hide.
    @MainActor
    static func categories(of candidates: [String]) -> [TileCategory] {
        let present = Set(candidates.map { TileCategory(domain: Domain.of($0)) })
        return TileCategory.allCases.filter(present.contains)
    }

    /// Groups, ordered by name so the sheet does not reshuffle between openings.
    ///
    /// An entity with no device — or whose device Home Assistant did not name — becomes its own
    /// single-entity group, which the view draws as a plain row. That is deliberately not an "Other"
    /// bucket: a lone light does not become easier to find by being filed under a heading that
    /// tells you nothing.
    @MainActor
    static func groups(candidates: [String], query: String, excluded: Set<TileCategory>,
                       store: HomeStore) -> [Group] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = candidates.filter { entityId in
            guard !excluded.contains(TileCategory(domain: Domain.of(entityId))) else { return false }
            guard !trimmed.isEmpty else { return true }
            // Name *and* id: the id is what tells two identically-named sensors apart, so a search
            // that ignored it could not reach one of them.
            return store.displayName(of: entityId).lowercased().contains(trimmed)
                || entityId.lowercased().contains(trimmed)
        }

        var byDevice: [String: [String]] = [:]
        var loose: [String] = []
        for entityId in matching {
            if let deviceId = store.home.registryInfo[entityId]?.deviceId,
               store.home.deviceNames[deviceId] != nil {
                byDevice[deviceId, default: []].append(entityId)
            } else {
                loose.append(entityId)
            }
        }

        let deviceGroups = byDevice.map { deviceId, ids in
            Group(id: deviceId, name: store.home.deviceNames[deviceId] ?? deviceId,
                  entityIds: ids.sorted())
        }
        let looseGroups = loose.map {
            Group(id: $0, name: store.displayName(of: $0), entityIds: [$0])
        }
        return (deviceGroups + looseGroups).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

#if DEBUG
/// A room shaped like the one that broke the first version: two cameras with eight detection sensors
/// each, plus a couple of ordinary devices.
private struct AddTilePreviewHost: View {
    @State private var store = AddTilePreviewHost.populatedStore()
    let areaId: String
    /// Renders with the kinds section already open, which is otherwise only reachable by tapping.
    var filtering = false

    var body: some View {
        AddTileView(areaId: areaId, surface: .overview, filteringByKindForPreview: filtering)
            .padding(16).environment(store)
    }

    @MainActor
    private static func populatedStore() -> HomeStore {
        let store = HomeStore()
        var tiers: [String: CurationTier] = [:]
        var ids: [String] = []
        var info: [String: EntityRegistryInfo] = [:]

        func set(_ id: String, _ state: String, _ name: String, tier: CurationTier,
                 deviceId: String? = nil, deviceClass: String? = nil) {
            var attrs: [String: JSONValue] = ["friendly_name": .string(name)]
            if let deviceClass { attrs["device_class"] = .string(deviceClass) }
            store.states[id] = EntityState(entityId: id, state: state, attributes: attrs,
                                           lastUpdated: Date(timeIntervalSince1970: 0))
            tiers[id] = tier
            ids.append(id)
            info[id] = EntityRegistryInfo(platform: "unifiprotect", uniqueId: id, deviceId: deviceId)
        }

        for (deviceId, camera) in [("dev-36th", "36th Street Camera"), ("dev-dens", "Densmore Ave Camera")] {
            for kind in ["animal", "baby_cry", "person", "smoke_alarm", "speaking", "vehicle", "motion", "audio"] {
                set("binary_sensor.\(deviceId)_\(kind)_detected", "off",
                    "\(camera) \(kind.replacingOccurrences(of: "_", with: " ").capitalized) detected",
                    tier: .secondary, deviceId: deviceId, deviceClass: "motion")
            }
        }
        set("light.lounge_lamp", "off", "Lounge Lamp", tier: .secondary, deviceId: "dev-lamp")
        set("sensor.lounge_power", "412", "Lounge Power", tier: .secondary, deviceClass: "power")

        store.home = ResolvedHome(
            floors: [ResolvedFloor(id: "f", name: "Ground", level: 0,
                                   areas: [ResolvedArea(id: "lounge", name: "Lounge",
                                                        entityIds: ids, tiers: tiers)])],
            registryInfo: info,
            deviceNames: ["dev-36th": "36th Street Camera", "dev-dens": "Densmore Ave Camera",
                          "dev-lamp": "Lounge Lamp"])
        return store
    }
}

#Preview("Add tile — grouped by device") { AddTilePreviewHost(areaId: "lounge") }
#Preview("Add tile — kinds expanded") { AddTilePreviewHost(areaId: "lounge", filtering: true) }

/// Over content, which is the only way to see that the sheet's background is opaque.
#Preview("Add tile — over content") {
    ZStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 0) {
            Text("Driveway").font(.system(size: 17, weight: .bold))
            Rectangle().fill(.orange).frame(height: 200)
        }
        AddTilePreviewHost(areaId: "lounge").background(.background)
    }
}
#endif
