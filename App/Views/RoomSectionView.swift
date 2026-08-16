import SwiftUI
import HavenCore

/// One room on the floor view: its heading, then its subsections.
struct RoomSectionView: View {
    let room: RoomSection
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Only the heading (name + env chips) is wrapped for navigation — NOT the subsections
            // below it, whose roll-up buttons and tiles rely on bare .onTapGesture /
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

            // **A room is its subsections.** Which of them exist, what is in each, how big its tiles
            // are and how they are laid out is all `Subsections.resolve`'s decision — read through
            // the store so this view observes the household document (see
            // `HomeStore.subsections(_:on:)`). The roll-up row that used to sit here went with it:
            // "All Off" belongs beside the Lights, not beside the room's name (design decision 6).
            //
            // `.overview` is the surface, and it is what confines this to the room's curated primary
            // controls — demoted sensors and device telemetry live in room detail (see
            // `CurationTier`), minus anything the household removed from this surface (see
            // `SurfaceMembership`). The resolver consumes `refs(for:)` and filters nothing itself.
            ForEach(store.subsections(room, on: .overview)) { subsection in
                SubsectionView(room: room, subsection: subsection, surface: .overview,
                               density: .compact)
            }

            // **One `+` per room per surface**, outside the subsection stack rather than in one of
            // them: the subsections are a presentation of one list and the picker is not scoped to a
            // kind — an added device lands in whichever subsection its domain belongs to. Outside
            // also means a room with nothing on this surface still has one, which is the only way a
            // device ever gets onto an empty room.
            if navigation.isConfiguring {
                RoomGrid(columns: 4, spacing: 9) {
                    AddTilePlaceholder {
                        navigation.presented = .addTile(areaId: room.areaId, surface: .overview)
                    }
                    .tileSpan(TileSpan(columns: 1, rows: 1))
                }
            }
        }
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
}
