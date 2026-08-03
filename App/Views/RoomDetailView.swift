import SwiftUI
import HavenCore

/// Full room view: one room, grouped by device domain, each group a plain heading
/// (no card/border — an earlier design round explicitly rejected wrapping groups in
/// chrome) followed by a 4-column tile grid. Lights/Covers groups additionally carry a
/// muted count and a right-aligned bulk action, hidden when there's nothing to act on.
struct RoomDetailView: View {
    let room: RoomSection
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    @State private var showingEnvironmentHistory = false
    /// Only the `+` still uses a `LazyVGrid`: it is a single 1×1 cell with no span to honour.
    ///
    /// The groups themselves moved to `RoomGrid`. The Climate group used to need a second, 2-column
    /// `[GridItem]` to get a half-width tile — `.gridCellColumns(2)` being inert inside a
    /// `LazyVGrid` — and that workaround is what a real span-aware layout removes.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 9), count: 4)

    /// Domain buckets for this room's `.entity` refs, in display order. `Domain.of(_:)`
    /// is switched exhaustively (every `Domain` case appears in exactly one branch), so
    /// every entity lands in exactly one bucket below — none dropped, none duplicated.
    /// `.composite` refs are skipped: nothing renders them yet (see `DeviceRef`'s doc
    /// comment / `HomeStore.deviceEntityIds`, which does the same).
    private struct Grouped {
        var climate: [String] = []
        var lights: [String] = []
        var covers: [String] = []
        var media: [String] = []
        var cameras: [String] = []
        var other: [String] = []
        var sensors: [String] = []
    }
    private var grouped: Grouped {
        var g = Grouped()
        // `refs(for: .roomDetail)` — the overview's controls *plus* the sensors curation demoted
        // off the grid, which is what makes this view the place demoted entities are reachable. A
        // device removed from the *dashboard* is still here; removal is per surface.
        for ref in room.refs(for: .roomDetail) {
            guard case .entity(let id) = ref else { continue }
            switch Domain.of(id) {
            case .climate: g.climate.append(id)
            case .light: g.lights.append(id)
            case .cover: g.covers.append(id)
            case .mediaPlayer: g.media.append(id)
            // Its own bucket, not `.other`: `.other` renders in the 4-column grid, and a camera
            // has no 1-column size — see `cameraGroup`.
            case .camera: g.cameras.append(id)
            case .scene, .script, .button, .lock, .switchOutlet, .unknown: g.other.append(id)
            case .sensor, .binarySensor: g.sensors.append(id)
            }
        }
        return g
    }

    var body: some View {
        let g = grouped
        let rollups = store.rollups(room)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                group("Climate", g.climate)
                group("Lights", g.lights, rollup: rollups.first { $0.kind == .lights })
                group("Shades", g.covers, rollup: rollups.first { $0.kind == .covers })
                group("Media", g.media)
                group("Cameras", g.cameras)
                group("Scenes & more", g.other)
                group("Sensors", g.sensors)
                // One `+` for the whole screen rather than one per group: the groups here are a
                // presentation of one list, and the picker is not scoped to a domain — an added
                // device lands in whichever group its domain belongs to.
                if navigation.isConfiguring {
                    LazyVGrid(columns: columns, spacing: 9) {
                        AddTilePlaceholder {
                            navigation.presented = .addTile(areaId: room.areaId, surface: .roomDetail)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // **Configuration is reachable from a room, not only from the dashboard.** It was
            // reachable only from the dashboard's menu, which made a room you had opened a screen
            // you could look at and not arrange — and left the devices that live *only* here, the
            // demoted sensors curation keeps off the overview, with no way to be configured at all.
            //
            // Two items with distinct ids rather than an `if` inside one, for the reason
            // `DashboardView`'s toolbar records: one item holding both states gives them one
            // identity, and SwiftUI does not reliably swap the control when the condition flips.
            if navigation.isConfiguring {
                ToolbarItem(id: "room-configuration-done", placement: .topBarTrailing) {
                    Button("Done") { navigation.isConfiguring = false }
                        .fontWeight(.semibold)
                }
            } else if store.config.canConfigure {
                // Shown only to a confirmed admin with a document Haven can read and write — see
                // `HavenConfig.canConfigure`. Omitted rather than disabled, this app's standing rule
                // for a control that cannot act.
                ToolbarItem(id: "room-configuration-enter", placement: .topBarTrailing) {
                    Button {
                        navigation.isConfiguring = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Edit room")
                }
            }
            ToolbarItem(id: "room-environment", placement: .topBarTrailing) {
                RoomEnvironmentChips(sensors: room.headerSensors) {
                    showingEnvironmentHistory = true
                }
            }
        }
        .sheet(isPresented: $showingEnvironmentHistory) {
            RoomEnvironmentHistoryView(roomName: room.name, sensors: room.headerSensors)
        }
    }

    /// One group: a heading, an optional roll-up count and action, then the group's tiles.
    ///
    /// **One builder for every group, where there used to be three.** Media and cameras each had
    /// their own, for one reason: a full-bleed 4×2 tile could not be expressed in a `LazyVGrid`
    /// whose cells are all one column, so those two groups were hand-built stacks and climate got a
    /// second `[GridItem]` to fake a half-width span. `RoomGrid` places by span, so all three
    /// special cases became the same code — and, more to the point, a tile's size in room detail is
    /// now `TileSpan.default(for:on:)` rather than three separate hand-agreements with it.
    ///
    /// Renders nothing when `ids` is empty so an unused domain never leaves a gap.
    @ViewBuilder
    private func group(_ title: String, _ ids: [String], rollup: Rollup? = nil) -> some View {
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.system(size: 14, weight: .bold))
                    if let rollup {
                        Text(rollup.kind == .lights ? "\(rollup.activeCount) of \(rollup.total) on" : "\(rollup.activeCount) open")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if rollup.activeCount > 0 {
                            Button(rollup.kind == .lights ? "All off" : "Close all") {
                                if rollup.kind == .lights { store.allOff(rollup, in: room.areaId) }
                                else { store.closeAll(rollup, in: room.areaId) }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(HavenColor.domain(rollup.kind == .lights ? .light : .cover))
                            // Mirrors `RoomSectionView.rollupRow`: named rather than silent, and
                            // gated on `activeCount > 0` (this block) the same way that view gates
                            // on `hasActive` — the only way the count ever clears without another
                            // bulk action is the button disappearing once there's nothing left to
                            // act on. Without this, a user who taps "All off" here saw exactly the
                            // silent half-failure this task exists to end: the count is tracked and
                            // shown in the room-list row, but this detail view never read it at all.
                            let failures = store.bulkFailureCount(for: rollup.kind, in: room.areaId)
                            if failures > 0 {
                                Text("\(failures) didn't respond")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(HavenColor.warning)
                            }
                        }
                    } else {
                        Spacer()
                    }
                }
                RoomGrid(columns: 4, spacing: 9) {
                    ForEach(ids, id: \.self) { id in
                        let span = store.span(of: id, on: .roomDetail)
                        DeviceTileView(entityId: id, surface: .roomDetail, span: span)
                            .tileSpan(span)
                    }
                }
            }
        }
    }
}
