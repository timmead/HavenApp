import SwiftUI
import HavenCore

/// One subsection kind's size and display mode — reached from its heading in configuration mode.
///
/// **Carries only a kind, no room and no surface**, because it edits exactly that: `SubsectionKind`
/// is a household-wide setting (see `DashboardDocument.subsectionSpan`/`subsectionMode`), not a
/// fact about the room the sheet happened to be opened from. A sheet opened from the Lights of one
/// room and one from another room's Lights edit the same two values — see
/// `Navigation.Presentation.subsectionConfig`.
///
/// **Deferred-save, exactly as `TileConfigView`**: every control edits a draft, and `commit()` on
/// Done — or on a swipe, fire-and-forget — is the only write, so two settings never cost two
/// versions of the shared document.
struct SubsectionConfigView: View {
    let kind: SubsectionKind
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// The chosen size, seeded from what is stored or the kind's default. A draft, like everything
    /// on this sheet: nothing is written until it closes.
    ///
    /// **No surface to seed the default against** — this sheet has none — so `.overview` stands in
    /// for it, the same canonical choice `SubsectionView` already makes for the roll-up count when
    /// a surface-free answer is needed. It only affects what the sheet shows *before* a change: a
    /// span the household actually picks is written exactly as picked, for every surface, whichever
    /// heading opened the sheet.
    @State private var span: TileSpan = TileSpan(columns: 1, rows: 1)
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
                        Text("Every tile in \(kind.displayName) renders at this size, on both the dashboard and in the room.")
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
            span = store.config.document.subsectionSpan(kind) ?? kind.defaultSpan(on: .overview)
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
                _ = await store.applySubsectionConfig(kind, span: spanEdit, mode: modeEdit)
            }
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

    /// Whether the span differs from what is stored. Unlike `TileConfigView.sizeEdit`, a value that
    /// happens to match today's default is still written explicitly — there is no default *chip* to
    /// choose here, only the sizes `kind.availableSpans` actually offers, and this sheet has no
    /// single surface to test "is this the default" against (`SubsectionKind.defaultSpan(on:)`
    /// disagrees between the two for cameras and media). Collapsing to `nil` would need one anyway,
    /// so it is not attempted — see the report for what that costs.
    private var spanEdit: TileSpan?? {
        let stored = store.config.document.subsectionSpan(kind)
        guard span != stored else { return nil }
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
        switch await store.applySubsectionConfig(kind, span: spanEdit, mode: modeEdit) {
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
    @State private var store: HomeStore

    init(kind: SubsectionKind, storedSpan: TileSpan? = nil, storedMode: SubsectionMode? = nil) {
        self.kind = kind
        let store = HomeStore()
        var document = DashboardDocument()
        if let storedSpan { document = document.settingSubsectionSpan(storedSpan, kind: kind) }
        if let storedMode { document = document.settingSubsectionMode(storedMode, kind: kind) }
        store.config.seedForTesting(document)
        _store = State(initialValue: store)
    }

    var body: some View {
        SubsectionConfigView(kind: kind).padding(16).environment(store)
    }
}

#Preview("Subsection config — unconfigured") {
    SubsectionConfigPreviewHost(kind: .lights)
}
/// **A kind with several sizes on offer**, unlike lights above — the size card is absent there and
/// present here, which is the only thing on screen that shows the card is conditional at all.
#Preview("Subsection config — cameras, span chosen") {
    SubsectionConfigPreviewHost(kind: .cameras, storedSpan: TileSpan(columns: 4, rows: 2))
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
