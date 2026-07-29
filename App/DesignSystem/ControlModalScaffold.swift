import SwiftUI
import HavenCore

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
    let systemImage: String
    let title: String
    /// What to say about the device **when it can be reached**. Overridden by "Unavailable" when
    /// it cannot — see `unavailable`.
    let subtitle: String
    /// The tint **for a reachable device**. Resolved against `unavailable` here, never by the
    /// caller.
    let accent: Color
    /// Whether Home Assistant can currently reach this device.
    ///
    /// **Required, and deliberately not defaulted.** Three separate things follow from it — the
    /// tint, the subtitle, and whether the toggle can be operated — and every one of them used to
    /// be derived at the call site. Eleven call sites, three chances each to forget, and several
    /// did: `SceneModal` passed a full-strength accent for a scene nothing could reach, which is
    /// the same defect `SensorTile` had before the tiles were given `TileLabel`.
    ///
    /// A default of `false` would let the next modal omit it and quietly inherit the bug. Making it
    /// required means a header cannot be written without answering the question.
    let unavailable: Bool
    var toggle: Binding<Bool>? = nil
    /// Occupies the toggle's place for a device whose primary action genuinely isn't on/off — today
    /// only a Sonos speaker, which has no meaningful power state and offers a hand-off to its own
    /// app there instead (see `MediaPlayerModal`). Deliberately an *alternative* to `toggle`, not an
    /// addition beside it: the slot means one thing per device, which is the property that made the
    /// header trustworthy in the first place. Passing both is a caller bug, and the toggle wins.
    var accessory: AnyView? = nil
    /// The tint actually drawn: `accent` for a reachable device, `.secondary` otherwise. The rule
    /// is `Emphasis`'s, in HavenCore with a test, and is the same one the tiles obey.
    private var resolvedAccent: Color {
        Emphasis.accent.color(unavailable: unavailable, accent: accent)
    }

    /// An unreachable device says so, whatever the caller had in mind. Centralised because naming
    /// this state in every header was previously a hand-applied sweep (`159b28b`), which is the
    /// kind that misses one.
    private var resolvedSubtitle: String { unavailable ? "Unavailable" : subtitle }

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
                Image(systemName: systemImage).font(.system(size: 20)).foregroundStyle(resolvedAccent).frame(width: 38, height: 38).background(resolvedAccent.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 1) { Text(title).font(.system(size: 16, weight: .bold)); Text(resolvedSubtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(resolvedSubtitle.isEmpty ? title : "\(title), \(resolvedSubtitle)")
            Spacer()
            if let toggle {
                // Disabled rather than removed on purpose. Removing it would leave the slot empty
                // and say nothing about *why*; leaving it live would be worse still, because the
                // command primitives refuse to act on an unreachable entity (see
                // `HomeStore.optimistic`), so an enabled toggle would flip under the finger, send
                // nothing, and spring back — a control that silently does nothing is the least
                // honest of the three.
                Toggle("", isOn: toggle).labelsHidden().tint(resolvedAccent).accessibilityLabel(title)
                    .disabled(unavailable)
            }
            else if let accessory { accessory }
        }
    }
}

#if DEBUG
/// Every header shape, reachable beside unreachable.
///
/// The modals are view code with no test coverage, and this change moved three separate decisions
/// — tint, subtitle, and whether the toggle can be operated — out of eleven call sites and into one
/// place. That is exactly the sort of change whose mistakes are invisible to `xcodebuild test`, so
/// it gets looked at instead.
#Preview("Modal headers") {
    VStack(alignment: .leading, spacing: 22) {
        ModalHeader(systemImage: "lightbulb.fill", title: "Kitchen", subtitle: "On",
                    accent: HavenColor.domain(.light), unavailable: false,
                    toggle: .constant(true))
        ModalHeader(systemImage: "lightbulb.fill", title: "Porch", subtitle: "On",
                    accent: HavenColor.domain(.light), unavailable: true,
                    toggle: .constant(true))
        Divider()
        ModalHeader(systemImage: "sparkles", title: "Movie", subtitle: "",
                    accent: HavenColor.domain(.scene), unavailable: false)
        // The one the sweep had missed entirely.
        ModalHeader(systemImage: "sparkles", title: "Away", subtitle: "",
                    accent: HavenColor.domain(.scene), unavailable: true)
        Divider()
        ModalHeader(systemImage: "thermometer.medium", title: "Lounge", subtitle: "Heat · 21°",
                    accent: HavenColor.domain(.climate), unavailable: false,
                    toggle: .constant(true))
        ModalHeader(systemImage: "questionmark.circle", title: "Shed", subtitle: "Locked",
                    accent: HavenColor.domain(.lock), unavailable: true)
    }
    .padding()
}
#endif

/// The explicit way out of a sheet, for the header's accessory slot.
///
/// The control modals rely on the drag indicator and a swipe, which is fine for a sheet you opened
/// to press one button. The configuration sheets are different in kind: you arrive at them from a
/// mode you had to enter deliberately, you may have typed into them, and "swipe it away" is a poor
/// answer to "am I finished?". So they say so.
struct ModalDoneButton: View {
    let action: () -> Void

    var body: some View {
        Button("Done", action: action)
            .font(.system(size: 15, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(HavenColor.domain(.cover))
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
