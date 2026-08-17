import SwiftUI

struct GlassTile<Content: View>: View {
    var active: Bool = false
    var accent: Color = .gray
    /// Home Assistant cannot currently reach this device. Overrides `active` outright: an
    /// unreachable device is not on, whatever its last-known state said, and tinting it as though
    /// it were would be the same false statement the strike exists to prevent.
    var unavailable: Bool = false
    /// Where the content sits in a tile taller than it is — which every tile is, since 66 is a
    /// floor and most content is shorter.
    ///
    /// **Defaulted to the only value that existed before it was a parameter**, so no tile changed
    /// by its arrival. Two callers differ — `MediaPlayerTile.row` and `ClimateTile.row` — and they
    /// are the same case twice rather than two exceptions, which is the thing to read off this
    /// list: **a single-row rendering centres its line.** A 4×1 is one line of content in a tile the
    /// same height as a 1×1, so hanging it from the top leaves it floating above 30–37pt of nothing
    /// (media's line is the taller of the two), while the multi-row and 1×1 sizes have a second row
    /// to put in that space and keep `.topLeading`.
    ///
    /// The alternative was for each of those tiles to restate the 66 itself and centre inside its
    /// own frame — this constant written down in a second and a third place, and one more of them
    /// every time a 4×1 is added.
    var alignment: Alignment = .topLeading
    @ViewBuilder var content: () -> Content

    var body: some View {
        let lit = active && !unavailable
        content()
            .frame(maxWidth: .infinity, minHeight: 66, alignment: alignment)
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 9, trailing: 14))
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(lit ? AnyShapeStyle(accent.opacity(0.30)) : AnyShapeStyle(.regularMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(lit ? accent.opacity(0.6) : HavenColor.glassStroke, lineWidth: 1))
                    .shadow(color: lit ? accent.opacity(0.28) : .black.opacity(0.06), radius: lit ? 10 : 3, y: 2)
            }
            // Over the content, not behind it — the tile is struck through, not watermarked. Placed
            // before `.clipShape` so the line is bounded by the same rounded rect as the border and
            // cannot poke out at the corners.
            .overlay { if unavailable { UnavailableStrike().stroke(HavenColor.glassStroke, lineWidth: 1) } }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
