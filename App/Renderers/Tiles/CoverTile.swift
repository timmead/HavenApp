import SwiftUI
import HavenCore
struct CoverTile: View {
    /// Trailing room for the position slider, so the name beneath the state clears it. See
    /// `LightTile.sliderClearance` — the slider's layout width is its 4pt track, not its touch
    /// target, so this needs to be small or it eats the name for nothing.
    private static let sliderClearance: CGFloat = 12

    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    /// Which surface this tile is on — set by `ConfigurableTile`, and what a tap in
    /// configuration mode removes it from.
    @Environment(\.havenSurface) private var surface
    var body: some View {
        let e = store.state(entityId); let s = e.map(CoverState.init)
        let open = s?.isOpen ?? false; let accent = HavenColor.domain(.cover)
        let unavailable = e?.isUnavailable ?? false
        GlassTile(active: open, accent: accent, unavailable: unavailable) {
            // Centred on the tile rather than on what the slider leaves of it — see `LightTile`,
            // which has the same arrangement and the same reason: a cover with a reported position
            // and one without must not put their glyphs in different places.
            StateFace(state: TileState.cover(deviceClass: e?.deviceClass, isOpen: open,
                                             unavailable: unavailable),
                      style: store.stateStyle(of: entityId),
                      name: store.displayName(of: entityId),
                      accent: accent, active: open, unavailable: unavailable,
                      trailingInset: s?.positionPercent != nil ? Self.sliderClearance : 0)
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
                            .padding(.vertical, 2)
                    }
                }
        }
        .contentShape(Rectangle()).onTapGesture { store.openCloseCover(entityId) }.onLongPressGesture(minimumDuration: 0.35) { navigation.open(entityId, on: surface) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.map { AccessibilitySummary.cover(store.displayName(of: entityId), $0) } ?? store.displayName(of: entityId))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open controls") { navigation.open(entityId, on: surface) }
    }
}
