import SwiftUI
import HavenCore
struct LightTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId)
        let s = e.map(LightState.init)
        let on = s?.isOn ?? false
        let accent = HavenColor.domain(.light)
        GlassTile(active: on, accent: accent) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Image(systemName: IconMap.symbol(domain: .light, deviceClass: nil))
                        .font(.system(size: 20)).foregroundStyle(on ? accent : .secondary).symbolRenderingMode(.hierarchical)
                    Spacer(minLength: 2)
                    Text(TileName.of(entityId, e)).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(on ? .primary : .secondary)
                }
                // Shown only while the light is on, unchanged: an off light has no brightness, and
                // `LightModal` makes the same call ("don't show a stale percentage"). So the
                // volume tiles' turn-it-on-when-you-drag case cannot arise here — there is nothing
                // to drag until the light is already on.
                //
                // The mirror-image hazard is the real one, and `minimum: 1` is what prevents it:
                // dragging to 0 would ask Home Assistant to turn the light off, and the control
                // would vanish from under the finger mid-gesture. Turning a light off is the tap
                // this tile already has, an inch away.
                if on, let pct = s?.brightnessPercent {
                    Spacer(minLength: 6)
                    PipSlider(percent: pct, accent: accent, minimum: 1,
                              label: "Brightness",
                              onCommit: { store.setBrightness(entityId, percent: $0) },
                              onTap: { store.toggle(entityId) })
                        .padding(.vertical, 2)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.toggle(entityId) }
        .onLongPressGesture(minimumDuration: 0.35) { store.presented = entityId }
        // One combined element per tile, not five fragments — a VoiceOver user hears
        // "Kitchen light, on, 60% brightness" once, not the icon/name/level bar separately.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.map { AccessibilitySummary.light(TileName.of(entityId, e), $0) } ?? TileName.of(entityId, e))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open controls") { store.presented = entityId }
    }
}
