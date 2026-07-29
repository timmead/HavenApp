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
            // Says which mode the dashboard is in, and only that — the toolbar's Done is the way
            // out. It briefly carried a Done of its own as insurance against the toolbar button
            // failing to appear, which was a real bug at the time; with that fixed, two Dones a
            // centimetre apart is just two things to read where one would do.
            //
            // Inside the stack, attached to the pager, so it sits *below* the navigation bar. Placed
            // outside the stack it competed with the bar for the top safe area.
            .safeAreaInset(edge: .top) { editingBanner }
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
                // **The conditional is in the toolbar builder, not inside one item.** An `if` inside
                // a single `ToolbarItem`'s view builder gives the two states one identity, and
                // SwiftUI does not reliably swap the rendered control when the condition flips —
                // which is how configuration mode shipped with no visible way out. Two items with
                // distinct ids leave nothing to swap.
                if navigation.isConfiguring {
                    ToolbarItem(id: "configuration-done", placement: .topBarTrailing) {
                        Button("Done") { navigation.isConfiguring = false }
                            .fontWeight(.semibold)
                    }
                } else {
                    ToolbarItem(id: "dashboard-menu", placement: .topBarTrailing) {
                        Menu {
                            // Shown only to a confirmed HA admin, with a document we actually read
                            // and can write — see `HavenConfig.canConfigure`, where each of the four
                            // denials has its own reason. Omitted rather than disabled, which is
                            // this app's standing rule for a control that cannot act.
                            if store.config.canConfigure {
                                Button("Edit Dashboard", systemImage: "slider.horizontal.3") {
                                    navigation.isConfiguring = true
                                }
                            }
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
        }
        // On the stack, not on the pager: the bar stays put across a push, as the tab bar it
        // replaces did, and the safe-area inset it claims propagates into the pushed detail so
        // that view's own content clears it too.
        .safeAreaInset(edge: .bottom) { floorBar }
        // The mode must not outlive its own preconditions: an admin demoted mid-session, a dropped
        // connection, or a write that came back `not_authorized` (which records `isAdmin = false`)
        // all land here and close it, rather than leaving a dashboard that looks editable and
        // refuses every edit.
        .onChange(of: store.config.canConfigure) { _, canConfigure in
            if !canConfigure { navigation.isConfiguring = false }
        }
        // Floors are rebuilt wholesale on every registry reload and the selected one can vanish
        // across one. Keyed on the ids rather than the floors themselves: a reload changes every
        // floor's contents, so comparing the values would fire on every reload regardless.
        .onChange(of: floors.map(\.id)) { _, _ in
            scrolledFloorId = FloorPaging.selection(current: scrolledFloorId, floors: floors)
        }
        .sheet(item: Binding(get: { navigation.presented },
                             set: { navigation.presented = $0 })) { presentation in
            // `DeviceModalView` applies `.fittedSheet()` itself; the two configuration sheets are
            // presented here directly and get it here. Without it they are raw sheet content: no
            // fitted detent, no padding, no drag indicator — a full-screen takeover with nothing
            // saying how to leave, which is exactly how they shipped.
            switch presentation {
            case .control(let entityId): DeviceModalView(entityId: entityId)
            case .tileConfig(let entityId): TileConfigView(entityId: entityId).fittedSheet()
            case .roomConfig(let areaId): RoomConfigView(areaId: areaId).fittedSheet()
            }
        }
        // On the outermost view, so it reaches the pushed `RoomDetailView` and the sheet above as
        // well as the tiles in the pager.
        .environment(navigation)
        .sheet(isPresented: $showingConnectionSettings) { ConnectionSettingsView() }
    }

    /// Says which mode the dashboard is in. **A label, not a control** — see the call site.
    @ViewBuilder
    private var editingBanner: some View {
        if navigation.isConfiguring {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .bold))
                Text("Editing dashboard").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            // A tinted strip, not a saturated one. `.safeAreaInset(edge: .top)` content sits under
            // the navigation bar, and iOS tints the bar from whatever is beneath it — a solid accent
            // bar turned the whole top of the screen blue and left the toolbar's own Done sitting on
            // it in a mismatched capsule. Tint plus accent text says the same thing without
            // repainting the chrome.
            //
            // **Two layers, and the opaque one is not optional.** A safe-area inset raises the scroll
            // view's content inset; it does not stop content *passing beneath* the inset as it
            // scrolls. With only the 16%-alpha tint, a room heading and a camera still slid visibly
            // through the strip. `.background` (the adaptive system background) goes underneath so
            // the tint composites onto something solid rather than onto whatever is scrolling past.
            .foregroundStyle(HavenColor.domain(.cover))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(HavenColor.domain(.cover).opacity(0.16))
            .background(.background)
            .accessibilityAddTraits(.isHeader)
        }
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
