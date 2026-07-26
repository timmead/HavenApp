import SwiftUI
import HavenCore

/// Temporary stub — Task 23 replaces this body with the full grouped room detail.
struct RoomDetailView: View {
    let room: RoomSection
    var body: some View {
        ScrollView { Text(room.name).font(.headline).padding() }
            .navigationTitle(room.name)
    }
}
