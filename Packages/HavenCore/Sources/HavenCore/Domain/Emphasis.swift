import Foundation

/// How prominently one element should be drawn — and what being unreachable does to that.
///
/// Used by the tiles (through `TileLabel`) and by the control modals (through `ModalHeader`). It
/// was `TileEmphasis` while only the tiles had it; the modals turned out to be repeating the same
/// rule by hand, which is what the name now stops pretending.
///
/// A *decision* about rendering, with no rendering in it — which is why it lives in HavenCore
/// alongside `IconMap` and `AccessibilitySummary` rather than in `App/`. The mapping to an actual
/// SwiftUI colour is the App layer's (`Emphasis.color(accent:)`); everything worth getting
/// wrong is here, where it is tested.
public enum Emphasis: Sendable, Equatable, CaseIterable {
    /// Tinted with the tile's domain accent. This element is carrying the "on"/"active" signal.
    case accent
    /// Full-strength foreground — the tile's primary content.
    case primary
    /// Dimmed: either subordinate content, or an element with nothing to assert.
    case secondary

    /// **The rule every tile has to obey, in the one place it can be tested.**
    ///
    /// Home Assistant cannot reach this device, so no element of its tile may assert anything
    /// about it: everything drops to `.secondary`, whatever the tile would otherwise have drawn.
    ///
    /// This existed eleven times in the tiles and six more in the modals, hand-written as
    /// `unavailable ? .secondary : …` at every element, and the sweep that added it missed one — `SensorTile`'s name had no
    /// `foregroundStyle` at all and so stayed `.primary` for a device nothing could reach. That is
    /// the defect this function exists to make unrepresentable: a tile that renders its label
    /// through `TileLabel` cannot express an intended emphasis without this being applied to it.
    ///
    /// Note what this is **not**: it resolves an element's *style*, never its *glyph*. Choosing a
    /// symbol that asserts nothing is the caller's job and cannot be done generically — see
    /// `LockTile`, where `unavailable` must select `questionmark.circle` specifically, because the
    /// domain's own symbol is `lock.fill` and quietly swapping a falsely-open padlock for a
    /// falsely-*locked* one is the worse of the two failures in a security context.
    public func resolved(unavailable: Bool) -> Emphasis {
        unavailable ? .secondary : self
    }
}
