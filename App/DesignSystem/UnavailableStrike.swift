import SwiftUI

/// A hairline drawn corner to corner across a tile, marking a device Home Assistant cannot
/// currently reach.
///
/// The design spec asks for `unavailable` to be a distinct *calm* state, not an alarm — so this is
/// the same colour and weight as the tile's own border rather than a warning tint, and it carries
/// no text. What it must not do is let an unreachable device look like an off one: before this,
/// a light that had dropped off the network and a light that was simply switched off rendered
/// identically, which is a false statement about the user's home.
struct UnavailableStrike: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}
