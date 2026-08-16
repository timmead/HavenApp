import SwiftUI
import HavenCore

/// Full room view: one room as a vertical stack of subsections — the same containers the floor view
/// renders, at `.regular` density because a kind's name is the only heading on this screen.
struct RoomDetailView: View {
    let room: RoomSection
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    @State private var showingEnvironmentHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // **The same construct the floor view renders**, and the only thing this screen
                // disagrees with it about is loudness: `.regular` density, because here a kind's
                // name is the whole heading rather than a sub-label under a room's.
                //
                // `.roomDetail` is the surface, and it is what makes this the place demoted entities
                // are reachable: `refs(for: .roomDetail)` is the overview's controls *plus* the
                // sensors curation kept off the grid. A device removed from the *dashboard* is still
                // here; removal is per surface. The resolver reads that list — the domain switch
                // this view used to carry as `Grouped`/`grouped` is `SubsectionKind.of(_:)` now,
                // tested in Core rather than living untested in a view body.
                ForEach(store.subsections(room, on: .roomDetail)) { subsection in
                    SubsectionView(room: room, subsection: subsection, surface: .roomDetail,
                                   density: .regular)
                }
                // **One `+` for the whole screen rather than one per subsection**, matching the
                // floor view: the subsections are a presentation of one list and the picker is not
                // scoped to a kind — an added device lands in whichever subsection its domain
                // belongs to. Outside the stack, so a room showing nothing still has one.
                //
                // **`RoomGrid`, not the `LazyVGrid` this used to be** (follow-up 6): the branch's
                // thesis is one construct per concept, and a `LazyVGrid` here was the last place a
                // room's tiles still went through the grid `RoomGrid` replaced everywhere else —
                // `RoomGrid`'s own doc comment already carries the reason (`.gridCellColumns` is inert
                // in a `LazyVGrid`, which is what made a room four separate grids before `RoomGrid`
                // existed), so losing this file's second copy of that reasoning is consolidation, not
                // comment loss. A single 1×1 cell has no span to honour either way; this only changes
                // which layout draws it.
                if navigation.isConfiguring {
                    RoomGrid(columns: 4, spacing: 9) {
                        AddTilePlaceholder {
                            navigation.presented = .addTile(areaId: room.areaId, surface: .roomDetail)
                        }
                        .tileSpan(TileSpan(columns: 1, rows: 1))
                    }
                }
            }
            .padding()
            // The floor bar floats over this view rather than insetting it, so the last row of
            // tiles would otherwise sit behind it — see `DashboardView.clearance`.
            .padding(.bottom, DashboardView.clearance)
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
                // **Reachability, not a new capability** (follow-up 3): `.roomConfig` already exists
                // and already clears both surfaces — see `HomeStore.resetOrder`'s own doc comment —
                // but the only door to it was the floor's tappable room heading. Room detail had no
                // heading of its own to wrap the same way (the name lives in `.navigationTitle`, a
                // system-drawn view this file cannot make tappable), so it gets a toolbar button
                // instead, matching the icon and label the floor's own reason for opening this sheet
                // already gives.
                ToolbarItem(id: "room-configuration-readings", placement: .topBarTrailing) {
                    Button {
                        navigation.presented = .roomConfig(areaId: room.areaId)
                    } label: {
                        Image(systemName: "thermometer.medium")
                    }
                    .accessibilityLabel("Configures this room's readings")
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
}
