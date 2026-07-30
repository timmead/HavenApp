import SwiftUI
import HavenCore

/// Makes a tile draggable, and a drop target, while the dashboard is being arranged.
///
/// **The system's drag and drop rather than a long press and a `DragGesture`.** The dashboard is a
/// horizontally-paging scroll view containing a vertical scroll, and `DashboardView` records that
/// hand-rolled pan logic is "the exact shape of the last two gesture bugs in this codebase". A
/// `.draggable` is arbitrated against those scroll views by the system instead of competing with
/// them, and brings the lift, the cancellation and the scroll-while-dragging that a custom gesture
/// would have to earn.
///
/// The cost is real and was accepted rather than overlooked: tiles shuffle into place on drop rather
/// than parting continuously under the finger. The home-screen feel is a custom gesture, and it can
/// be built later on top of an order that already works.
///
/// **Dropping on a tile inserts before it.** Which is why the `+` is the drop target for "last": it
/// is the only position that has no tile to be before.
struct RearrangeableTile: ViewModifier {
    let entityId: String
    let room: RoomSection
    /// The room's visible tiles in their current order — the list a move is computed against.
    let visibleIds: [String]
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation

    func body(content: Content) -> some View {
        if navigation.isConfiguring {
            content
                .draggable(entityId)
                .dropDestination(for: String.self) { ids, _ in
                    guard let dragged = ids.first else { return false }
                    Task {
                        let moved = TileOrder.moving(dragged, before: entityId, in: visibleIds)
                        // A tile dropped on itself, or a drop that changes nothing, must not write:
                        // a no-op write churns the shared record's version for the whole household.
                        guard moved != visibleIds else { return }
                        _ = await store.setOrder(moved, areaId: room.areaId)
                    }
                    return true
                }
        } else {
            // Outside configuration mode a tile has no drag at all — the gesture would compete with
            // the pager for nothing, since there is nothing to rearrange.
            content
        }
    }
}
