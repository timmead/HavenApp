import SwiftUI
import HavenCore

/// What a two-state tile shows: its state, large and in the middle, with its name beneath.
///
/// **The state is the main event here, where `TileLabel` makes the name the main event.** That
/// arrangement — small glyph up top, name at the bottom — suits a tile whose interesting content is
/// a control or a reading. A door sensor has neither: the only thing it has to say is whether the
/// door is open, and saying it in a 20pt glyph in a corner made every binary tile look identical
/// until you read the tint.
///
/// Either a glyph or a word, per `TileStateStyle` — the household's choice, because which is faster
/// to read genuinely differs by person and by device. A picture is quicker once you know it; a word
/// is unambiguous the first time. Neither is right for everyone, so it is a setting rather than an
/// argument.
struct StateFace: View {
    let state: TileState
    let style: TileStateStyle
    let name: String
    let accent: Color
    let active: Bool
    let unavailable: Bool
    /// Room to leave on the trailing edge for a control drawn *over* this face — a brightness or
    /// position slider.
    ///
    /// **Only the name is inset, never the state.** The state is centred on the whole tile, which is
    /// the point of it: a bulb that sits left of centre whenever a light happens to be dimmable, and
    /// centred when it does not, reads as a layout that cannot make up its mind. The name is the
    /// one thing that would actually collide, so the name is the one thing that moves.
    var trailingInset: CGFloat = 0

    /// The state's own emphasis: accented when active, secondary otherwise — and resolved through
    /// `Emphasis` so the unreachable rule is applied rather than remembered. See `TileLabel`.
    private var stateColor: Color {
        (active ? Emphasis.accent : .secondary).color(unavailable: unavailable, accent: accent)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            switch style {
            case .icon:
                Image(systemName: state.symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(stateColor)
                    .symbolRenderingMode(.hierarchical)
            case .label:
                Text(state.word)
                    .font(.system(size: 19, weight: .semibold))
                    // "Unavailable" is the longest word any of these produce and it must not
                    // truncate: a state clipped to "Unavaila…" reads as a rendering fault rather
                    // than as a device Haven cannot reach.
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(stateColor)
            }
            Spacer(minLength: 0)
            Text(name)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(Emphasis.primary.color(unavailable: unavailable, accent: accent))
                .padding(.trailing, trailingInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
