import SwiftUI
import HavenCore

/// The kinds of device the add-tile picker offers, as tickboxes.
///
/// **An expanding section, not a sheet.** It was a sheet, and presenting one from inside another
/// makes the first dismiss and re-present around it — the list you were reading slides away and
/// comes back, which is a lot of motion for five tickboxes. Expanding in place costs nothing and
/// keeps the list you are filtering on screen while you filter it.
///
/// Everything is ticked when the picker opens, so a user who never touches this never notices it.
/// The choice is **not persisted**: it narrows one search of one room, the way a filter in a file
/// picker does, and storing it in the household document would mean a tick someone left off last
/// month silently hiding devices from everyone.
struct TileKindFilter: View {
    /// The kinds actually present among the candidates, in `TileCategory`'s own order — a room with
    /// no cameras should not offer to filter cameras out.
    let available: [TileCategory]
    @Binding var excluded: Set<TileCategory>

    var body: some View {
        FacetCard(title: "Kinds") {
            VStack(spacing: 0) {
                ForEach(available, id: \.self) { category in
                    let isOn = !excluded.contains(category)
                    Button {
                        if isOn { excluded.insert(category) } else { excluded.remove(category) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: category.symbol)
                                .font(.system(size: 14))
                                .foregroundStyle(HavenColor.domain(.cover))
                                .frame(width: 22)
                            Text(category.label).font(.system(size: 15, weight: .semibold))
                            Spacer(minLength: 8)
                            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                .font(.system(size: 17))
                                .foregroundStyle(isOn ? AnyShapeStyle(HavenColor.domain(.cover))
                                                      : AnyShapeStyle(.secondary))
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
                if !excluded.isEmpty {
                    Button("Show all kinds") { excluded.removeAll() }
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }
        }
    }
}
