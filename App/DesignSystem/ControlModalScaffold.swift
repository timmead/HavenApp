import SwiftUI

/// Header row for a control modal: icon · name · state subtitle · primary on/off toggle · close button.
/// The primary on/off ALWAYS lives here — never in the body — for every device type, including composites.
struct ModalHeader: View {
    let systemImage: String; let title: String; let subtitle: String; let accent: Color
    var toggle: Binding<Bool>? = nil
    var onClose: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            // Grouped as one VoiceOver element ("name, state") — the icon carries no
            // information a sighted user gets that isn't already in the text, so exposing
            // it separately would just be a second, redundant stop while swiping.
            //
            // A real container, not `Group`: `Group` isn't a layout container at all — it
            // propagates whatever modifiers are attached to it to *each child individually*
            // rather than applying them once to the group as a whole. `.accessibilityElement`/
            // `.accessibilityLabel` on a `Group` therefore applied twice, once to the `Image` and
            // once to the `VStack`, producing exactly the two redundant VoiceOver stops this
            // comment says it exists to avoid. `HStack` is a genuine container, so the modifiers
            // below apply exactly once, to the row as a whole.
            HStack(spacing: 10) {
                Image(systemName: systemImage).font(.system(size: 20)).foregroundStyle(accent).frame(width: 38, height: 38).background(accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 1) { Text(title).font(.system(size: 16, weight: .bold)); Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(subtitle.isEmpty ? title : "\(title), \(subtitle)")
            Spacer()
            if let toggle { Toggle("", isOn: toggle).labelsHidden().tint(accent).accessibilityLabel(title) }
            Button { onClose() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary).frame(width: 28, height: 28).background(.gray.opacity(0.15), in: Circle()) }
                .accessibilityLabel("Close")
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
        .background(HavenColor.glassFill, in: RoundedRectangle(cornerRadius: 16))
    }
}
