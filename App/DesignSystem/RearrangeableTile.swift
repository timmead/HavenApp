import SwiftUI
import UniformTypeIdentifiers
import HavenCore

/// What is being dragged, and where it would land.
///
/// Shared between a room's tiles because a drag is a fact about the *room*: one tile is lifted, a
/// different tile is the target, and both have to draw differently at the same moment.
@MainActor @Observable
final class TileDragState {
    /// The entity being dragged, or nil. Its own tile draws as an empty slot while this holds.
    var dragging: String?
    /// The entity the dragged tile would be inserted *before*, or nil for "after everything".
    var target: String?
    /// True once the drag has entered the trailing drop zone rather than a tile.
    var targetIsEnd = false

    func clear() {
        dragging = nil
        target = nil
        targetIsEnd = false
    }
}

/// Makes a tile draggable, and a drop target, while the dashboard is being arranged.
///
/// **System drag and drop, but through `onDrag`/`DropDelegate` rather than
/// `.draggable`/`.dropDestination`.** The arbitration is what matters and both give it: the dashboard
/// is a horizontally-paging scroll view containing a vertical scroll, and this codebase has been
/// bitten twice by hand-rolled pan logic, so letting the system decide whether a pan is a scroll or a
/// lift is the whole reason not to write a `DragGesture`.
///
/// The higher-level pair could not express three things, and the first version shipped all three
/// wrong:
///
/// - **The operation.** `.dropDestination` proposes a *copy*, so the system drew a green plus badge
///   on a tile that was being moved — alarming on a dashboard, where nothing is being duplicated.
///   `DropDelegate.dropUpdated` returning `.move` is the only way to say what is really happening.
/// - **The preview.** `.draggable` lifts the view together with its backing, which arrives as an
///   opaque square around a rounded tile. `onDrag(preview:)` takes a view, so what lifts can be the
///   tile's own shape and nothing behind it.
/// - **Where it would land.** Neither offers a hook mid-drag; a delegate's `dropEntered` does, and
///   that is what draws the caret.
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

    private var isLifted: Bool { drag.dragging == entityId }
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
                .onDrag {
                    drag.dragging = entityId
                    return NSItemProvider(object: entityId as NSString)
                } preview: {
                    // **Everything it draws is passed in, and that is not a style choice.** A drag
                    // preview is hosted by the drag session, *outside* this view hierarchy, so it
                    // inherits none of the environment — and a missing `@Observable` environment
                    // object is a `fatalError`, not a nil. Reading the store in here crashed the app
                    // the instant a tile was lifted.
                    TileDragPreview(title: store.displayName(of: entityId),
                                    symbol: IconMap.symbol(domain: Domain.of(entityId),
                                                           deviceClass: store.state(entityId)?.deviceClass),
                                    accent: HavenColor.domain(Domain.of(entityId)))
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
        drag.target = isEnd ? nil : target
        drag.targetIsEnd = isEnd
    }

    func dropExited(info: DropInfo) {
        if isEnd ? drag.targetIsEnd : drag.target == target {
            drag.target = nil
            drag.targetIsEnd = false
        }
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

/// What the finger carries: the tile's icon and name, on the tile's own shape.
///
/// Deliberately small and flat rather than a copy of the tile. `onDrag`'s default preview is a
/// snapshot of the view *and its backing*, which arrives as an opaque square around a rounded tile —
/// the shape mismatch that made the first version look broken. A view supplied here is drawn as
/// given, so what lifts is a rounded chip and nothing behind it.
///
/// **It takes plain values and reads no environment**, because a preview is hosted by the drag
/// session rather than by the view that started the drag: it has no ancestors, so it inherits no
/// environment, and `@Environment(HomeStore.self)` in here is a `fatalError` the moment a tile is
/// lifted. Anything it needs is resolved by the caller, which does have the environment.
private struct TileDragPreview: View {
    let title: String
    let symbol: String
    let accent: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(accent)
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accent.opacity(0.5), lineWidth: 1.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// **Deliberately injects no environment.** That is the whole point: this renders `TileDragPreview`
/// under the same conditions the drag session does — no ancestors, nothing in the environment — so if
/// an `@Environment` read is ever added back to the chip, this render fails here rather than crashing
/// the app in somebody's hand the moment they lift a tile. Which is how it was found the first time.
#Preview("Tile drag preview — no environment") {
    VStack(spacing: 16) {
        TileDragPreview(title: "Bedside Lamp", symbol: "lamp.table.fill", accent: HavenColor.domain(.light))
        TileDragPreview(title: "Hallway", symbol: "thermometer.medium", accent: HavenColor.domain(.climate))
        TileDragPreview(title: "Front Door Camera", symbol: "video.fill", accent: HavenColor.domain(.camera))
    }
    .padding(24)
}
