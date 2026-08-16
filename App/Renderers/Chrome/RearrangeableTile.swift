import SwiftUI
import UniformTypeIdentifiers
import HavenCore

// In `Renderers/Chrome/` for the reason recorded on `ConfigurableTile`: it reads `HomeStore` and
// `Navigation` from the environment, which is the one thing a widget or watch target cannot
// supply. `import HavenCore` alone would not have moved it.

/// Which lift is the live one.
///
/// **The one genuinely app-wide fact about dragging, and the only one.** iOS runs a single drag
/// session at a time, so "is a drag in progress, and is it *this* one" is not a question a subsection
/// can answer from its own state — every `SubsectionView` has its own `TileDragState`, and a
/// subsection whose drag was abandoned has no way to notice that the world moved on without it.
///
/// It carries no drag *content* — not what is lifted, not where it would land — so the isolation
/// that matters is untouched: a lifted tile still has no representation in any container but its
/// own. This is a clock, not a channel.
///
/// Monotonic and never reset. `&+` so a wrap after 2^63 lifts is defined rather than a crash, and
/// the comparison is equality, so wrapping costs nothing.
@MainActor
enum TileDragSession {
    /// The id of the most recent lift. Zero before the first, which no state ever claims — a fresh
    /// `TileDragState` has `session` zero *and* a nil `dragging`, and it is `dragging` that is
    /// checked first.
    private(set) static var current = 0

    static func begin() -> Int {
        current &+= 1
        return current
    }
}

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

    /// Which lift this state belongs to — see `TileDragSession`. Stale the moment a newer lift
    /// happens anywhere in the app, which is what tells an abandoned drag that it is over.
    private(set) var session = 0

    /// Whether this state describes the drag that is happening *now*.
    ///
    /// Both halves are needed and neither is enough. `dragging` alone was the old test, and it says
    /// only that a drag once started here. The session says it has not since been superseded.
    var isLive: Bool { dragging != nil && session == TileDragSession.current }

    /// A tile has been lifted: this is the start of a drag session.
    ///
    /// Called from `RearrangeableTile`'s `onDrag`, and by tests, so that what a test calls a lift and
    /// what the app calls a lift cannot drift apart.
    ///
    /// **Residual risk, named rather than left to a report.** SwiftUI may re-invoke `onDrag`'s
    /// closure at moments of its own choosing (see `isOver`) — including, undocumented, on a tile
    /// other than the one actually lifted. A re-invocation on a *different* subsection's tile mid-drag
    /// would call this method there, claiming session currency for that subsection and superseding
    /// whatever drag is actually live.
    ///
    /// This creates no new wrong-write exposure: the old, session-less code would also have set that
    /// other subsection's `dragging` wrongly on the same spurious call. What is new is a fail-safe
    /// failure mode the old code lacked: the live drag's own session goes stale,
    /// `TileDropDelegate.discardIfSuperseded` refuses it mid-gesture, and the drag self-heals rather
    /// than writes — the user retries, and nothing was written. I have no evidence this re-invocation
    /// happens; it is named because it is the one place this mechanism could be wrong.
    func begin(_ entityId: String) {
        dragging = entityId
        session = TileDragSession.begin()
    }

    func entered() {
        generation &+= 1
        isOver = true
    }

    /// Stops *drawing* the drag — but **after long enough for a finger to cross a gap**, not
    /// immediately.
    ///
    /// The gaps between tiles are 9pt, and crossing one means leaving a target before entering the
    /// next, so a synchronous stop would blink the slot and the caret out on every crossing. The
    /// delay is sized to the hand rather than to the scheduler: a turn of the main actor is
    /// microseconds and a finger crossing 9pt is tens of milliseconds, so hopping once would lose
    /// this race in every case except a same-turn handoff.
    func endAfterHandoff() {
        let scheduled = generation
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard scheduled == self.generation else { return }
            self.endDrawing()
        }
    }

    /// Forgets where the finger is, and **deliberately not what is in the air**.
    ///
    /// **This split is a bug fix, and the bug was that one field did both jobs.** `dragging` names
    /// the item the *session* is carrying; `isOver`/`target` say where the finger is *now*. Leaving
    /// a tile ends the second and says nothing about the first — the finger is still down and iOS is
    /// still carrying the item.
    ///
    /// This used to call `clear()`, which nils `dragging` — and `dragging != nil` is also what
    /// `TileDropDelegate.validateDrop` answers with. So a finger that strayed off its subsection for
    /// 200ms (over a sibling subsection, a heading, anywhere with no drop area of its own) had the
    /// item silently taken out of the air beneath it: every delegate in the origin subsection began
    /// refusing the drop, iOS drew the "no" badge, and coming back could not undo it because nothing
    /// re-sets `dragging` mid-session. `onDrag`'s closure runs at the lift, not on re-entry.
    ///
    /// That it *sometimes* recovered is the same fact from the other side, and is why this presented
    /// as intermittent: SwiftUI re-invokes the `onDrag` closure at moments of its own choosing (see
    /// `isOver`), so a stray re-set `dragging` by luck.
    ///
    /// Note this fix does not depend on whether SwiftUI re-runs `validateDrop` on re-entry — a
    /// question the documentation does not settle. If it does, it now returns true; if it caches an
    /// earlier answer, the drop that follows no longer trips `performDrop`'s nil guard. Both branches
    /// were broken by the same nil and are fixed by not writing it.
    ///
    /// What clears `dragging` is a *completed* drop, in `performDrop`.
    ///
    /// **There is a second bug on the other side of this line, and it is worth both being written
    /// down.** The unconditional `clear()` was wrong for a live stray, above — but it did, by
    /// accident, mop up after a drag that was *abandoned*: released over a heading, over the gap
    /// between subsections, anywhere without a drop area, so that `performDrop` never runs and this
    /// state is simply left behind. Removing the clear fixed the first case and exposed the second,
    /// which is worse: leftover state that a later, unrelated drag can pick up and act on. Fixing
    /// one and minting the other is what happens when a single field means two things and a timer is
    /// asked to arbitrate.
    ///
    /// So the abandoned case is handled where it can be handled *deterministically* rather than
    /// after a delay — `TileDropDelegate.discardIfSuperseded`, which reads a newer lift as proof this
    /// one is over. Nothing here needs to guess how long a drag lasts, which is the mistake both
    /// previous defects were made of.
    ///
    /// A leftover `dragging` draws nothing in the meantime: `isLifted` and `isTarget` are both gated
    /// on state this method clears.
    func endDrawing() {
        target = nil
        targetIsEnd = false
        isOver = false
        generation &+= 1
    }

    /// Ends the drag outright: nothing in the air, nothing drawn. The end of a *session*, which is a
    /// completed drop — see `endDrawing` for why leaving a tile is not one.
    func clear() {
        dragging = nil
        endDrawing()
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
    /// The surface being arranged. **Each surface keeps its own order** (design decision 9), so a
    /// drag has to say which one it is: the same tile dragged on the dashboard and in room detail
    /// writes two different lists, and it must, because the two surfaces do not show the same
    /// tiles. See `HomeStore.setOrder`.
    let surface: HavenSurface
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
                    drag.begin(entityId)
                    // For a composite this is `ref.id`, not an HA entity id — see the call site's
                    // doc comment in `SubsectionView.wrapBody`. Nothing reads it back synchronously
                    // today (`TileDropDelegate` never inspects the provider's payload, only
                    // `drag.dragging`), but the name would mislead a future payload consumer.
                    return NSItemProvider(object: entityId as NSString)
                }
                .onDrop(of: [.text], delegate: TileDropDelegate(
                    target: entityId, isEnd: false, room: room, visibleIds: visibleIds,
                    surface: surface, drag: drag, store: store))
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
    /// Which surface's order this drop writes — see `RearrangeableTile.surface`.
    let surface: HavenSurface
    let drag: TileDragState
    let store: HomeStore

    // MARK: - DropDelegate
    //
    // Each of these forwards to a method below that takes no `DropInfo`. Not indirection for its own
    // sake: `DropInfo` has no public initialiser, so a test cannot call these four at all — and the
    // sequencing they express (enter, stray, re-enter, drop) is exactly where this file's two
    // shipped drag defects lived. Split this way it is plain code with tests on it. Nothing here
    // reads `info`; if something ever needs to, it takes a parameter and the split still holds.

    func validateDrop(info: DropInfo) -> Bool { accepts }

    /// **This is where the green plus goes away.** Without an explicit `.move` the system advertises
    /// a copy, and a badge promising a second copy of a device is worse than no badge at all.
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropEntered(info: DropInfo) { entered() }
    func dropExited(info: DropInfo) { exited() }
    func performDrop(info: DropInfo) -> Bool { drop() }

    // MARK: - The logic, without SwiftUI

    /// Whether this area will take the drop: **only while its own subsection has something in the
    /// air**.
    ///
    /// A subsection the drag did not start in answers false, which is what confines a drag to one
    /// container — see `SubsectionView.drag`. It must go on answering true for the *origin*
    /// subsection for as long as the session lasts, however far the finger has wandered in between;
    /// `TileDragState.endDrawing` records the defect that got that wrong.
    /// **Discards first, then answers a single question.** The two used to be separate checks — a
    /// session comparison here *and* a discard beside it — and a mutation test showed the comparison
    /// was dead weight: the discard nils `dragging`, so the answer was already no. Redundant guards
    /// that cannot fail independently are guards nobody can verify, so there is one.
    var accepts: Bool {
        discardIfSuperseded()
        return drag.dragging != nil
    }

    /// Throws away state belonging to a drag that has demonstrably ended, and is the app's only
    /// self-heal for one.
    ///
    /// **A drag that is abandoned never tells anyone.** `performDrop` is what clears `dragging`, and
    /// it only runs when the finger comes up over a drop area — lift over a heading, the gap between
    /// two subsections, or another room, and the subsection the drag started in keeps holding it.
    /// Nothing else in the session ever fires again.
    ///
    /// Left there, that state is not merely untidy, it is armed: the next drag from anywhere in the
    /// app, crossing this subsection, would find `dragging != nil`, accept, draw a caret, and on
    /// release reorder **the abandoned entity** — a tile the user has not touched this time,
    /// written straight to the shared household document. That is the defect this method exists for,
    /// and `aStaleDragFromAnAbandonedSessionIsRefused` is it.
    ///
    /// A newer lift is proof, and the only proof available. It is not a timer and does not guess how
    /// long a drag ought to last: the previous two defects here were both a timer deciding something
    /// it could not know.
    ///
    /// **Why not read the dragged id back off the drag session instead**, which would be the more
    /// direct check? Because it cannot be done in time. `onDrag` does carry the entity id —
    /// `NSItemProvider(object: entityId as NSString)` — but every route back out of a provider
    /// (`loadObject(ofClass:)`, `loadItem(forTypeIdentifier:)`) is completion-handler based, and
    /// `validateDrop` must answer `Bool` synchronously. The synchronous things a provider does offer
    /// are no use: `registeredTypeIdentifiers` is the same for every tile, and identity comparison of
    /// the provider object rests on UIKit handing back the very instance `onDrag` returned, which is
    /// not documented and would fail closed — refusing every drop in the app — if it ever stopped
    /// being true. A session id we mint ourselves depends on nothing outside this file.
    private func discardIfSuperseded() {
        guard drag.dragging != nil, !drag.isLive else { return }
        drag.clear()
    }

    /// **Gated on `accepts`, for the same reason `endDrawing` exists.** SwiftUI is not documented to
    /// say whether `dropEntered` can reach a delegate whose `validateDrop` answered false, and it
    /// probably does not — but "probably does not" is the kind of unsettled contract that produced
    /// the stray-ends-the-drag defect. Ungated, a finger crossing a *sibling* subsection would set
    /// that subsection's `target`, and its tile would draw a caret advertising a drop that cannot
    /// happen there.
    func entered() {
        guard accepts else { return }
        drag.entered()
        drag.target = isEnd ? nil : target
        drag.targetIsEnd = isEnd
    }

    /// Only the tile the drag is *currently* over may end it — otherwise a handoff between two tiles
    /// would let the one being left cancel the one being entered.
    func exited() {
        guard isEnd ? drag.targetIsEnd : drag.target == target else { return }
        drag.endAfterHandoff()
    }

    func drop() -> Bool {
        defer { drag.clear() }
        // `accepts` and not `drag.dragging != nil`: a drop can arrive at an area whose validate said
        // no (see `entered`), and this is the one path that writes to the household document.
        guard accepts, let dragged = drag.dragging else { return false }
        let moved = TileOrder.moving(dragged, before: isEnd ? nil : target, in: visibleIds)
        // A tile dropped where it already was must not write: a no-op write churns the shared
        // record's version, which the rest of the household reads as somebody rearranging the room.
        guard moved != visibleIds else { return false }
        Task { _ = await store.setOrder(moved, areaId: room.areaId, on: surface) }
        return true
    }
}

/// The chip that used to be carried by the finger is gone, and so is the preview that guarded it.
/// A tile now drags as itself — see `.contentShape(.dragPreview, ...)` above — which is both what was
/// asked for and one fewer view hosted outside the hierarchy with nothing in its environment.
