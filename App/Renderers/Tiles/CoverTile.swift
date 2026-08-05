import SwiftUI
import HavenCore
struct CoverTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    var body: some View {
        let e = store.state(entityId); let s = e.map(CoverState.init)
        let open = s?.isOpen ?? false; let accent = HavenColor.domain(.cover)
        let unavailable = e?.isUnavailable ?? false
        // Lit by the *derived* state where there is one, so the wash and the glyph cannot
        // disagree: a garage whose limits say shut must not glow because its cover entity still
        // reports "open".
        GlassTile(active: store.deviceState(of: entityId).isActive ?? open,
                  accent: accent, unavailable: unavailable) {
            // Centred on the tile rather than on what the slider leaves of it — see `LightTile`,
            // which has the same arrangement and the same reason: a cover with a reported position
            // and one without must not put their glyphs in different places.
            // **The device's own state where it has one.** A garage with both limits bound can say
            // "Partly open", which `cover.garage` itself has no word for — see `CompositeState`.
            // The tile reads that value and does not compute it, which is what 6a's resolver was
            // shaped for: hoisting the composite here cost this one expression.
            StateFace(state: store.deviceState(of: entityId).face
                      ?? TileState.cover(deviceClass: e?.deviceClass, isOpen: open,
                                         unavailable: unavailable),
                      style: store.stateStyle(of: entityId),
                      name: store.displayName(of: entityId),
                      accent: accent,
                      // The derived state's own tint where there is one — see `DeviceState.isActive`.
                      active: store.deviceState(of: entityId).isActive ?? open,
                      unavailable: unavailable)
                .overlay(alignment: .trailing) {
                    // Unlike the light, this is shown at every position including 0 — a closed shade
                    // has a real, meaningful position — so a drag up from the bottom genuinely opens
                    // it, and `CoverOptimistic.position` moves the open/closed state along with the
                    // number so the tile's tint and the bar can't disagree. Hence `minimum: 0`: for a
                    // cover, dragging to the bottom is closing it, which is a legitimate thing to ask
                    // for and leaves the control on screen.
                    if let pos = s?.positionPercent {
                        PipSlider(percent: pos, accent: accent,
                                  label: "Position",
                                  onCommit: { store.setCoverPosition(entityId, percent: $0) },
                                  onTap: { store.openCloseCover(entityId) })
                            .padding(.top, 2)
                            // Stops above the name rather than running the full height of the
                            // tile, so the label is exactly as wide with a slider as without one —
                            // see `StateFace.nameHeight`.
                            .padding(.bottom, StateFace.nameHeight)
                    }
                }
        }
        .tileInteraction(entityId,
                         label: s.map { AccessibilitySummary.cover(store.displayName(of: entityId), $0) }
                             ?? store.displayName(of: entityId)) {
            store.openCloseCover(entityId)
        }
    }
}
