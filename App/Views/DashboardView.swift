import SwiftUI
import HavenCore

struct DashboardView: View {
    @Environment(HomeStore.self) private var store
    var body: some View {
        TabView {
            ForEach(store.home.floors) { floor in
                Tab(floor.name, systemImage: "square.stack.3d.up") {
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                ForEach(floor.areas) { area in RoomSectionView(area: area) }
                            }.padding()
                        }.navigationTitle(floor.name)
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
