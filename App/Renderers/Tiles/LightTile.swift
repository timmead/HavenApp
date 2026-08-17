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
        let unavailable = e?.isUnavailable ?? false
        GlassTile(active: on, accent: accent, unavailable: unavailable) {
            // **The bulb is centred on the tile, not on what the slider leaves of it.** Laid out
            // side by side, a dimmable light's glyph sat left of centre and a non-dimmable one's sat
            // in the middle — the same tile appearing to change its mind about where its icon goes.
            // The slider is drawn *over* the face instead, and only the name is inset to clear it.
            StateFace(state: TileState.light(isOn: on, unavailable: unavailable),
                      style: store.stateStyle(of: entityId),
                      name: store.displayName(of: entityId),
                      accent: accent, active: on, unavailable: unavailable,
                      nameHidden: store.labelHidden(of: entityId))
                .overlay(alignment: .trailing) {
                    // Shown only while the light is on, unchanged: an off light has no brightness,
                    // and `LightModal` makes the same call ("don't show a stale percentage"). So the
                    // volume tiles' turn-it-on-when-you-drag case cannot arise here — there is
                    // nothing to drag until the light is already on.
                    //
                    // The mirror-image hazard is the real one, and `minimum: 1` is what prevents it:
                    // dragging to 0 would ask Home Assistant to turn the light off, and the control
                    // would vanish from under the finger mid-gesture. Turning a light off is the tap
                    // this tile already has, an inch away.
                    if on, let pct = s?.brightnessPercent {
                        PipSlider(percent: pct, accent: accent, minimum: 1,
                                  label: "Brightness",
                                  onCommit: { store.setBrightness(entityId, percent: $0) },
                                  onTap: { store.toggle(entityId) })
                            .padding(.top, 2)
                            // Stops above the name rather than running the full height of the
                            // tile, so the label is exactly as wide with a slider as without one —
                            // see `StateFace.nameHeight`.
                            .padding(.bottom, StateFace.nameHeight)
                    }
                }
        }
        .tileInteraction(entityId,
                         label: s.map { AccessibilitySummary.light(store.displayName(of: entityId), $0) }
                             ?? store.displayName(of: entityId)) {
            store.toggle(entityId)
        }
    }
}
