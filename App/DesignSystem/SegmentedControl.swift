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
                // A real Button, not `.onTapGesture` — the latter carries no button trait,
                // so VoiceOver couldn't tell a user this was operable at all (D.2 follow-up).
                // `.plain` keeps the appearance pixel-identical to the old tap-gesture Text.
                Button { selection = opt } label: {
                    Text(label(opt)).font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background { if sel { RoundedRectangle(cornerRadius: 10).fill(.background).shadow(radius: 1, y: 1) } }
                        .foregroundStyle(sel ? accent : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(sel ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 14).fill(HavenColor.glassFill))
    }
}
