import SwiftUI
import UniformTypeIdentifiers
import HavenCore

/// What is being dragged, and where it would land.
///
/// Shared between a room's tiles because a drag is a fact about the *room*: one tile is lifted, a
/// different tile is the target, and both have to draw differently at the same moment.
@MainActor @Observable
final class TileDragState {
    /// The entity being dragged, or nil.
    ///
    /// **Not sufficient on its own to say a tile is lifted** — see `isOver`.
    var dragging: String?
    /// The entity the dragged tile would be inserted *before*, or nil for "after everything".
    var target: String?
    /// True once the drag has entered the trailing drop zone rather than a tile.
    var targetIsEnd = false

    /// Whether the finger is demonstrably over a drop target *right now*.
    ///
    /// **This is what stops the vacated slot reappearing after a drag finishes.** `dragging` is set
    /// from `onDrag`'s item-provider closure, and SwiftUI calls that closure more than once and at
    /// moments of its own choosing — including during the re-render that follows a completed drop,
    /// which silently re-marked a tile as lifted with no drag in progress at all.
    ///
    /// iOS offers no drag-ended callback to correct that with (`onDragSessionUpdated` is macOS-only),
    /// so the drawing is gated on a signal that can only be true during a real drag: the drop
    /// delegates, which fire as the finger moves and cannot fire when there is no finger. A stale
    /// closure call still sets `dragging`, and now nothing is drawn from it.
    private(set) var isOver = false

    /// Bumped on every entry, so a clear scheduled by one tile can tell it has been superseded.
    private var generation = 0

    func entered() {
        generation &+= 1
        isOver = true
    }

    /// Ends the drag — but **after long enough for a finger to cross a gap**, not immediately.
    ///
    /// The gaps between tiles are 9pt, and crossing one means leaving a target before entering the
    /// next, so a synchronous clear would blink the slot and the caret out on every crossing. The
    /// delay is sized to the hand rather than to the scheduler: a turn of the main actor is
    /// microseconds and a finger crossing 9pt is tens of milliseconds, so hopping once would lose
    /// this race in every case except a same-turn handoff.
    ///
    /// It costs nothing that shows. A completed drop clears synchronously in `performDrop`, so only
    /// a cancelled drag — or one released over nothing — waits this out.
    func endAfterHandoff() {
        let scheduled = generation
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard scheduled == self.generation else { return }
            self.clear()
        }
    }

    func clear() {
        dragging = nil
        target = nil
        targetIsEnd = false
        isOver = false
        generation &+= 1
    }
}

/// Makes a tile draggable, and a drop target, while the dashboard is being arranged.
///
/// **System drag and drop.** The arbitration is the reason: the dashboard is a horizontally-paging
/// scroll view containing a vertical scroll, and this codebase has been bitten twice by hand-rolled
/// pan logic, so letting the system decide whether a pan is a scroll or a lift is the whole reason
/// not to write a `DragGesture`.
///
/// It is assembled from three pieces, each of which replaced something that went wrong on a device:
///
/// - **`onDrag` for the source**, because `.draggable` cannot say what the preview's *shape* is, and
///   a rectangular snapshot of a rounded tile is the "bigger square with a white background" this
///   started as. `.contentShape(.dragPreview, ...)` is the fix, and the preview itself stays the
///   default — a rendering of this view — so what lifts is the tile that was in the slot.
/// - **`TileDropDelegate` for the destination**, whose `dropUpdated` is where a move stops being
///   advertised as a copy, and whose `dropEntered` is the only hook that fires mid-drag, and so the
///   only thing that can draw the caret or tell that a drag is still live.
/// - **`TileDragState.isOver` to decide what is drawn**, because iOS has no drag-ended callback at
///   all — `onDragSessionUpdated` and `dragConfiguration` are macOS-only, whatever the documentation
///   implies by not saying so. What a real drag *does* give is a stream of drop-delegate calls, and
///   that is what the drawing is gated on.
///
/// A lifted tile leaves its slot behind as an empty outline rather than the grid closing the gap.
/// The grid deliberately does not reflow under the finger — that was the accepted cost of not
/// writing this gesture by hand — so a hole that stays put is what keeps the arrangement legible
/// while one piece of it is in the air.
struct RearrangeableTile: ViewModifier {
    let entityId: String
    let room: RoomSection
    /// The room's visible tiles in their current order — the list a move is computed against.
    let visibleIds: [String]
    let drag: TileDragState
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation

    // Both halves matter: `dragging` alone can be a leftover from a stale `onDrag` call. See
    // `TileDragState.isOver`.
    private var isLifted: Bool { drag.dragging == entityId && drag.isOver }
    private var isTarget: Bool { drag.target == entityId && drag.dragging != entityId }

    func body(content: Content) -> some View {
        if navigation.isConfiguring {
            content
                // The tile in the air is not also on the grid — but the slot is *covered*, not
                // emptied with `.opacity(0)`.
                //
                // **Because the drag preview is a rendering of this same view.** Hiding the tile to
                // vacate its slot and snapshotting it for the finger happen at the same moment, and
                // nothing orders the two, so a lifted tile can be photographed blank. An opaque cover
                // leaves `content` at full opacity throughout: whatever the system snapshots is the
                // real tile, and the race stops existing rather than being won.
                .overlay {
                    if isLifted {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.background)
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(HavenColor.domain(.cover).opacity(0.35),
                                                  style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            }
                    }
                }
                // The caret marks the seam the tile would arrive in. On the *leading* edge because a
                // drop inserts before the tile it lands on — over the tile would say "replace this".
                .overlay(alignment: .leading) {
                    if isTarget {
                        Capsule()
                            .fill(HavenColor.domain(.cover))
                            .frame(width: 3)
                            .padding(.vertical, 2)
                            .offset(x: -6)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: isTarget)
                // **No custom preview: what lifts is this tile.** The default preview is a rendering
                // of the view itself, and in configuration mode that view is already the placeholder
                // — so the thing under the finger is the thing that was in the slot, which is the
                // whole ask. The first attempt supplied a substitute chip, which fixed the wrong
                // problem: the original complaint was that the dragged item was "a bigger square with
                // a white background", and that was its *bounds*, not its backing.
                .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onDrag {
                    drag.dragging = entityId
                    return NSItemProvider(object: entityId as NSString)
                }
                .onDrop(of: [.text], delegate: TileDropDelegate(
                    target: entityId, isEnd: false, room: room, visibleIds: visibleIds,
                    drag: drag, store: store))
        } else {
            // Outside configuration mode a tile has no drag at all — the gesture would compete with
            // the pager for nothing, since there is nothing to rearrange.
            content
        }
    }
}

/// The drop half, for one cell.
///
/// A delegate rather than `.dropDestination` for the three reasons on `RearrangeableTile` — chiefly
/// `dropUpdated`, which is where a move stops being advertised as a copy.
struct TileDropDelegate: DropDelegate {
    let target: String?
    /// True for the trailing zone, whose meaning is "after everything" rather than "before a tile".
    let isEnd: Bool
    let room: RoomSection
    let visibleIds: [String]
    let drag: TileDragState
    let store: HomeStore

    func validateDrop(info: DropInfo) -> Bool { drag.dragging != nil }

    /// **This is where the green plus goes away.** Without an explicit `.move` the system advertises
    /// a copy, and a badge promising a second copy of a device is worse than no badge at all.
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropEntered(info: DropInfo) {
        drag.entered()
        drag.target = isEnd ? nil : target
        drag.targetIsEnd = isEnd
    }

    /// Only the tile the drag is *currently* over may end it — otherwise a handoff between two tiles
    /// would let the one being left cancel the one being entered.
    func dropExited(info: DropInfo) {
        guard isEnd ? drag.targetIsEnd : drag.target == target else { return }
        drag.endAfterHandoff()
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { drag.clear() }
        guard let dragged = drag.dragging else { return false }
        let moved = TileOrder.moving(dragged, before: isEnd ? nil : target, in: visibleIds)
        // A tile dropped where it already was must not write: a no-op write churns the shared
        // record's version, which the rest of the household reads as somebody rearranging the room.
        guard moved != visibleIds else { return false }
        Task { _ = await store.setOrder(moved, areaId: room.areaId) }
        return true
    }
}

/// The chip that used to be carried by the finger is gone, and so is the preview that guarded it.
/// A tile now drags as itself — see `.contentShape(.dragPreview, ...)` above — which is both what was
/// asked for and one fewer view hosted outside the hierarchy with nothing in its environment.
