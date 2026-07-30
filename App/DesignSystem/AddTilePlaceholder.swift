import SwiftUI

/// The dashed **+** at the end of a room's grid, in configuration mode.
///
/// Sized and cornered like a 1×1 `GlassTile` so it sits *in* the grid rather than beside it, but
/// deliberately drawn as an outline: it is a place where a tile could be, not a tile. A filled
/// version reads as a device you own called "+".
struct AddTilePlaceholder: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(HavenColor.domain(.cover).opacity(0.5),
                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(minHeight: 66)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(HavenColor.domain(.cover))
                }
                // The stroke alone is not hit-testable across the tile's middle, so the shape is
                // stated: a + you have to hit the outline of is a + that mostly does nothing.
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a device")
    }
}
