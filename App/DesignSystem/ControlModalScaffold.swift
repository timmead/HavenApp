import SwiftUI

/// Header row for a control modal: icon · name · state subtitle · primary on/off toggle.
///
/// **The primary on/off lives here — never in the body — for every device type that *has* an
/// on/off**, including composites. One place, one meaning, so the header is trustworthy at a
/// glance.
///
/// Two deliberate exceptions, both recorded here so the rule isn't silently contradicted by a
/// renderer that looks like it forgot it:
///
/// - **A lock puts its action in the body instead** (`LockModal`), as a large explicit button. Not
///   an oversight and not a styling preference: locking is a consequential action rather than a
///   state you flip, and a toggle sitting at the top of a sheet is one careless swipe away from
///   unlocking a door. The header keeps the lock's *state* in its subtitle; what it does not offer
///   is a one-gesture way to change it.
/// - **A Sonos speaker substitutes a vendor hand-off** for the toggle (`MediaPlayerModal`), because
///   it has no meaningful power state at all. A substitution, never an addition — see `accessory`.
///
/// There is deliberately **no close button**. Every one of these is presented as a sheet, which
/// already dismisses by swiping its grabber down or tapping the dimmed area above it; a third way
/// bought nothing and cost the header the width it now gives back to the title.
struct ModalHeader: View {
    let systemImage: String; let title: String; let subtitle: String; let accent: Color
    var toggle: Binding<Bool>? = nil
    /// Occupies the toggle's place for a device whose primary action genuinely isn't on/off — today
    /// only a Sonos speaker, which has no meaningful power state and offers a hand-off to its own
    /// app there instead (see `MediaPlayerModal`). Deliberately an *alternative* to `toggle`, not an
    /// addition beside it: the slot means one thing per device, which is the property that made the
    /// header trustworthy in the first place. Passing both is a caller bug, and the toggle wins.
    var accessory: AnyView? = nil
    /// Whether the toggle can be operated. `false` renders it in place but greyed and inert — for a
    /// device Home Assistant cannot currently reach.
    ///
    /// Disabled rather than removed on purpose. Removing it would leave the slot empty and say
    /// nothing about *why*; leaving it live would be worse still, because the command primitives
    /// now refuse to act on an unreachable entity (see `HomeStore.optimistic`), so an enabled
    /// toggle would flip under the finger, send nothing, and spring back — a control that silently
    /// does nothing is the least honest of the three.
    var toggleEnabled: Bool = true
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
            if let toggle {
                Toggle("", isOn: toggle).labelsHidden().tint(accent).accessibilityLabel(title)
                    .disabled(!toggleEnabled)
            }
            else if let accessory { accessory }
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
