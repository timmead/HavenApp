import SwiftUI
import HavenCore

/// Choosing how much of the grid a tile takes.
///
/// **The options are drawn, not written.** A chip reading "2x1" asks the reader to know whether that
/// is columns-by-rows or rows-by-columns, and the two conventions are both in daily use — the
/// codebase writes one and the request that prompted this feature wrote the other. A rectangle in
/// the shape of the tile cannot be read the wrong way round.
///
/// Shown only where there is a choice. Its one caller, `SubsectionConfigView`, hides the whole card
/// when `kind.availableSpans` holds a single entry rather than draw a picker holding one selected
/// chip — a control that cannot act. Per-entity sizing (and with it `TileConfigView`'s own copy of
/// this gate, `TileSpan.isResizable`) left the app in the same change that made `kind.availableSpans`
/// this component's only source of options — see decision 5 in the room-subsections design.
/// `TileSpan.isResizable` itself was deleted from `HavenCore` in Task 7, once nothing called it any
/// more.
struct TileSizePicker: View {
    let options: [TileSpan]
    @Binding var selection: TileSpan

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.self) { span in
                Button {
                    selection = span
                } label: {
                    TileSizeChip(span: span, isSelected: span == selection)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(span.columns) by \(span.rows)")
                .accessibilityAddTraits(span == selection ? [.isButton, .isSelected] : .isButton)
            }
            Spacer(minLength: 0)
        }
    }
}

/// One option: the tile's proportions, at a size that fits a row of them.
///
/// The cells are drawn individually rather than as one rectangle of the right ratio, because the
/// question a reader is answering is "how much of my row does this take" — and a 4×2 beside a 1×1
/// says that better as eight little squares against one than as two rectangles of different sizes.
private struct TileSizeChip: View {
    let span: TileSpan
    let isSelected: Bool

    /// The largest span on offer is 4 wide and 2 tall, so every chip is drawn on that grid and the
    /// smaller ones simply fill less of it. Drawn to a common frame, the chips line up and the
    /// comparison between them is the thing you see.
    private static let gridColumns = 4
    private static let gridRows = 2
    private static let cell: CGFloat = 7
    private static let gap: CGFloat = 2

    private var accent: Color { isSelected ? HavenColor.domain(.cover) : .secondary }

    var body: some View {
        VStack(spacing: Self.gap) {
            ForEach(0..<Self.gridRows, id: \.self) { row in
                HStack(spacing: Self.gap) {
                    ForEach(0..<Self.gridColumns, id: \.self) { column in
                        let filled = column < span.columns && row < span.rows
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(filled ? accent.opacity(isSelected ? 0.9 : 0.45)
                                         : Color.secondary.opacity(0.12))
                            .frame(width: Self.cell, height: Self.cell)
                    }
                }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(isSelected ? accent.opacity(0.12) : Color.secondary.opacity(0.06)))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isSelected ? accent.opacity(0.7) : Color.clear, lineWidth: 1.5)
        }
    }
}

#if DEBUG
/// Every option set that exists, so the chips can be compared as sets rather than one at a time —
/// which is the only way to see whether a 2×2 reads as different from a 2×1 at this size.
///
/// Over the kinds with more than one option — `SubsectionConfigView`'s own gate — rather than every
/// kind, so this shows exactly the option sets a picker can actually appear with.
#Preview("Tile size picker") {
    VStack(alignment: .leading, spacing: 18) {
        ForEach(SubsectionKind.allCases.filter { $0.availableSpans.count > 1 }, id: \.self) { kind in
            VStack(alignment: .leading, spacing: 7) {
                Text(kind.displayName).font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                StatefulPicker(options: kind.availableSpans)
            }
        }
    }
    .padding(24)
}

private struct StatefulPicker: View {
    let options: [TileSpan]
    @State private var selection: TileSpan

    init(options: [TileSpan]) {
        self.options = options
        _selection = State(initialValue: options[0])
    }

    var body: some View { TileSizePicker(options: options, selection: $selection) }
}
#endif
