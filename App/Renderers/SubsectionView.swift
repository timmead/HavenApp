import SwiftUI
import HavenCore

/// How much room a surface gives a subsection's heading.
///
/// **A density axis, not a second construct** (design decision 2): the floor view and room detail
/// render the *same* container, and the only thing they disagree about is how loud its heading is.
/// A floor card already carries the room's name at 17pt bold, so a kind label there has to read as a
/// sub-label of it; in room detail the kind label is the only heading on screen.
enum SubsectionDensity { case regular, compact }

/// One room's devices of one kind — Lights, Shades, Cameras, and the rest — as a heading and a row
/// or grid of tiles.
///
/// **This is the whole of what a room renders now**, on both surfaces: `Subsections.resolve` decides
/// which of these exist, what is in each and how big and how laid out, and this draws that decision.
/// Nothing here re-derives any of it — the fields of `RoomSubsection` are the entire contract, which
/// is what makes "a tile is the wrong size" a question with exactly one place to look.
///
/// Not wired into either surface yet: Task 5 does that. Until then the only thing that constructs
/// one is `TileGallery`, which is also the only verification this view has — see that file.
struct SubsectionView: View {
    /// The room this belongs to. Needed for the roll-up, which is computed per *room* (a bulk action
    /// names an area), not per subsection.
    let room: RoomSection
    let subsection: RoomSubsection
    /// Which surface this is drawn on.
    ///
    /// **Explicit, and not derived from `density`.** The two do travel together — the floor is
    /// compact and `.overview`, room detail is regular and `.roomDetail` — but they are different
    /// facts: density is how loud the heading is, and the surface is what a tile's configuration
    /// sheet removes it *from*. Deriving one from the other would make a styling choice silently
    /// decide a membership one.
    let surface: HavenSurface
    let density: SubsectionDensity
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation

    /// **One grid value, used by both modes.** The wrap body lays out with it and the scroll body
    /// asks it how wide a tile is, so the two cannot divide the width differently — which is the
    /// spec's promise that changing the display mode changes a subsection's *arrangement* and never
    /// a tile's width.
    ///
    /// Constructed with no arguments on purpose: `RoomGrid`'s own defaults are 4 columns at 9 points,
    /// and restating them here would be a second place for them to be changed. The scroll body reads
    /// `Self.grid.spacing` for its own gaps for the same reason.
    private static let grid = RoomGrid()

    /// How wide this container was drawn, which is what the scroll body's tiles are sized against.
    ///
    /// `onGeometryChange` rather than a `GeometryReader`: both surfaces put this inside a vertical
    /// `ScrollView`, and a reader has no height of its own to offer — it would take whatever it was
    /// proposed and push the room's layout around. Zero until the first layout pass, which
    /// `RoomGrid.columnWidth` already floors at zero rather than producing a negative width.
    @State private var containerWidth: CGFloat = 0

    /// **Configuration mode forces wrap** — design decision 8. Rearranging happens on a grid, never
    /// in a scroll row, so the drag machinery Task 5 moves in here only ever composes with
    /// `RoomGrid`. Derived rather than stored: leaving configuration mode restores the household's
    /// configured mode with nothing to remember to undo.
    private var mode: SubsectionMode {
        navigation.isConfiguring ? .wrap : subsection.mode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: headingGap) {
            header
            switch mode {
            case .scroll: scrollBody
            case .wrap: wrapBody
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
    }

    // MARK: - Heading

    /// The kind's name and its roll-up — and, while configuring, the way into its settings.
    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            // Only the *name* is wrapped for navigation — **not** the roll-up beside it, which is a
            // `Button` of its own. `RoomSectionView` keeps its roll-up row outside the room
            // heading's button for exactly this reason: a button inside another button's label has
            // ambiguous hit testing, and whichever way it happens to resolve, one of the two
            // meanings is silently unreachable. "All Off" that opens a settings sheet is a bulk
            // action that does not happen and says nothing about not happening.
            if navigation.isConfiguring {
                Button { navigation.presented = .subsectionConfig(kind: subsection.kind) } label: { title }
                    .buttonStyle(.plain)
                    .accessibilityHint("Configures this subsection's tile size and layout")
            } else {
                title
            }
            if let rollup { rollupRow(rollup) }
            Spacer(minLength: 0)
        }
    }

    /// The kind's name — the tap target in configuration mode, a plain label otherwise.
    ///
    /// One property wrapped by both branches rather than a heading built in each, for the reason
    /// `RoomSectionView.heading` records: two branches that build a heading each are two headings
    /// that can drift into looking like different things.
    private var title: some View {
        Text(subsection.kind.displayName)
            .font(titleFont)
            .foregroundStyle(density == .compact ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .contentShape(Rectangle())
    }

    /// Room detail's heading is the only one on its screen; the floor card's sits under a 17pt bold
    /// room name and has to read as subordinate to it.
    private var titleFont: Font {
        switch density {
        case .regular: return .system(size: 14, weight: .bold)
        case .compact: return .system(size: 12.5, weight: .semibold)
        }
    }

    /// The gap between the heading and the tiles — tighter on the floor, where a room card is a
    /// glance and every point of height is a room further down the screen.
    private var headingGap: CGFloat {
        switch density {
        case .regular: return 10
        case .compact: return 6
        }
    }

    /// Which roll-up belongs beside this heading, if any.
    ///
    /// Exhaustive with no `default`, so a kind added tomorrow has to say here whether it has a bulk
    /// action rather than silently inheriting "no".
    private var rollupKind: Rollup.Kind? {
        switch subsection.kind {
        case .lights: return .lights
        case .shades: return .covers
        case .climate, .media, .cameras, .other, .sensors: return nil
        }
    }

    /// The room's roll-up for this kind. Recomputed from the room rather than passed in: it counts
    /// live states, and a count that went stale would be a button claiming to act on lights that are
    /// already off.
    private var rollup: Rollup? {
        guard let rollupKind else { return nil }
        return store.rollups(room).first { $0.kind == rollupKind }
    }

    /// A single room-level bulk action, e.g. "3/5 · All Off" or "2/2 · Close All".
    ///
    /// **`RoomSectionView.rollupRow`'s implementation, moved to where the design puts it** (decision
    /// 6): a roll-up belongs to the Lights, not to the room heading above them. The floor version
    /// rather than room detail's, because it is the one that says the count and the failure in a
    /// fixed amount of space — room detail's spelt-out "3 of 5 on" with a right-aligned button
    /// assumed a heading with a whole row to itself, which a subsection heading is not.
    ///
    /// Both originals are still in place; Task 5 deletes them as it rewires the two surfaces, so the
    /// duplication this collapses lives on for exactly one commit.
    @ViewBuilder
    private func rollupRow(_ rollup: Rollup) -> some View {
        let accent = HavenColor.domain(rollup.kind == .lights ? .light : .cover)
        let hasActive = rollup.activeCount > 0
        HStack(spacing: 6) {
            Image(systemName: rollup.kind == .lights ? "lightbulb.fill" : "blinds.vertical.closed")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(hasActive ? accent : .secondary)
            Text("\(rollup.activeCount)/\(rollup.total)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Button(rollup.kind == .lights ? "All Off" : "Close All") {
                if rollup.kind == .lights { store.allOff(rollup, in: room.areaId) }
                else { store.closeAll(rollup, in: room.areaId) }
            }
            .font(.system(size: 12, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(hasActive ? accent : .secondary)
            .disabled(!hasActive)
            // Named rather than silent: a bulk action that half-fails used to revert the failed
            // rows with no explanation at all, which reads as the app ignoring the tap.
            //
            // Gated on `hasActive` too, not just `failures > 0`: this is the only way a stale count
            // ever clears without another bulk action. If the user fixes the failures by hand (e.g.
            // manually locks the one door that didn't respond), `activeCount` drops to 0, the button
            // disables, and the room genuinely has nothing left to complain about — but nothing
            // re-runs `recordBulkFailures` to zero the stored count, so without this gate the label
            // would go on accusing the room of a failure that no longer exists.
            let failures = store.bulkFailureCount(for: rollup.kind, in: room.areaId)
            if failures > 0 && hasActive {
                Text("\(failures) didn't respond")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HavenColor.warning)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(HavenColor.glassFill))
    }

    // MARK: - Bodies

    /// One row, scrolled sideways. **Every tile is framed to the width it would have in the grid**,
    /// so a light is exactly as wide in both modes and only its neighbours move.
    ///
    /// **Width is a guarantee; height is not, and the difference is worth being exact about.** Both
    /// modes get their widths from the same `RoomGrid` value, so they cannot disagree. Heights do not
    /// work that way: `RoomGrid` measures its subviews to find a row height and an `HStack` has no
    /// `Subviews` to measure, so this cannot reproduce that number and does not claim to — see
    /// `tileHeight`.
    ///
    /// `.top` alignment, deliberately: an `HStack` centres members of unequal height, and the grid
    /// places every tile at its cell's top-leading corner. Where two tiles do differ, they should
    /// differ downwards in both modes rather than one row being centred and the other not.
    ///
    /// Not lazy, for the reason `RoomGrid` documents at greater length: this is a *room's* worth of
    /// tiles of one kind, which is a handful.
    private var scrollBody: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Self.grid.spacing) {
                ForEach(subsection.refs) { ref in
                    // A ref whose primary has vanished draws nothing, exactly as it does in the
                    // grid — the resolver already skips those, so this is belt and braces.
                    if let id = ref.primaryEntityId {
                        DeviceTileView(entityId: id, surface: surface, span: subsection.span)
                            .frame(width: Self.grid.width(for: subsection.span,
                                                          inContainerOfWidth: containerWidth),
                                   height: tileHeight)
                    }
                }
            }
        }
    }

    /// The height a scrolled tile is given, or `nil` to let each tile take its own ideal height.
    ///
    /// **Multi-row is the case with a guarantee.** A subsection sizes all its tiles alike, so a
    /// subsection whose span is more than one row has nothing single-row in it — and `RoomGrid`'s
    /// `rowHeight` measures *only* single-row subviews, so in wrap mode it finds none and falls back
    /// to `fallbackRowHeight`. `unmeasuredHeight(for:)` is that same fallback, arrived at by the same
    /// arithmetic, so the two modes give a camera identical height. It also stops an image's aspect
    /// ratio deciding how tall a camera row is, which is the defect `CameraTile` records.
    ///
    /// **Single-row is a practical coincidence, not a mechanism, and it is stated that way on
    /// purpose.** `RoomGrid` takes the tallest single-row subview's ideal height and gives it to
    /// every tile in the row; an `HStack` has nothing to measure and can only give each tile the
    /// ideal height it asks for. What makes the two agree in practice is that a subsection's tiles
    /// are the same renderer at the same span, so their ideal heights coincide — *not* any levelling
    /// this view performs. A `.frame(maxHeight: .infinity)` was tried here and removed: against a
    /// finite proposal it makes every tile greedy rather than equal, which is a different bug wearing
    /// the right comment.
    ///
    /// So: **if a single-row scroll tile is a different height from its wrap twin, the cause is here
    /// and not the container width** — the widths cannot disagree.
    private var tileHeight: CGFloat? {
        subsection.span.rows > 1 ? Self.grid.unmeasuredHeight(for: subsection.span) : nil
    }

    /// The wrapping grid — the existing `RoomGrid`, unchanged, which is also the mode configuration
    /// forces so that the drag machinery has a grid to work on.
    private var wrapBody: some View {
        Self.grid {
            ForEach(subsection.refs) { ref in
                if let id = ref.primaryEntityId {
                    DeviceTileView(entityId: id, surface: surface, span: subsection.span)
                        .tileSpan(subsection.span)
                }
            }
        }
    }
}
