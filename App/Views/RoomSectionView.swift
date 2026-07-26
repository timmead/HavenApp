import SwiftUI
import HavenCore

struct RoomSectionView: View {
    let room: RoomSection
    @Environment(HomeStore.self) private var store
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 9), count: 4)
    // Climate tiles render in their own 2-column grid (see body) — a genuine `Grid`/`GridRow`
    // span, not `.gridCellColumns(2)`, which is inert inside a `LazyVGrid`.
    private let climateColumns = Array(repeating: GridItem(.flexible(), spacing: 9), count: 2)

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Only the heading (name + env chips) is wrapped for navigation — NOT the
            // roll-up buttons or the tile grid below, which rely on bare .onTapGesture /
            // .onLongPressGesture (see LightTile etc.) that would otherwise contend with
            // (and likely lose to) an enclosing NavigationLink's own tap recognizer.
            NavigationLink(value: room.id) {
                HStack {
                    Text(room.name).font(.system(size: 17, weight: .bold))
                    Spacer()
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            let rollups = store.rollups(room)
            if !rollups.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(rollups.enumerated()), id: \.offset) { _, rollup in
                        rollupRow(rollup)
                    }
                    Spacer(minLength: 0)
                }
            }

            // Climate sits prominently at the top of the room, at half width (2-of-4 columns),
            // matching the approved mockups. Hoisted into its own grid because `.gridCellColumns`
            // is inert inside `LazyVGrid` — a real 2-column `[GridItem]` is the only way to get
            // an actual 2-column span here.
            // `overviewRefs`, not `deviceRefs`: the grid shows curated primary controls only —
            // demoted sensors and device telemetry live in room detail (see `CurationTier`).
            let climateIds = room.overviewRefs.compactMap { ref -> String? in
                guard case .entity(let id) = ref, Domain.of(id) == .climate else { return nil }
                return id
            }
            if !climateIds.isEmpty {
                LazyVGrid(columns: climateColumns, spacing: 9) {
                    ForEach(climateIds, id: \.self) { id in DeviceTileView(entityId: id) }
                }
            }

            let otherRefs = room.overviewRefs.filter { ref in
                guard case .entity(let id) = ref else { return true }
                return Domain.of(id) != .climate
            }
            if !otherRefs.isEmpty {
                LazyVGrid(columns: columns, spacing: 9) {
                    ForEach(otherRefs) { ref in
                        if case .entity(let id) = ref {
                            DeviceTileView(entityId: id)
                        }
                    }
                }
            }
        }
    }

    /// A single room-level bulk action, e.g. "3/5 lights on · All Off" or
    /// "2/2 covers open · Close All". Kept private to this view since a roll-up
    /// line only ever appears attached to its room's heading.
    @ViewBuilder
    private func rollupRow(_ rollup: Rollup) -> some View {
        let accent = HavenColor.domain(rollup.kind == .lights ? .light : .cover)
        let hasActive = rollup.activeCount > 0
        HStack(spacing: 6) {
            Image(systemName: rollup.kind == .lights ? "lightbulb.fill" : "blinds.vertical.closed")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(hasActive ? accent : .secondary)
            Text("\(rollup.activeCount)/\(rollup.total)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Button(rollup.kind == .lights ? "All Off" : "Close All") {
                if rollup.kind == .lights { store.allOff(rollup) } else { store.closeAll(rollup) }
            }
            .font(.system(size: 12, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(hasActive ? accent : .secondary)
            .disabled(!hasActive)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(HavenColor.glassFill))
    }
}
