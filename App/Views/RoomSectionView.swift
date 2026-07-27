import SwiftUI
import HavenCore

struct RoomSectionView: View {
    let room: RoomSection
    @Environment(HomeStore.self) private var store
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 9), count: 4)
    // Climate tiles render in their own 2-column grid (see body) — a genuine `Grid`/`GridRow`
    // span, not `.gridCellColumns(2)`, which is inert inside a `LazyVGrid`.
    private let climateColumns = Array(repeating: GridItem(.flexible(), spacing: 9), count: 2)
    // Same story for the 2×1 media tile — a real 2-column grid, not a span modifier.
    private let mediaColumns = Array(repeating: GridItem(.flexible(), spacing: 9), count: 2)
    // And for the 2×2 camera tile. Cameras have *no* 1-column rendering at all (below two columns
    // a feed is a thumbnail of a thumbnail), so unlike media this is not a nicety — a camera that
    // slipped into the 4-column grid below would render at a size the design explicitly rejected.
    private let cameraColumns = Array(repeating: GridItem(.flexible(), spacing: 9), count: 2)

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Only the heading (name + env chips) is wrapped for navigation — NOT the
            // roll-up buttons or the tile grid below, which rely on bare .onTapGesture /
            // .onLongPressGesture (see LightTile etc.) that would otherwise contend with
            // (and likely lose to) an enclosing NavigationLink's own tap recognizer.
            NavigationLink(value: room.id) {
                HStack {
                    // The name yields before the readings do: it truncates, they don't (see
                    // `RoomEnvironmentChips`). A long room name is still recognisable clipped; a
                    // temperature is not.
                    Text(room.name).font(.system(size: 17, weight: .bold)).lineLimit(1)
                    Spacer(minLength: 8)
                    RoomEnvironmentChips(sensors: room.headerSensors, spacing: 8)
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

            // Everything that is not hoisted into a grid of its own. Cameras are excluded here for
            // a stronger reason than climate and media are: those two have a legitimate 1×1, so a
            // missed filter would only cost them their preferred size. A camera has none, and
            // leaking into this 4-column grid would render it at exactly the size the design
            // rejected.
            let otherRefs = room.overviewRefs.filter { ref in
                guard case .entity(let id) = ref else { return true }
                let domain = Domain.of(id)
                return domain != .climate && domain != .mediaPlayer && domain != .camera
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

            // Media players sit *below* the main grid, at half width (2-of-4 columns), for the same
            // structural reason Climate sits above it in its own grid: `.gridCellColumns` is inert
            // inside a `LazyVGrid`, so a 2-wide tile needs a real 2-column `[GridItem]`. Below
            // rather than above because the lights and switches are what a room glance is usually
            // for; what's playing is worth space, not precedence.
            let mediaIds = room.overviewRefs.compactMap { ref -> String? in
                guard case .entity(let id) = ref, Domain.of(id) == .mediaPlayer else { return nil }
                return id
            }
            if !mediaIds.isEmpty {
                LazyVGrid(columns: mediaColumns, spacing: 9) {
                    ForEach(mediaIds, id: \.self) { id in
                        MediaPlayerTile(entityId: id, size: .wide)
                    }
                }
            }

            // Cameras last, at half width, in their own 2-column grid. Last because a room glance
            // is usually about the lights and the temperature; a camera still is worth space on the
            // overview but not precedence over the controls — and putting four feeds at the top of
            // every room would make the dashboard a security console.
            let cameraIds = room.overviewRefs.compactMap { ref -> String? in
                guard case .entity(let id) = ref, Domain.of(id) == .camera else { return nil }
                return id
            }
            if !cameraIds.isEmpty {
                LazyVGrid(columns: cameraColumns, spacing: 9) {
                    ForEach(cameraIds, id: \.self) { id in
                        CameraTile(entityId: id, size: .square)
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
