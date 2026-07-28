import SwiftUI
import HavenCore

extension TileEmphasis {
    /// The SwiftUI colour for this emphasis.
    ///
    /// `Color.primary`/`Color.secondary` deliberately, and **not** the `HierarchicalShapeStyle`
    /// values of the same names: every tile's original expression resolved to `Color` — that is
    /// the only way `unavailable ? .secondary : accent` type-checks at all, since `accent` is a
    /// `Color` and both arms of a ternary must agree. Returning `Color` keeps what is drawn
    /// identical to what it replaced.
    func color(accent: Color) -> Color {
        switch self {
        case .accent: accent
        case .primary: .primary
        case .secondary: .secondary
        }
    }
}

/// Resolves an intended emphasis against reachability and maps it to a colour, for the tiles whose
/// layouts `TileLabel` does not fit — the climate tile's oversized target temperature, and the
/// media player's two `GlassTile` sizes.
///
/// Exists so that **no tile hand-writes `unavailable ? .secondary : …` any more.** That is a
/// grep-checkable invariant, which is worth more than the handful of characters it costs at each
/// call site: the defect this whole change addresses is an element that quietly never got the
/// guard, and an invariant you can check in one command is how that stops recurring.
func tileColor(_ intended: TileEmphasis, unavailable: Bool, accent: Color) -> Color {
    intended.resolved(unavailable: unavailable).color(accent: accent)
}

/// The icon-over-name stack that eight of the eleven tile renderers are built from.
///
/// It existed eight times, hand-written, and the interesting part was never the layout — it was
/// that every element had to remember `unavailable ? .secondary : …`. One tile forgot
/// (`SensorTile`'s name had no `foregroundStyle` at all), which took its own commit to notice and
/// fix. Here there is no way to *say* what an element should look like except by handing over an
/// intended `TileEmphasis`, and this applies `resolved(unavailable:)` to it — so the guard is not
/// something a caller can leave out.
///
/// **The glyph is the caller's, and deliberately so.** `symbol` is passed through untouched: this
/// resolves style, never which picture is drawn. Whether a symbol asserts something it shouldn't
/// is domain knowledge that cannot be decided generically — `LockTile` must render
/// `questionmark.circle` when unreachable specifically because the lock domain's own symbol is
/// `lock.fill`, and quietly showing a falsely-*locked* padlock instead of a falsely-open one is
/// the worse of the two failures in a security context. See that file; its reasoning is why this
/// parameter cannot be "just derive it from the domain".
struct TileLabel<Subtitle: View>: View {
    let symbol: String
    let name: String
    /// What the icon should look like **if the device is reachable**. Resolved against
    /// `unavailable` here, never by the caller.
    var icon: TileEmphasis = .secondary
    /// Likewise for the name. `.primary` is the common case — a tile with no on/off notion of its
    /// own (lock, scene, sensor, binary sensor, generic) keeps its name at full strength.
    var title: TileEmphasis = .primary
    let accent: Color
    let unavailable: Bool
    /// Optional second line, for the tiles that show a reading under the name. Its own styling is
    /// the caller's: every current subtitle is unconditionally `.secondary` — a hierarchy choice
    /// rather than a state claim — so there is nothing here for the rule to resolve.
    @ViewBuilder var subtitle: () -> Subtitle

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(icon.resolved(unavailable: unavailable).color(accent: accent))
                .symbolRenderingMode(.hierarchical)
            Spacer(minLength: 2)
            Text(name)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(title.resolved(unavailable: unavailable).color(accent: accent))
            subtitle()
        }
    }
}

extension TileLabel where Subtitle == EmptyView {
    init(symbol: String, name: String, icon: TileEmphasis = .secondary,
         title: TileEmphasis = .primary, accent: Color, unavailable: Bool) {
        self.init(symbol: symbol, name: name, icon: icon, title: title,
                  accent: accent, unavailable: unavailable) { EmptyView() }
    }
}
