import SwiftUI
import HavenCore

/// Which kinds of thing the add-tile picker offers.
///
/// Its own sheet rather than a row of chips in the picker: the picker's whole problem is that it is
/// long, and the fix cannot be to put seven more tappable things above the list. Everything is ticked
/// when it opens, so a user who never touches this never notices it.
///
/// The choice is **not** persisted. It narrows one search of one room, the way a filter in a file
/// picker does; storing it in the household document would mean a tick someone left off last month
/// silently hiding devices from everyone.
struct AddTileFilterView: View {
    /// The categories actually present in this room, in `TileCategory`'s own order — a room with no
    /// cameras should not offer to filter cameras out.
    let available: [TileCategory]
    @Binding var excluded: Set<TileCategory>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModalHeader(systemImage: "line.3.horizontal.decrease.circle",
                        title: "Filter",
                        subtitle: "Kinds of device to show",
                        accent: HavenColor.domain(.cover), unavailable: false,
                        accessory: AnyView(ModalDoneButton { dismiss() }))
            FacetCard {
                VStack(spacing: 0) {
                    ForEach(available, id: \.self) { category in
                        Button {
                            if excluded.contains(category) {
                                excluded.remove(category)
                            } else {
                                excluded.insert(category)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: category.symbol)
                                    .font(.system(size: 14))
                                    .foregroundStyle(HavenColor.domain(.cover))
                                    .frame(width: 22)
                                Text(category.label).font(.system(size: 15, weight: .semibold))
                                Spacer(minLength: 8)
                                Image(systemName: excluded.contains(category) ? "square" : "checkmark.square.fill")
                                    .font(.system(size: 17))
                                    .foregroundStyle(excluded.contains(category)
                                                     ? AnyShapeStyle(.secondary)
                                                     : AnyShapeStyle(HavenColor.domain(.cover)))
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(excluded.contains(category) ? [] : .isSelected)
                    }
                }
            }
            if !excluded.isEmpty {
                Button("Show all kinds") { excluded.removeAll() }
                    .font(.system(size: 13, weight: .semibold))
            }
        }
    }
}

#if DEBUG
private struct AddTileFilterPreviewHost: View {
    @State private var excluded: Set<TileCategory>
    init(excluded: Set<TileCategory>) { _excluded = State(initialValue: excluded) }
    var body: some View {
        AddTileFilterView(available: [.lights, .shades, .cameras, .sensors, .scenesAndMore],
                          excluded: $excluded)
            .padding(16)
    }
}

#Preview("Filter — all kinds") { AddTileFilterPreviewHost(excluded: []) }
#Preview("Filter — some unticked") { AddTileFilterPreviewHost(excluded: [.sensors, .cameras]) }
#endif
