import SwiftUI
import HavenCore
struct CoverModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @State private var dragPercent: Double?      // non-nil only while dragging

    var body: some View {
        let e = store.state(entityId); let s = e.map(CoverState.init)
        let accent = HavenColor.domain(.cover)
        let live = Double(s?.positionPercent ?? 0)
        // `isOpen` reads `false` for an `unavailable` state string exactly as it would for a cover
        // that is genuinely closed, so this header claimed "Closed" about a blind Home Assistant
        // cannot reach. `unavailable` and `unknown` are read apart because only the former cannot
        // be commanded — `HomeStore.openCloseCover` makes the same distinction, and the toggle has
        // to agree with it or it flips and springs back having sent nothing.
        let unavailable = e?.state == "unavailable"
        let unknown = e?.state == "unknown"
        VStack(spacing: 12) {
            ModalHeader(systemImage: IconMap.symbol(domain: .cover, deviceClass: e?.deviceClass),
                        title: store.displayName(of: entityId),
                        subtitle: unknown ? "Unknown" : ((s?.isOpen ?? false) ? "Open" : "Closed"),
                        accent: accent, unavailable: unavailable,
                        toggle: Binding(get: { s?.isOpen ?? false },
                                        set: { _ in store.openCloseCover(entityId) }))
            if s?.supportsPosition ?? false {
                FacetCard(title: "Position") {
                    // Pinned after an adjustment — conservatively, not necessarily.
                    //
                    // The pin was added when `setCoverPosition` was fire-and-forget: with no write
                    // into `states`, clearing would have left `accessibilityValue` (and each next
                    // swipe's starting point) stuck on the stale pre-swipe reading until HA's echo
                    // landed. That is no longer true — it goes through `optimisticState` with
                    // `CoverOptimistic.position`, so `live` catches up synchronously and brightness'
                    // reasoning for clearing would now apply here too.
                    //
                    // Kept because it is what ships, and unpinning is a behaviour change rather
                    // than a tidy-up: it would make this slider start honouring state pushes
                    // between adjustments, which nothing has been asked for and no test covers.
                    // See `CommitSlider`'s doc comment for what clearing buys and pinning costs.
                    CommitSlider(value: live, preview: $dragPercent, in: 0...100,
                                 adjustmentStep: 5, tint: accent, label: "Position",
                                 pinsPreviewAfterAdjusting: true,
                                 valueDescription: { "\(Int($0.rounded()))% open" },
                                 onCommit: { store.setCoverPosition(entityId, percent: Int($0.rounded())) })
                }
            }
            FacetCard { HStack(spacing: 10) {
                Button("Open") { store.openCover(entityId) }.frame(maxWidth: .infinity)
                Button("Stop") { store.stopCover(entityId) }.frame(maxWidth: .infinity)
                Button("Close") { store.closeCover(entityId) }.frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).tint(accent) }
        }
        .onChange(of: s?.isOpen ?? false) { _, _ in dragPercent = nil }
    }
}
