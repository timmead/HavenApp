import SwiftUI
import HavenCore
struct ClimateTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let s = e.map(ClimateState.init)
        let on = s?.isOn ?? false; let accent = HavenColor.domain(.climate)
        GlassTile(active: on, accent: accent) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "thermometer.medium").font(.system(size: 20)).foregroundStyle(accent).symbolRenderingMode(.hierarchical)
                Spacer(minLength: 2)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(s?.targetTemp.map { "\(Int($0))°" } ?? "—").font(.system(size: 24, weight: .bold)).foregroundStyle(accent)
                    Text(s.map { "\($0.hvacMode.capitalized)\($0.fanMode.map { " · fan \($0)" } ?? "")" } ?? "").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle()).onTapGesture { store.presented = entityId }.onLongPressGesture(minimumDuration: 0.35) { store.presented = entityId }
    }
}
