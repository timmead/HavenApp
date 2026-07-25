import SwiftUI

struct GlassTile<Content: View>: View {
    var active: Bool = false
    var accent: Color = .gray
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 9, trailing: 14))
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(active ? AnyShapeStyle(accent.opacity(0.30)) : AnyShapeStyle(.regularMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(active ? accent.opacity(0.6) : Color.white.opacity(0.35), lineWidth: 1))
                    .shadow(color: active ? accent.opacity(0.28) : .black.opacity(0.06), radius: active ? 10 : 3, y: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
