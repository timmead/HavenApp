import SwiftUI
import HavenCore

/// Full room view: one room, grouped by device domain, each group a plain heading
/// (no card/border — an earlier design round explicitly rejected wrapping groups in
/// chrome) followed by a 4-column tile grid. Lights/Covers groups additionally carry a
/// muted count and a right-aligned bulk action, hidden when there's nothing to act on.
struct RoomDetailView: View {
    let room: RoomSection
    @Environment(HomeStore.self) private var store
    @State private var showingEnvironmentHistory = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 9), count: 4)
    // The Climate group renders in its own 2-column grid — a half-width tile is exactly a
    // 2-of-4 span, matching the approved mockups. (`.gridCellColumns(2)` is inert inside a
    // `LazyVGrid`; a real 2-column `[GridItem]` is the only way to get an actual span.)
    private let climateColumns = Array(repeating: GridItem(.flexible(), spacing: 9), count: 2)

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
        // `detailRefs` — the overview's controls *plus* the sensors curation demoted off the
        // grid, which is what makes this view the place demoted entities are reachable.
        for ref in room.detailRefs {
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
                group("Climate", g.climate, columns: climateColumns)
                group("Lights", g.lights, rollup: rollups.first { $0.kind == .lights })
                group("Shades", g.covers, rollup: rollups.first { $0.kind == .covers })
                mediaGroup(g.media)
                cameraGroup(g.cameras)
                group("Scenes & more", g.other)
                group("Sensors", g.sensors)
            }
            .padding()
        }
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                RoomEnvironmentChips(sensors: room.headerSensors) {
                    showingEnvironmentHistory = true
                }
            }
        }
        .sheet(isPresented: $showingEnvironmentHistory) {
            RoomEnvironmentHistoryView(roomName: room.name, sensors: room.headerSensors)
        }
    }

    /// The Media group, at full width (4-of-4 columns) — the size the approved design gives the
    /// artwork-and-transport tile. Its own `VStack`, not `group(_:_:columns:)`: a full-bleed 4×2
    /// tile is not a `DeviceTileView` in a narrower grid, it is a different tile rendering, and the
    /// dispatcher deliberately only knows the 1×1 (see `DeviceTileView`).
    @ViewBuilder
    private func mediaGroup(_ ids: [String]) -> some View {
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Media").font(.system(size: 14, weight: .bold)); Spacer() }
                VStack(spacing: 9) {
                    ForEach(ids, id: \.self) { id in
                        MediaPlayerTile(entityId: id, size: .large).configurable(entityId: id)
                    }
                }
            }
        }
    }

    /// The Cameras group, at full width (4-of-4 columns) — the full-bleed 4×2 rendering, which is
    /// the one the design gives the most space to and the only one that drops the staleness stamp,
    /// because at this width you can see the scene rather than having to be told about it.
    ///
    /// Its own `VStack` for the same structural reason as `mediaGroup`: this is a different tile
    /// rendering, not a `DeviceTileView` in a narrower grid.
    @ViewBuilder
    private func cameraGroup(_ ids: [String]) -> some View {
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Cameras").font(.system(size: 14, weight: .bold)); Spacer() }
                VStack(spacing: 9) {
                    ForEach(ids, id: \.self) { id in
                        CameraTile(entityId: id, size: .wide).configurable(entityId: id)
                    }
                }
            }
        }
    }

    /// One group: heading (+ optional roll-up count/action) then a grid of tiles (4 columns
    /// by default; pass `columns:` to override, e.g. Climate's 2-column half-width span).
    /// Renders nothing when `ids` is empty so an unused domain never leaves a gap.
    @ViewBuilder
    private func group(_ title: String, _ ids: [String], rollup: Rollup? = nil, columns: [GridItem]? = nil) -> some View {
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
                LazyVGrid(columns: columns ?? self.columns, spacing: 9) {
                    ForEach(ids, id: \.self) { id in
                        DeviceTileView(entityId: id)
                    }
                }
            }
        }
    }
}
