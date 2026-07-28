import SwiftUI
import HavenCore
struct SceneTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let accent = HavenColor.domain(.scene)
        let unavailable = e?.isUnavailable ?? false
        GlassTile(active: false, accent: accent, unavailable: unavailable) {
            VStack(alignment: .leading, spacing: 5) {
                // Always tinted `accent` by design, same as `ClimateTile` — scenes have no on/off
                // to gate it, so the unavailable guard has to be added on its own rather than
                // inherited from a state check.
                Image(systemName: IconMap.symbol(domain: Domain.of(entityId), deviceClass: nil)).font(.system(size: 20)).foregroundStyle(unavailable ? .secondary : accent).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2); Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.run(entityId) }.onLongPressGesture(minimumDuration: 0.35) { store.presented = entityId }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AccessibilitySummary.scene(TileName.of(entityId, e)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open controls") { store.presented = entityId }
    }
}
