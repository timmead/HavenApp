import SwiftUI
import HavenCore

struct RoomSectionView: View {
    let area: ResolvedArea
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(area.name).font(.headline)
            LazyVGrid(columns: columns, spacing: 10) {
                // Temporary bridge: route every entity through the new renderer
                // dispatch so it's reachable at runtime. Task 22 rewrites this view.
                ForEach(area.entityIds, id: \.self) { id in
                    DeviceTileView(entityId: id).gridCellColumns(1)
                }
            }
        }
    }
}
