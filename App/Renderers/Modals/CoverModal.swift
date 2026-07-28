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
                        title: TileName.of(entityId, e),
                        subtitle: unknown ? "Unknown" : ((s?.isOpen ?? false) ? "Open" : "Closed"),
                        accent: accent, unavailable: unavailable,
                        toggle: Binding(get: { s?.isOpen ?? false },
                                        set: { _ in store.openCloseCover(entityId) }))
            if s?.supportsPosition ?? false {
                FacetCard(title: "Position") {
                    Slider(value: Binding(get: { dragPercent ?? live },
                                          set: { dragPercent = $0 }),
                           in: 0...100,
                           onEditingChanged: { editing in
                               if !editing, let v = dragPercent {
                                   store.setCoverPosition(entityId, percent: Int(v.rounded()))
                                   dragPercent = nil
                               }
                           })
                    .tint(accent)
                    .accessibilityLabel("Position")
                    .accessibilityValue("\(Int((dragPercent ?? live).rounded()))% open")
                    .accessibilityAdjustableAction { direction in
                        let current = dragPercent ?? live
                        let step = 5.0
                        let next = direction == .increment ? min(100, current + step) : max(0, current - step)
                        // Pin to `next`, not `nil` — `setCoverPosition` is fire-and-forget
                        // with no write into `states`, so clearing this would leave
                        // `accessibilityValue` (and each next swipe's `current`) stuck on
                        // the stale pre-swipe reading until HA's echo lands.
                        dragPercent = next
                        store.setCoverPosition(entityId, percent: Int(next.rounded()))
                    }
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
