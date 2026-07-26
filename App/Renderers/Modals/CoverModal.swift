import SwiftUI
import HavenCore
struct CoverModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var dragPercent: Double?      // non-nil only while dragging

    var body: some View {
        let e = store.state(entityId); let s = e.map(CoverState.init)
        let accent = HavenColor.domain(.cover)
        let live = Double(s?.positionPercent ?? 0)
        VStack(spacing: 12) {
            ModalHeader(systemImage: IconMap.symbol(domain: .cover, deviceClass: e?.deviceClass), title: TileName.of(entityId, e), subtitle: (s?.isOpen ?? false) ? "Open" : "Closed", accent: accent,
                        toggle: Binding(get: { s?.isOpen ?? false },
                                        set: { _ in store.openCloseCover(entityId) })) { dismiss() }
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
                        dragPercent = nil
                        store.setCoverPosition(entityId, percent: Int(next.rounded()))
                    }
                }
            }
            FacetCard { HStack(spacing: 10) {
                Button("Open") { store.openCover(entityId) }.frame(maxWidth: .infinity)
                Button("Stop") { store.stopCover(entityId) }.frame(maxWidth: .infinity)
                Button("Close") { store.closeCover(entityId) }.frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).tint(accent) }
            Spacer()
        }
        .onChange(of: s?.isOpen ?? false) { _, _ in dragPercent = nil }
    }
}
