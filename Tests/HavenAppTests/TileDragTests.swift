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
@Suite @MainActor struct TileDragTests {

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
        drag.dragging = "light.a"
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
        drag.dragging = "light.a"
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
        drag.dragging = "light.a"
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
        drag.dragging = "light.c"
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
        drag.dragging = "light.a"
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
        drag.dragging = "light.a"
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
        origin.dragging = "light.a"
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

    // MARK: - The end position

    /// Entering the trailing drop cell means "after everything", which is a nil target plus the flag
    /// the caret is drawn from.
    @Test func enteringTheEndCellMarksTheEndRatherThanATile() {
        let drag = TileDragState()
        drag.dragging = "light.a"
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
        drag.dragging = "light.a"
        drag.entered()
        let end = delegate(drag, target: nil, isEnd: true)

        #expect(end.drop())
        #expect(TileOrder.moving("light.a", before: nil, in: ids) == ["light.b", "light.c", "light.a"])
    }

    /// Leaving the end cell is governed by `targetIsEnd`, not by a target id it does not have — the
    /// `isEnd` half of the same stale-exit guard.
    @Test func leavingTheEndCellEndsTheDrawingItStarted() async throws {
        let drag = TileDragState()
        drag.dragging = "light.a"
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
        drag.dragging = "light.c"
        drag.entered()
        // "before nothing" for the tile that is already last.
        let end = delegate(drag, target: nil, isEnd: true)
        #expect(end.drop() == false)
    }
}
