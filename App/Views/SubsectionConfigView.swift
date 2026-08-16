import SwiftUI
import HavenCore

/// The decision `SubsectionConfigView`'s Done button and swipe-to-dismiss both need answered: what
/// changed, and what `HomeStore.applySubsectionConfig` should be told to write for it.
///
/// **Extracted from the view because a `private` computed property on a `View` cannot be reached by
/// anything outside that view's own `body`.** `spanEdit`/`modeEdit`/`hasChanges` used to live there,
/// unreachably, which is how the opened-but-untouched span bug (see `SubsectionConfigView
/// .seededSpan`) escaped both suites the first time and needed an advisor pass to catch by
/// inspection rather than a red test. Same rules, same comments, just a value a test can construct
/// and call directly now.
struct SubsectionConfigEdit: Equatable {
    /// Whether the sheet's Size card is on screen at all — `kind.availableSpans.count > 1`. A kind
    /// with one size has no card, so it never has a span to write, whatever the draft holds — the
    /// `TileConfigView.sizeEdit`-equivalent guard this sheet also needs.
    let spanIsEditable: Bool
    /// The chosen size, or `nil` for "Follow" — the draft's own representation of "go back to
    /// tracking the other surface", picked because neither `seededSpan` nor `storedSpan` can ever
    /// hold it themselves (see below): both are concrete `TileSpan`s. A draft never confuses "no size
    /// chosen yet" with "Follow chosen", because there is no third state — the sheet always seeds a
    /// concrete `span` from `Subsections.resolvedSpan` before a user can touch anything.
    let draftSpan: TileSpan?
    /// What `draftSpan` was seeded to when the sheet opened — **not** what `subsectionSpan(kind, on:
    /// surface)` returns.
    ///
    /// The two disagree by design, and comparing against the stored value directly is exactly the
    /// regression this type exists to keep out: `subsectionSpan` is `nil` for any surface the
    /// household has not sized *directly*, but under decision 10's own-then-other-then-default
    /// fallback that does not mean unsized — a camera opened in room detail before room detail has
    /// ever been sized for itself is currently rendering whatever the floor chose, and its seed is
    /// that resolved value, not `nil`. Comparing `draftSpan` against `nil` would make every
    /// untouched sheet on a *following* surface look edited, and closing it would write the followed
    /// value as an explicit choice — silently ending the following relationship nobody asked to end,
    /// and, for an unconfigured kind on either surface, churning the shared record's version on a
    /// mere open-and-close. Comparing against what was actually seeded makes "opened and closed" a
    /// no-op regardless of whether, or through what path, a value was already showing.
    let seededSpan: TileSpan
    /// This surface's own explicit span, straight from `subsectionSpan(kind, on: surface)` — `nil`
    /// when the surface is already following. Distinct from `seededSpan`, which is always concrete:
    /// this is what decides whether choosing Follow has anything to clear at all.
    let storedSpan: TileSpan?
    let draftMode: SubsectionMode?
    let storedMode: SubsectionMode?

    /// What to write for span, or `nil` for "the sheet's span control was untouched".
    ///
    /// Unlike `TileConfigView.sizeEdit`, a value *changed to* something matching this surface's
    /// default is still written explicitly rather than collapsed to `nil` — there is no default
    /// *chip* to choose here, only the sizes `kind.availableSpans` offers. Decision 10 gave this
    /// sheet a single surface to test "is this the default" against, unlike its predecessor, but
    /// collapsing was not reinstated even so: doing it well would mean distinguishing "the household
    /// picked this surface's own default on purpose" from "the household picked whatever this
    /// surface happens to be following right now", and only the write path knows which, not this
    /// comparison. Writing explicitly either way is the simpler, correct answer.
    ///
    /// `draftSpan == nil` is Follow, handled first and separately: it is never compared against
    /// `seededSpan` (a concrete span can equal `nil` from neither direction), and it clears rather
    /// than writes — `.some(nil)`, not `.some(draftSpan)`. It only does that when there is something
    /// to clear: `storedSpan == nil` means the surface is already following, so reselecting Follow
    /// there is a no-op, the same as picking a mode that already matches what is stored.
    var spanEdit: TileSpan?? {
        guard spanIsEditable else { return nil }
        guard let draftSpan else {
            return storedSpan == nil ? nil : .some(nil)
        }
        guard draftSpan != seededSpan else { return nil }
        return .some(draftSpan)
    }

    /// What to write for mode, or `nil` for "untouched". `nil` is also a value the draft can hold —
    /// "Household default", chosen deliberately — so this only reports "no edit" when the draft and
    /// the stored value already agree, never merely because the draft holds `nil`.
    var modeEdit: SubsectionMode?? {
        guard draftMode != storedMode else { return nil }
        return .some(draftMode)
    }

    var hasChanges: Bool { spanEdit != nil || modeEdit != nil }
}

/// One subsection kind's size and display mode — reached from its heading in configuration mode.
///
/// **Carries a kind and the surface it was opened from, no room.** Mode is still household-wide on
/// the kind alone (see `DashboardDocument.subsectionMode`) — a sheet opened from the Lights of one
/// room edits the same mode as one opened from another room's Lights. Size is not: decision 10 made
/// it per-surface, the same shape decision 9 gave tile order, so this sheet edits **the size of the
/// surface it was opened from, and only that surface** — see
/// `Navigation.Presentation.subsectionConfig`. **No surface picker** — decision 10 is explicit that
/// the sheet does not grow one; "configured where it is seen" is meant literally.
///
/// **Deferred-save, exactly as `TileConfigView`**: every control edits a draft, and `commit()` on
/// Done — or on a swipe, fire-and-forget — is the only write, so two settings never cost two
/// versions of the shared document.
struct SubsectionConfigView: View {
    let kind: SubsectionKind
    let surface: HavenSurface
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// The chosen size, seeded from what this surface actually renders. A draft, like everything on
    /// this sheet: nothing is written until it closes.
    ///
    /// **Seeded from `Subsections.resolvedSpan`, not from `subsectionSpan(kind, on: surface)`
    /// alone.** The latter is `nil` for any surface the household has not sized directly — which,
    /// under decision 10's own-then-other-then-default fallback, does not mean unsized: a camera
    /// opened in room detail before room detail has ever been sized for itself is currently
    /// rendering whatever the floor chose. Seeding from the resolved value is what makes the picker
    /// agree with the tile behind the sheet.
    @State private var span: TileSpan = TileSpan(columns: 1, rows: 1)
    /// What `span` was seeded to, fed to `SubsectionConfigEdit` as `seededSpan` — see that type's
    /// own doc comment for why this is compared against rather than what is stored, which is the
    /// whole of the reasoning and lives in exactly one place now.
    @State private var seededSpan: TileSpan = TileSpan(columns: 1, rows: 1)
    /// The chosen mode override, or `nil` to keep following the household default. A draft, like
    /// `span`.
    ///
    /// **Seeded only in `onAppear`, with no `seededSpan`-style twin to fall back on.** The span half
    /// of this sheet survives an unseeded `onDisappear` for free: `span` and `seededSpan` both
    /// declare the same default, `TileSpan(columns: 1, rows: 1)`, so if `onAppear` never ran they
    /// are still trivially equal to each other, `spanEdit` sees no change, and nothing is written.
    /// `mode` has no such twin — `edit`'s `storedMode` is read fresh from the document on every
    /// access, not from a seed captured at open — so the only thing standing between an unseeded
    /// `mode` and a spurious write is SwiftUI's own ordering guarantee: **`onDisappear` cannot fire
    /// without `onAppear` having fired first.** If that ever stopped holding, `mode` would still be
    /// sitting at its declared default, `nil`, while `storedMode` could be anything the household
    /// had already chosen; `modeEdit` would see them disagree and write `.some(nil)`, clearing a
    /// mode override for a sheet nobody ever opened.
    @State private var mode: SubsectionMode?
    /// Whether the draft is "Follow" rather than a chosen size — `SubsectionConfigEdit`'s `draftSpan
    /// == nil`. Kept apart from `span` rather than folded into it (`span: TileSpan?`) because
    /// `TileSizePicker`'s chips still need a concrete value to seed from *if* Follow is later backed
    /// out of — see `sizeSelection` below, where tapping a chip clears this flag rather than losing
    /// track of the size that was showing before Follow was chosen.
    @State private var followsOtherSurface = false
    @State private var failure: String?
    /// True once this sheet has written, so a dismissal cannot write a second time.
    @State private var committed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalHeader(systemImage: "slider.horizontal.3", title: kind.displayName,
                        subtitle: "Size and layout",
                        accent: HavenColor.domain(.cover), unavailable: false,
                        accessory: AnyView(ModalDoneButton {
                            Task { if await commit() { dismiss() } }
                        }))
            if let failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(HavenColor.warning)
            }
            // Only where there is a choice — a kind with one rendering (`.other`) shows no card at
            // all, the same rule `TileConfigView` applied per domain. See `SubsectionKind.availableSpans`.
            if kind.availableSpans.count > 1 {
                FacetCard(title: "Size") {
                    VStack(alignment: .leading, spacing: 9) {
                        // Shown only when this surface has its own explicit span to give up — an
                        // already-following surface has nothing to revert, so there is no unchecked
                        // state for the row to offer switching from. The edit type's own
                        // `storedSpan != nil` guard makes a spurious write impossible even if that
                        // ever stopped holding (see `SubsectionConfigEdit.spanEdit`), so this gate is
                        // about what reads sensibly, not about safety.
                        if hasOwnSpan {
                            followRow
                        }
                        TileSizePicker(options: kind.availableSpans, selection: sizeSelection)
                        // Names the surface, because decision 10 made the two independent — a
                        // household resizing a camera here has said nothing about its other surface,
                        // which is the opposite of what this sheet said before decision 10 landed.
                        Text(sizeScopeNote)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            FacetCard(title: "Layout") {
                VStack(alignment: .leading, spacing: 0) {
                    modeOption(householdDefaultLabel, value: nil)
                    modeOption("Scroll", value: .scroll)
                    modeOption("Wrap", value: .wrap)
                }
            }
        }
        .onAppear {
            span = Subsections.resolvedSpan(kind, on: surface, document: store.config.document)
            seededSpan = span
            mode = store.config.document.subsectionMode(kind)
        }
        // Swiping the sheet away commits too, for the reason `TileConfigView.onDisappear` gives at
        // length: there is no Cancel here, and a sheet that has gone has nowhere to put an error.
        .onDisappear {
            guard !committed, hasChanges else { return }
            let spanEdit = spanEdit
            let modeEdit = modeEdit
            committed = true
            Task {
                _ = await store.applySubsectionConfig(kind, span: spanEdit, mode: modeEdit, on: surface)
            }
        }
    }

    /// Which surface this sheet is sizing — named because decision 10 made the two surfaces
    /// independent, the opposite of what this sheet said before.
    private var sizeScopeNote: String {
        switch surface {
        case .overview: return "Size on the dashboard. This subsection's size in the room is set separately."
        case .roomDetail: return "Size in this room. This subsection's size on the dashboard is set separately."
        }
    }

    /// One row of the mode picker: its label, and a checkmark when it is the current draft.
    ///
    /// Rows rather than a segmented control, because "Household default (Scroll)" is a phrase, not a
    /// word, and a segmented control's three cells cannot give one of them the room a phrase needs
    /// without starving the other two. `tapWithoutDrag`, not `Button`, for the reason every other
    /// picker row in this app's sheets already gives: in a sheet these fire on the lift at the end
    /// of a scroll.
    private func modeOption(_ label: String, value: SubsectionMode?) -> some View {
        HStack {
            Text(label).font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 8)
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(HavenColor.domain(.cover))
                .opacity(mode == value ? 1 : 0)
        }
        .padding(.vertical, 7)
        .tapWithoutDrag { mode = value }
    }

    /// What "Household default" currently resolves to, spelled out so choosing it is an informed
    /// choice rather than a guess — the fallback chain itself is invisible on screen otherwise.
    private var householdDefaultLabel: String {
        let resolved = store.config.document.displayMode ?? .scroll
        return "Household default (\(resolved == .scroll ? "Scroll" : "Wrap"))"
    }

    /// Whether this surface currently carries its own explicit span — straight from the document,
    /// not from the draft, so tapping `followRow` cannot make it disappear mid-sheet: it reflects
    /// what is *stored*, and nothing here writes until commit. Gates `followRow`'s visibility and
    /// doubles as `edit`'s `storedSpan`.
    private var hasOwnSpan: Bool {
        store.config.document.subsectionSpan(kind, on: surface) != nil
    }

    /// Follow-up 4's row: returns this surface to tracking the other one, mirroring
    /// `householdDefaultLabel`'s "spell out what it resolves to" — see `followLabel`.
    private var followRow: some View {
        HStack {
            Text(followLabel).font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 8)
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(HavenColor.domain(.cover))
                .opacity(followsOtherSurface ? 1 : 0)
        }
        .padding(.vertical, 7)
        .tapWithoutDrag { followsOtherSurface = true }
    }

    /// What Follow currently resolves to. Computed by actually clearing this surface's span from a
    /// scratch copy of the document and resolving through the same chain the tile behind this sheet
    /// reads — not by resolving the *other* surface directly, which would answer the wrong question
    /// whenever that surface itself has nothing stored: its own resolution falls back to *this*
    /// surface first (see `Subsections.resolvedSpan`), so it would show the very value being given
    /// up. Clearing first and resolving after is what the commit actually does; this just does it a
    /// step early, on a document that never leaves this property.
    private var followLabel: String {
        let cleared = store.config.document.settingSubsectionSpan(nil, kind: kind, on: surface)
        let resolved = Subsections.resolvedSpan(kind, on: surface, document: cleared)
        let target = surface == .overview ? "the room" : "the dashboard"
        return "Follow \(target) (\(resolved.columns)×\(resolved.rows))"
    }

    /// `TileSizePicker`'s binding. Reads as `nil` — no chip checked — whenever Follow is the current
    /// draft, so the row above and a chip below are never checked at once; writes always mean a chip
    /// was tapped, which is a size chosen, so it clears `followsOtherSurface` the same motion.
    private var sizeSelection: Binding<TileSpan?> {
        Binding(
            get: { followsOtherSurface ? nil : span },
            set: { chosen in
                guard let chosen else { return }
                span = chosen
                followsOtherSurface = false
            })
    }

    /// The one decision this sheet's Done and swipe-to-dismiss both need — see `SubsectionConfigEdit`,
    /// the testable type this delegates to. Built fresh on every access rather than cached in
    /// `@State`: it is a pure function of state this view already owns (`span`, `seededSpan`,
    /// `mode`) plus one document read, cheap enough that recomputing it is simpler than keeping a
    /// sixth piece of state in step with the other five.
    private var edit: SubsectionConfigEdit {
        SubsectionConfigEdit(spanIsEditable: kind.availableSpans.count > 1,
                             draftSpan: followsOtherSurface ? nil : span,
                             seededSpan: seededSpan,
                             storedSpan: store.config.document.subsectionSpan(kind, on: surface),
                             draftMode: mode,
                             storedMode: store.config.document.subsectionMode(kind))
    }

    private var spanEdit: TileSpan?? { edit.spanEdit }
    private var modeEdit: SubsectionMode?? { edit.modeEdit }
    private var hasChanges: Bool { edit.hasChanges }

    /// The one write this sheet performs. Returns whether the sheet may close. See
    /// `TileConfigView.commit` — identical shape, one fewer setting.
    private func commit() async -> Bool {
        guard !committed else { return true }
        guard hasChanges else { committed = true; return true }
        committed = true
        switch await store.applySubsectionConfig(kind, span: spanEdit, mode: modeEdit, on: surface) {
        case .written, .unchanged:
            return true
        case .notAuthorized:
            failure = "Only Home Assistant admins can change the household dashboard."
        case .failed:
            failure = "Couldn't save that. Check your connection and try again."
        }
        committed = false
        return false
    }
}

#if DEBUG
private struct SubsectionConfigPreviewHost: View {
    let kind: SubsectionKind
    let surface: HavenSurface
    @State private var store: HomeStore

    init(kind: SubsectionKind, surface: HavenSurface = .overview,
        storedSpan: (TileSpan, HavenSurface)? = nil, storedMode: SubsectionMode? = nil) {
        self.kind = kind
        self.surface = surface
        let store = HomeStore()
        var document = DashboardDocument()
        if let (span, spanSurface) = storedSpan {
            document = document.settingSubsectionSpan(span, kind: kind, on: spanSurface)
        }
        if let storedMode { document = document.settingSubsectionMode(storedMode, kind: kind) }
        store.config.seedForTesting(document)
        _store = State(initialValue: store)
    }

    var body: some View {
        SubsectionConfigView(kind: kind, surface: surface).padding(16).environment(store)
    }
}

#Preview("Subsection config — unconfigured, dashboard") {
    SubsectionConfigPreviewHost(kind: .lights)
}
/// **A kind with several sizes on offer**, unlike lights above — the size card is absent there and
/// present here, which is the only thing on screen that shows the card is conditional at all.
#Preview("Subsection config — cameras, span chosen on this surface") {
    SubsectionConfigPreviewHost(kind: .cameras, surface: .overview,
                                storedSpan: (TileSpan(columns: 2, rows: 2), .overview))
}
/// **Decision 10's whole reason for existing.** Room detail has never been sized for itself — only
/// the dashboard has — so this sheet, opened *in room detail*, must show what room detail is
/// actually rendering: the dashboard's `2x2`, not room detail's own unrelated built-in default
/// (`4x2`). If this preview ever shows `4x2` selected, the seeding is reading the wrong thing.
#Preview("Subsection config — cameras, following the other surface") {
    SubsectionConfigPreviewHost(kind: .cameras, surface: .roomDetail,
                                storedSpan: (TileSpan(columns: 2, rows: 2), .overview))
}
/// **A kind whose mode already overrides the household default** — the checkmark sits on Wrap, not
/// on Household default, and that row's label still names what the default currently is.
#Preview("Subsection config — mode overridden") {
    SubsectionConfigPreviewHost(kind: .shades, storedMode: .wrap)
}
/// **`.other` spans one size** — no Size card at all, the same omission `TileConfigView` makes for a
/// light.
#Preview("Subsection config — other, no size choice") {
    SubsectionConfigPreviewHost(kind: .other)
}
#endif
