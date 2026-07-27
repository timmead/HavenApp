import SwiftUI
import HavenCore

struct RoomEnvironmentHistoryView: View {
    let roomName: String
    let sensors: [UpliftedSensor]
    var body: some View { Text(roomName) }
}
