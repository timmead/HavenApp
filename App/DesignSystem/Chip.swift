import SwiftUI

struct HavenChip: View {
    var systemImage: String? = nil
    let text: String
    var accent: Color? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .bold)).foregroundStyle(accent ?? .secondary) }
            Text(text).font(.system(size: 12.5, weight: .bold))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(HavenColor.glassFill))
    }
}
