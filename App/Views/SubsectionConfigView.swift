import SwiftUI
import HavenCore

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
    /// What `span` was seeded to — see `spanEdit`, which dirty-checks against this rather than
    /// against what is stored.
    ///
    /// **Exists to close an opened-but-untouched bug, precisely named because "unopened" is not a
    /// state this view can reach: `onDisappear` cannot fire without `onAppear` firing first, so the
    /// failure was never about a sheet nobody opened.** The bug was a comparison across an
    /// optional/non-optional asymmetry: `span` is a non-optional `TileSpan` — it always holds a
    /// concrete value, because the picker always has something selected — while
    /// `subsectionSpan(kind, on:)` is `TileSpan?`, `nil` for any surface the household has never set
    /// directly. `spanEdit` used to compare the two directly, so an unset surface's seeded value
    /// always disagreed with the stored `nil`, and a sheet opened and closed with nothing touched
    /// dirty-checked as edited. Seeding `seededSpan` from the same value `span` gets and comparing
    /// draft-to-seed rather than draft-to-stored closes both halves of that: the unset-surface case
    /// stops writing on a mere open-and-close (no more spurious churn of the shared record's
    /// version), and — since decision 10 — opening a sheet whose surface is *following* the other
    /// one stops silently locking in that followed value as an explicit choice the instant the sheet
    /// renders, which would otherwise end the following relationship nobody asked to end.
    @State private var seededSpan: TileSpan = TileSpan(columns: 1, rows: 1)
    /// The chosen mode override, or `nil` to keep following the household default. A draft, like
    /// `span`.
    @State private var mode: SubsectionMode?
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
                        TileSizePicker(options: kind.availableSpans, selection: $span)
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

    /// Whether the span differs from what the sheet opened with.
    ///
    /// **Against `seededSpan`, not against `store.config.document.subsectionSpan(kind, on:
    /// surface)`** — see `seededSpan`'s own doc comment for why the two disagree and what comparing
    /// against the stored value directly used to cost.
    ///
    /// Unlike `TileConfigView.sizeEdit`, a value that is *changed to* something matching this
    /// surface's default is still written explicitly rather than collapsed to `nil` — there is no
    /// default *chip* to choose here, only the sizes `kind.availableSpans` offers. Decision 10 gave
    /// this sheet a single surface to test "is this the default" against, unlike its predecessor —
    /// but collapsing was not reinstated even so: doing it well would mean distinguishing "the
    /// household picked this surface's own default on purpose" from "the household picked whatever
    /// this surface happens to be following right now", and only the write path knows which, not
    /// this comparison. Writing explicitly either way is the simpler, correct answer.
    private var spanEdit: TileSpan?? {
        guard kind.availableSpans.count > 1, span != seededSpan else { return nil }
        return .some(span)
    }

    /// Whether the mode differs from what is stored. `nil` is a value here, not "no edit" — it is
    /// "Household default", chosen deliberately — so this reads `mode` against the *stored* override
    /// and only reports "no edit" when the two already agree.
    private var modeEdit: SubsectionMode?? {
        let stored = store.config.document.subsectionMode(kind)
        guard mode != stored else { return nil }
        return .some(mode)
    }

    private var hasChanges: Bool { spanEdit != nil || modeEdit != nil }

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
