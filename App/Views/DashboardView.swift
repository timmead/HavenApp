import SwiftUI
import HavenCore

struct DashboardView: View {
    @Environment(HomeStore.self) private var store
    @Environment(AppModel.self) private var app
    /// Where the optional "connect faster at home" upgrade is offered. Reached only by deliberate
    /// navigation — the location prompt behind it must never appear during onboarding.
    @State private var showingConnectionSettings = false
    var body: some View {
        let rooms = store.rooms()
        TabView {
            ForEach(store.home.floors) { floor in
                Tab(floor.name, systemImage: "square.stack.3d.up") {
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                ForEach(floor.areas) { area in
                                    if let room = rooms.first(where: { $0.areaId == area.id }) {
                                        RoomSectionView(room: room)
                                    }
                                }
                            }.padding()
                        }
                        .navigationTitle(floor.name)
                        .navigationDestination(for: String.self) { roomId in
                            if let room = rooms.first(where: { $0.id == roomId }) {
                                RoomDetailView(room: room)
                            }
                        }
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Menu {
                                    Button("Connection", systemImage: "wifi") {
                                        showingConnectionSettings = true
                                    }
                                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                        Task { await app.signOut() }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                            }
                        }
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .sheet(isPresented: Binding(get: { store.presented != nil }, set: { if !$0 { store.presented = nil } })) {
            if let id = store.presented { DeviceModalView(entityId: id) }
        }
        .sheet(isPresented: $showingConnectionSettings) { ConnectionSettingsView() }
    }
}
