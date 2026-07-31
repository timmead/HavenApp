import SwiftUI
import HavenCore

struct RoomSectionView: View {
    let room: RoomSection
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    /// What is being dragged in *this* room and where it would land — see `TileDragState`. Owned
    /// here because a drag is a fact about the room: the lifted tile and the target are different
    /// tiles that must draw differently at the same moment.
    ///
    /// Injectable, and that is not gratuitous: the two states this adds — the hole a lifted tile
    /// leaves and the caret marking where it would land — exist only *during* a gesture, and a
    /// gesture is the one thing a preview cannot perform. Seeding it is the only way to look at
    /// them at all.
    @State private var drag: TileDragState

    init(room: RoomSection, drag: TileDragState = TileDragState()) {
        self.room = room
        _drag = State(initialValue: drag)
    }
    // The four `[GridItem]` arrays that used to live here — one per tile width — are gone; see
    // `body`. What they encoded, that a camera is two columns and a light is one, is now
    // `TileSpan.default(for:on:)`, and the grid honours it in one container instead of four.

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Only the heading (name + env chips) is wrapped for navigation — NOT the
            // roll-up buttons or the tile grid below, which rely on bare .onTapGesture /
            // .onLongPressGesture (see LightTile etc.) that would otherwise contend with
            // (and likely lose to) an enclosing NavigationLink's own tap recognizer.
            // The heading is the room's own control in both modes, and the *same* heading in both:
            // it is extracted rather than duplicated so the two branches cannot drift into looking
            // like different rooms.
            if navigation.isConfiguring {
                Button { navigation.presented = .roomConfig(areaId: room.areaId) } label: { heading }
                    .buttonStyle(.plain)
                    .accessibilityHint("Configures this room's readings")
            } else {
                NavigationLink(value: room.id) { heading }
                    .buttonStyle(.plain)
            }

            let rollups = store.rollups(room)
            if !rollups.isEmpty {
                HStack(spacing: 8) {
                    ForEach(rollups) { rollup in
                        rollupRow(rollup)
                    }
                    Spacer(minLength: 0)
                }
            }

            // **One grid, and every tile declares its span.**
            //
            // This was four stacked `LazyVGrid`s — climate at two columns, everything else at four,
            // media at two, cameras at two — because `.gridCellColumns` is inert inside a
            // `LazyVGrid`, so a 2-wide tile needed a literally 2-column grid. That worked, and it
            // made a room four containers: nothing could move from one part of it to another, which
            // is what rearranging a room means.
            //
            // `refs(for: .overview)`, not `deviceRefs`: the grid shows curated primary controls only
            // — demoted sensors and device telemetry live in room detail (see `CurationTier`) —
            // minus anything the household removed from this surface (see `SurfaceMembership`).
            let refs = room.refs(for: .overview)
            if !refs.isEmpty || navigation.isConfiguring {
                RoomGrid(columns: 4, spacing: 9) {
                    ForEach(refs) { ref in
                        if case .entity(let id) = ref {
                            let span = TileSpan.default(for: Domain.of(id), on: .overview)
                            tile(id, span: span)
                                .tileSpan(span)
                                .modifier(RearrangeableTile(entityId: id, room: room,
                                                            visibleIds: visibleIds(refs),
                                                            drag: drag))
                        }
                    }
                    // A cell like any other, last in the sequence, rather than a special case inside
                    // whichever grid happened to exist. One `+` per room per surface.
                    if navigation.isConfiguring {
                        AddTilePlaceholder {
                            navigation.presented = .addTile(areaId: room.areaId, surface: .overview)
                        }
                        .tileSpan(TileSpan(columns: 1, rows: 1))
                        // The `+` doubles as the drop target for "put it last": it is always the end
                        // of the sequence, so a tile dropped on it has nowhere else to mean. It
                        // shows the caret on its *trailing* edge, since arriving here means going
                        // after everything rather than before anything.
                        .overlay(alignment: .trailing) {
                            if drag.dragging != nil && drag.targetIsEnd {
                                Capsule()
                                    .fill(HavenColor.domain(.cover))
                                    .frame(width: 3)
                                    .padding(.vertical, 2)
                                    .offset(x: 6)
                            }
                        }
                        .onDrop(of: [.text], delegate: TileDropDelegate(
                            target: nil, isEnd: true, room: room, visibleIds: visibleIds(refs),
                            drag: drag, store: store))
                    }
                }
            }
        }
    }

    private func visibleIds(_ refs: [DeviceRef]) -> [String] {
        refs.compactMap { ref in
            guard case .entity(let id) = ref else { return nil }
            return id
        }
    }

    /// The renderer for one entity, at the size the grid has given it.
    ///
    /// **Every domain goes through the one dispatcher now.** Media and camera tiles used to be built
    /// here by hand because they have sizes to choose — which meant this view named a rendering while
    /// `TileSpan.default` separately named a number of cells, and the two agreed only because someone
    /// kept them agreeing. `DeviceTileView` takes the span and picks the rendering from it.
    private func tile(_ id: String, span: TileSpan) -> some View {
        DeviceTileView(entityId: id, surface: .overview, span: span)
    }

    /// The room's name and its readings. Rendered identically whether it pushes room detail or
    /// opens the room's configuration — see `body`.
    private var heading: some View {
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
                if rollup.kind == .lights { store.allOff(rollup, in: room.areaId) }
                else { store.closeAll(rollup, in: room.areaId) }
            }
            .font(.system(size: 12, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(hasActive ? accent : .secondary)
            .disabled(!hasActive)
            // Named rather than silent: a bulk action that half-fails used to revert the failed
            // rows with no explanation at all, which reads as the app ignoring the tap.
            //
            // Gated on `hasActive` too, not just `failures > 0`: this is the only way a stale count
            // ever clears without another bulk action. If the user fixes the failures by hand (e.g.
            // manually locks the one door that didn't respond), `activeCount` drops to 0, the button
            // disables, and the room genuinely has nothing left to complain about — but nothing
            // re-runs `recordBulkFailures` to zero the stored count, so without this gate the label
            // would go on accusing the room of a failure that no longer exists.
            let failures = store.bulkFailureCount(for: rollup.kind, in: room.areaId)
            if failures > 0 && hasActive {
                Text("\(failures) didn't respond")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HavenColor.warning)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(HavenColor.glassFill))
    }
}
