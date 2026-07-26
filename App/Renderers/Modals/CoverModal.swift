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
            ModalHeader(systemImage: "blinds.horizontal.closed", title: TileName.of(entityId, e), subtitle: (s?.isOpen ?? false) ? "Open" : "Closed", accent: accent,
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
                }
            }
            FacetCard { HStack(spacing: 10) {
                Button("Open") { store.openCover(entityId) }.frame(maxWidth: .infinity)
                Button("Stop") { store.stopCover(entityId) }.frame(maxWidth: .infinity)
                Button("Close") { store.closeCover(entityId) }.frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).tint(accent) }
            Spacer()
        }
    }
}
