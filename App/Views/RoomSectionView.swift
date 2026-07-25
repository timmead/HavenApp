import SwiftUI
import HavenCore

struct RoomSectionView: View {
    let area: ResolvedArea
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(area.name).font(.headline)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(area.entityIds.filter { $0.hasPrefix("light.") }, id: \.self) { id in
                    LightTileView(entityId: id).gridCellColumns(1)
                }
            }
        }
    }
}
