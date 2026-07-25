import SwiftUI

struct LevelBar: View {
    let percent: Int
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.black.opacity(0.09))
                Capsule().fill(color).frame(height: geo.size.height * CGFloat(max(0, min(100, percent))) / 100)
            }
        }
        .frame(width: 4)
    }
}
