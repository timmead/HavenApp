import Testing
import Foundation
import HavenCore
@testable import HavenApp

/// The drag machinery's state transitions and drop sequencing, driven as plain methods.
///
/// **No gesture is performed here, and none needs to be.** `TileDropDelegate`'s four `DropDelegate`
/// methods take a `DropInfo`, which has no public initialiser and so cannot be built by a test — so
/// each forwards to a `DropInfo`-free method, and those are what this drives. What that buys is the
/// thing gestures were previously the only way to reach: the *sequence*. Enter a tile, stray off it
/// long enough for the handoff timer to fire, come back — three calls here, and the pair of shipped
/// defects this suite was written for both lived in exactly that order of events.
///
/// What still needs hands: whether iOS routes a real finger through these methods in the order the
/// tests assume. That is why the human pass is not replaced by this file.
///
/// **Serialized, and it has to be.** `TileDragSession` is app-wide by design — there is one drag in
/// iOS at a time — so two of these running concurrently would be two lifts racing, and a test that
/// awaits the handoff timer would find its own session superseded by another test's. Every case here
/// lifts through `lift(_:in:)` for the same reason: a state assembled by hand, without a session, is
/// a state the app cannot produce.
@Suite(.serialized) @MainActor struct TileDragTests {

    /// Built through `SectionBuilder` rather than by hand: `RoomSection`'s memberwise initialiser is
    /// internal to HavenCore, and this bundle links the package rather than living in it.
    private func room() -> RoomSection {
        let area = ResolvedArea(id: "lounge", name: "Lounge",
                                entityIds: ["light.a", "light.b", "light.c"],
                                tiers: ["light.a": .primary, "light.b": .primary,
                                        "light.c": .primary])
        let home = ResolvedHome(floors: [ResolvedFloor(id: "f", name: "F", level: 0, areas: [area])])
        return SectionBuilder.rooms(from: home, environment: [:], devices: [:], overrides: [:],
                                    orders: [:])[0]
    }

    private let ids = ["light.a", "light.b", "light.c"]

    /// A delegate over one tile of the room, sharing `drag`.
    private func delegate(_ drag: TileDragState, target: String?, isEnd: Bool = false,
                          store: HomeStore = HomeStore()) -> TileDropDelegate {
        TileDropDelegate(target: target, isEnd: isEnd, room: room(), visibleIds: ids,
                         surface: .overview, drag: drag, store: store)
    }

    /// A lift, exactly as `RearrangeableTile`'s `onDrag` performs one.
    private func lift(_ entityId: String, in drag: TileDragState) { drag.begin(entityId) }

    /// Longer than `endAfterHandoff`'s 200ms, so the scheduled work has demonstrably run.
    private func awaitHandoffTimer() async throws {
        try await Task.sleep(for: .milliseconds(320))
    }

    // MARK: - What a stray does to the item in the air

    /// **The regression.** Leaving a tile stops the *drawing* and must not take the dragged item out
    /// of the air: the finger is still down and iOS is still carrying it.
    ///
    /// This is the whole of the "stray too far and it never becomes droppable again" defect, at the
    /// level it actually happened. `endAfterHandoff` called `clear()`, `clear()` nils `dragging`, and
    /// `dragging != nil` is what `validateDrop` answers with — so a finger off its subsection for
    /// 200ms made every delegate in the *origin* subsection start refusing, with nothing able to
    /// undo it, because `onDrag`'s closure runs at the lift and not on re-entry.
    @Test func strayingLongEnoughStopsTheDrawingButKeepsTheItemInTheAir() async throws {
        let drag = TileDragState()
        lift("light.a", in: drag)
        drag.entered()
        drag.target = "light.c"

        drag.endAfterHandoff()
        try await awaitHandoffTimer()

        #expect(drag.dragging == "light.a")
        #expect(drag.isOver == false)
        #expect(drag.target == nil)
        #expect(drag.targetIsEnd == false)
    }

    /// The same fact where it bites: the origin subsection goes on accepting the drop however long
    /// the finger has been away. `accepts` is `validateDrop`.
    @Test func theOriginSubsectionStillAcceptsAfterAStray() async throws {
        let drag = TileDragState()
        lift("light.a", in: drag)
        let overC = delegate(drag, target: "light.c")

        overC.entered()
        overC.exited()
        try await awaitHandoffTimer()

        #expect(overC.accepts)
    }

    /// And coming back draws again. `entered()` is the only thing that restores `isOver`, so a
    /// re-entry after a stray has to go through it — which it does, since the area never stopped
    /// accepting.
    @Test func comingBackAfterAStrayDrawsTheCaretAgain() async throws {
        let drag = TileDragState()
        lift("light.a", in: drag)
        let overC = delegate(drag, target: "light.c")

        overC.entered()
        overC.exited()
        try await awaitHandoffTimer()
        #expect(drag.isOver == false)

        overC.entered()
        #expect(drag.isOver)
        #expect(drag.target == "light.c")
    }

    /// A completed drop *is* the end of the session, and clears everything — the distinction
    /// `endDrawing` exists to make.
    @Test func aCompletedDropTakesTheItemOutOfTheAir() {
        let drag = TileDragState()
        lift("light.c", in: drag)
        drag.entered()
        let overA = delegate(drag, target: "light.a")

        #expect(overA.drop())
        #expect(drag.dragging == nil)
        #expect(drag.isOver == false)
        #expect(drag.target == nil)
    }

    /// Crossing the 9pt gap between two tiles must not blink the drag out: the second tile's
    /// `entered()` bumps the generation, and the clear the first one scheduled sees it has been
    /// superseded and does nothing.
    @Test func aHandoffBetweenTwoTilesSurvivesTheTimer() async throws {
        let drag = TileDragState()
        lift("light.a", in: drag)
        let overB = delegate(drag, target: "light.b")
        let overC = delegate(drag, target: "light.c")

        overB.entered()
        overB.exited()          // leaving b
        overC.entered()         // arriving at c, well within the 200ms
        try await awaitHandoffTimer()

        #expect(drag.isOver)
        #expect(drag.target == "light.c")
    }

    /// Only the tile the finger is *currently* over may end the drawing. A late exit from a tile
    /// already handed off would otherwise cancel the drag under the tile that took over.
    @Test func aStaleExitFromAnAlreadyLeftTileIsIgnored() async throws {
        let drag = TileDragState()
        lift("light.a", in: drag)
        let overB = delegate(drag, target: "light.b")
        let overC = delegate(drag, target: "light.c")

        overC.entered()
        overB.exited()          // b is not the current target; this must be a no-op
        try await awaitHandoffTimer()

        #expect(drag.isOver)
        #expect(drag.target == "light.c")
    }

    // MARK: - One drag, one subsection

    /// A subsection the drag did not start in refuses it, and touches nothing belonging to the one
    /// that did. This is what makes a cross-subsection drop inexpressible rather than detected —
    /// see `SubsectionView.drag`.
    @Test func aSiblingSubsectionRefusesAndDisturbsNothing() {
        let origin = TileDragState()
        lift("light.a", in: origin)
        origin.entered()
        origin.target = "light.c"

        let sibling = TileDragState()          // its own state, nothing in the air
        let inSibling = delegate(sibling, target: "cover.x")

        #expect(inSibling.accepts == false)
        inSibling.entered()

        // It draws nothing of its own: a caret there would advertise a drop that cannot happen.
        #expect(sibling.target == nil)
        #expect(sibling.isOver == false)
        // And it cannot move the origin's caret, because it is not the origin's state.
        #expect(origin.target == "light.c")
        #expect(origin.dragging == "light.a")
    }

    // MARK: - State left behind by a drag that never finished

    /// **A drag abandoned over empty space must not arm the subsection it started in.**
    ///
    /// Nothing calls `performDrop` when the finger lifts somewhere with no drop delegate under it —
    /// a heading, the gap between subsections, another room — so that subsection is left holding a
    /// `dragging` from a session that is over. The next drag, from anywhere, must not be able to
    /// pick it up: crossing the abandoned subsection would otherwise have it accept, draw a caret,
    /// and on release move **its own stale entity** and write that to the household document. A
    /// silent wrong-tile reorder, from a gesture aimed at a different tile entirely.
    @Test func aStaleDragFromAnAbandonedSessionIsRefused() {
        let abandoned = TileDragState()
        lift("light.a", in: abandoned)      // …and the finger comes up over nothing.

        let live = TileDragState()
        lift("light.c", in: live)           // a later, unrelated drag

        #expect(delegate(abandoned, target: "light.b").accepts == false)
    }

    /// And the refusal cleans up after itself. A session that has demonstrably ended is proof the
    /// state is dead, so the first delegate to notice discards it rather than leaving it to be
    /// re-examined on every subsequent drag.
    @Test func refusingAStaleDragAlsoDiscardsIt() {
        let abandoned = TileDragState()
        lift("light.a", in: abandoned)
        let live = TileDragState()
        lift("light.c", in: live)

        _ = delegate(abandoned, target: "light.b").accepts
        #expect(abandoned.dragging == nil)
    }

    /// The stale subsection draws nothing either — no caret advertising a drop that would move the
    /// wrong tile.
    @Test func aStaleSubsectionDrawsNothingWhenCrossed() {
        let abandoned = TileDragState()
        lift("light.a", in: abandoned)
        let live = TileDragState()
        lift("light.c", in: live)

        delegate(abandoned, target: "light.b").entered()
        #expect(abandoned.target == nil)
        #expect(abandoned.isOver == false)
    }

    /// The write path, which is where the damage would have been done: releasing over the abandoned
    /// subsection moves nothing and writes nothing.
    /// The stale entity and target are chosen so the move would be a *real* one — `light.c` before
    /// `light.a` reorders the room. A pairing whose move happens to be a no-op would pass this test
    /// against the broken code, on the `moved != visibleIds` guard, and prove nothing.
    @Test func droppingOnAStaleSubsectionWritesNothing() {
        let abandoned = TileDragState()
        lift("light.c", in: abandoned)
        let live = TileDragState()
        lift("light.b", in: live)

        #expect(TileOrder.moving("light.c", before: "light.a", in: ids) != ids)   // it would write
        #expect(delegate(abandoned, target: "light.a").drop() == false)
    }

    /// The other side of the same line: a *live* session's own state is not mistaken for stale —
    /// even with an older, abandoned session sitting nearby and demonstrably discarded, and however
    /// far the live drag's finger has strayed. Without this the fix for straying would be undone.
    ///
    /// Two sessions, not one: the abandoned lift comes first, so `live` is the *second* — proof that
    /// currency is decided against `TileDragSession.current` rather than against a state that merely
    /// looks live in isolation. `theOriginSubsectionStillAcceptsAfterAStray` covers the one-session
    /// case; this is the case beside it, where a second, superseded session exists and must not drag
    /// the live one down with it.
    @Test func theLiveSessionIsNeverMistakenForAStaleOne() async throws {
        let abandoned = TileDragState()
        lift("light.a", in: abandoned)              // an older session, left behind…

        let live = TileDragState()
        lift("light.c", in: live)                   // …a second, later lift, which supersedes it
        #expect(delegate(abandoned, target: "light.b").accepts == false)   // now stale, discarded

        let overB = delegate(live, target: "light.b")

        overB.entered()
        overB.exited()
        try await awaitHandoffTimer()

        #expect(overB.accepts)
    }

    // MARK: - The end position

    /// Entering the trailing drop cell means "after everything", which is a nil target plus the flag
    /// the caret is drawn from.
    @Test func enteringTheEndCellMarksTheEndRatherThanATile() {
        let drag = TileDragState()
        lift("light.a", in: drag)
        let end = delegate(drag, target: nil, isEnd: true)

        end.entered()
        #expect(drag.targetIsEnd)
        #expect(drag.target == nil)
        #expect(drag.isOver)
    }

    /// **Dropping on the end cell appends.** Without this the last position in a subsection is
    /// unreachable in one gesture: a caret on a tile's leading edge only ever means "before this
    /// one", so dropping on the last tile puts you second to last.
    @Test func droppingOnTheEndCellPutsTheTileLast() {
        let drag = TileDragState()
        lift("light.a", in: drag)
        drag.entered()
        let end = delegate(drag, target: nil, isEnd: true)

        #expect(end.drop())
        #expect(TileOrder.moving("light.a", before: nil, in: ids) == ["light.b", "light.c", "light.a"])
    }

    /// Leaving the end cell is governed by `targetIsEnd`, not by a target id it does not have — the
    /// `isEnd` half of the same stale-exit guard.
    @Test func leavingTheEndCellEndsTheDrawingItStarted() async throws {
        let drag = TileDragState()
        lift("light.a", in: drag)
        let end = delegate(drag, target: nil, isEnd: true)

        end.entered()
        end.exited()
        try await awaitHandoffTimer()

        #expect(drag.targetIsEnd == false)
        #expect(drag.isOver == false)
        // Still droppable: straying off the end cell is a stray like any other.
        #expect(end.accepts)
    }

    /// A tile dropped where it already was must not write — a no-op write churns the shared record's
    /// version, which every other phone in the household reads as somebody rearranging the room.
    @Test func droppingATileWhereItAlreadyWasWritesNothing() {
        let drag = TileDragState()
        lift("light.c", in: drag)
        drag.entered()
        // "before nothing" for the tile that is already last.
        let end = delegate(drag, target: nil, isEnd: true)
        #expect(end.drop() == false)
    }
}
