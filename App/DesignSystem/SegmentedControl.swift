import SwiftUI

struct HavenSegmented<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String
    var accent: Color = .accentColor
    var body: some View {
        HStack(spacing: 5) {
            ForEach(options, id: \.self) { opt in
                let sel = opt == selection
                Text(label(opt)).font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background { if sel { RoundedRectangle(cornerRadius: 10).fill(.background).shadow(radius: 1, y: 1) } }
                    .foregroundStyle(sel ? accent : .secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { selection = opt }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.5)))
    }
}
