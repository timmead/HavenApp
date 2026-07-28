import SwiftUI
import HavenCore
struct LightTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    var body: some View {
        let e = store.state(entityId)
        let s = e.map(LightState.init)
        let on = s?.isOn ?? false
        let accent = HavenColor.domain(.light)
        let unavailable = e?.isUnavailable ?? false
        GlassTile(active: on, accent: accent, unavailable: unavailable) {
            HStack(alignment: .top, spacing: 0) {
                // `on` already reads `false` for an `unavailable` state string, so these would
                // resolve to `.secondary` there regardless — but incidentally, via
                // `LightState.isOn`'s definition, rather than because anything decided it.
                TileLabel(symbol: IconMap.symbol(domain: .light, deviceClass: nil),
                          name: TileName.of(entityId, e),
                          icon: on ? .accent : .secondary,
                          title: on ? .primary : .secondary,
                          accent: accent, unavailable: unavailable)
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
        .onLongPressGesture(minimumDuration: 0.35) { navigation.presentedEntityId = entityId }
        // One combined element per tile, not five fragments — a VoiceOver user hears
        // "Kitchen light, on, 60% brightness" once, not the icon/name/level bar separately.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.map { AccessibilitySummary.light(TileName.of(entityId, e), $0) } ?? TileName.of(entityId, e))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open controls") { navigation.presentedEntityId = entityId }
    }
}
