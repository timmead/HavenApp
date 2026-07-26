import SwiftUI
import HavenCore

/// Full room view: one room, grouped by device domain, each group a plain heading
/// (no card/border — an earlier design round explicitly rejected wrapping groups in
/// chrome) followed by a 4-column tile grid. Lights/Covers groups additionally carry a
/// muted count and a right-aligned bulk action, hidden when there's nothing to act on.
struct RoomDetailView: View {
    let room: RoomSection
    @Environment(HomeStore.self) private var store
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
                group("Scenes & more", g.other)
                group("Sensors", g.sensors)
            }
            .padding()
        }
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 7) {
                    ForEach(room.headerSensors, id: \.entityId) { hs in
                        let v = store.state(hs.entityId)?.state ?? "—"
                        let unit = hs.role == .temperature ? "°" : "%"
                        HavenChip(
                            systemImage: hs.role == .temperature ? "thermometer.medium" : "humidity.fill",
                            text: v + unit,
                            accent: hs.role == .temperature ? HavenColor.domain(.climate) : HavenColor.domain(.cover)
                        )
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
                                if rollup.kind == .lights { store.allOff(rollup) } else { store.closeAll(rollup) }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(HavenColor.domain(rollup.kind == .lights ? .light : .cover))
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
