import SwiftUI
import HavenCore

/// The dashboard: one floor per full-width page, paged horizontally, with a floor bar pinned at
/// the bottom.
///
/// Paging is a plain `ScrollView(.horizontal)` with `.scrollTargetBehavior(.paging)` and *not* a
/// `DragGesture`, because the two behaviours this screen has to have are the two a scroll view
/// already has and a drag gesture does not: a distance threshold before a horizontal pan is
/// claimed at all, and a directional lock so a vertical scroll already under way inside a floor
/// can never turn into a page change. Hand-rolling those means re-deriving UIScrollView's pan
/// logic inside a gesture whose own view is moving beneath it — the exact shape of the last two
/// gesture bugs in this codebase.
struct DashboardView: View {
    @Environment(HomeStore.self) private var store
    @Environment(AppModel.self) private var app
    /// Where the optional "connect faster at home" upgrade is offered. Reached only by deliberate
    /// navigation — the location prompt behind it must never appear during onboarding.
    @State private var showingConnectionSettings = false
    /// The single source of truth for which floor is showing: the scroll view writes it as the
    /// user swipes, the floor bar writes it when a tab is tapped, and both read it back. Two
    /// states kept in step by hand is how a tab bar ends up disagreeing with its content.
    /// `nil` until the scroll view first reports a position — see `selectedFloorId`.
    @State private var scrolledFloorId: String?
    /// One navigation stack for the whole pager rather than one per floor. Per-floor stacks would
    /// put the interactive back-swipe — an edge pan — in direct competition with the pager's own
    /// horizontal pan on the same view, and would leave a pushed `RoomDetailView` sitting inside a
    /// page that is still swipeable sideways into a different floor. With the stack outside, a
    /// pushed detail covers the pager entirely, so the back-swipe is the only horizontal gesture
    /// on screen and no room can be dragged into another floor's context.
    @State private var path: [String] = []
    /// Which device modal is open. Owned here rather than by `HomeStore` — see `Navigation`. Being
    /// `@State` on the view that only exists while `phase == .ready` is the whole point: sign-out,
    /// reauthentication and a mid-session reconnect all destroy it on their way past, so a stale
    /// modal cannot outlive the session that opened it.
    @State private var navigation = Navigation()

    private var floors: [ResolvedFloor] { store.home.floors }
    /// What the bar highlights and the title names. Falls back to the first floor so neither is
    /// blank on the first render, before the scroll view has reported anything.
    private var selectedFloorId: String? { scrolledFloorId ?? floors.first?.id }

    var body: some View {
        let rooms = store.rooms()
        NavigationStack(path: $path) {
            ScrollView(.horizontal) {
                // Lazy so a five-floor house builds one floor of tiles to show one floor of tiles.
                // The cost is that paging away from a floor discards it, and its vertical scroll
                // offset with it — a floor you come back to starts at the top.
                LazyHStack(spacing: 0) {
                    ForEach(floors) { floor in
                        floorPage(floor, rooms: rooms)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrolledFloorId)
            .scrollIndicators(.hidden)
            .navigationTitle(floors.first { $0.id == selectedFloorId }?.name ?? "")
            // Inline, not the large title each floor used to carry: the navigation bar now sits
            // above a *horizontal* scroll view, so there is no vertical offset for it to collapse
            // against. A large title here would be one that never shrinks.
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { roomId in
                if let room = rooms.first(where: { $0.id == roomId }) {
                    RoomDetailView(room: room)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Connection", systemImage: "wifi") {
                            showingConnectionSettings = true
                        }
                        Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            Task { await app.signOut() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        // On the stack, not on the pager: the bar stays put across a push, as the tab bar it
        // replaces did, and the safe-area inset it claims propagates into the pushed detail so
        // that view's own content clears it too.
        .safeAreaInset(edge: .bottom) { floorBar }
        // Floors are rebuilt wholesale on every registry reload and the selected one can vanish
        // across one. Keyed on the ids rather than the floors themselves: a reload changes every
        // floor's contents, so comparing the values would fire on every reload regardless.
        .onChange(of: floors.map(\.id)) { _, _ in
            scrolledFloorId = FloorPaging.selection(current: scrolledFloorId, floors: floors)
        }
        .sheet(isPresented: Binding(get: { navigation.presentedEntityId != nil },
                                    set: { if !$0 { navigation.presentedEntityId = nil } })) {
            if let id = navigation.presentedEntityId { DeviceModalView(entityId: id) }
        }
        // On the outermost view, so it reaches the pushed `RoomDetailView` and the sheet above as
        // well as the tiles in the pager.
        .environment(navigation)
        .sheet(isPresented: $showingConnectionSettings) { ConnectionSettingsView() }
    }

    /// One floor's page — the same vertical scroll of rooms as before. Deliberately carries no
    /// width of its own; the caller sizes it to the container so a floor with two rooms is exactly
    /// as wide as a floor with twenty.
    private func floorPage(_ floor: ResolvedFloor, rooms: [RoomSection]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(floor.areas) { area in
                    if let room = rooms.first(where: { $0.areaId == area.id }) {
                        RoomSectionView(room: room)
                    }
                }
            }.padding()
        }
    }

    /// The floor bar, hand-built rather than a `TabView`'s own. No `TabView` style gives both
    /// halves of what this screen needs: `.page` swipes but drops the bar, and the styles that
    /// show a bar do not swipe. Building the bar is the smaller of the two gaps to close.
    ///
    /// This is what costs us `.tabViewStyle(.sidebarAdaptable)` — on iPad the floors were a
    /// sidebar and are now this same bottom bar. Accepted: the swipe is the feature being built,
    /// and the iPad layout was an affordance we got for free rather than one that was designed.
    @ViewBuilder
    private var floorBar: some View {
        if !floors.isEmpty {
            HStack(spacing: 0) {
                ForEach(floors) { floor in floorTab(floor) }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background {
                Capsule().fill(.regularMaterial)
                    .overlay(Capsule().strokeBorder(HavenColor.glassStroke, lineWidth: 1))
            }
            .padding(.horizontal, 16)
        }
    }

    /// One floor's tab. Tapping pops any pushed room first: the bar sits *over* `RoomDetailView`,
    /// and quietly changing the floor behind an open room would leave the two disagreeing about
    /// where the user is — the same "tap the current tab to go back to its root" the tab bar this
    /// replaces did for free.
    private func floorTab(_ floor: ResolvedFloor) -> some View {
        let selected = floor.id == selectedFloorId
        return Button {
            path.removeAll()
            withAnimation(.snappy) { scrolledFloorId = floor.id }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 16, weight: selected ? .semibold : .regular))
                Text(floor.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
