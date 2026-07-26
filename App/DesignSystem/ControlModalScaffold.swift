import SwiftUI

/// Header row for a control modal: icon · name · state subtitle · primary on/off toggle · close button.
/// The primary on/off ALWAYS lives here — never in the body — for every device type, including composites.
struct ModalHeader: View {
    let systemImage: String; let title: String; let subtitle: String; let accent: Color
    var toggle: Binding<Bool>? = nil
    var onClose: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 20)).foregroundStyle(accent).frame(width: 38, height: 38).background(accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 1) { Text(title).font(.system(size: 16, weight: .bold)); Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer()
            if let toggle { Toggle("", isOn: toggle).labelsHidden().tint(accent) }
            Button { onClose() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary).frame(width: 28, height: 28).background(.gray.opacity(0.15), in: Circle()) }
        }
    }
}

/// A body card holding only secondary controls (sliders, segmented controls) and/or sensor+history.
struct FacetCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title { Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary) }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }
}
