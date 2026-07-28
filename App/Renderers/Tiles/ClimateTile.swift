import SwiftUI
import HavenCore
struct ClimateTile: View {
    let entityId: String
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    var body: some View {
        let e = store.state(entityId); let s = e.map(ClimateState.init)
        let on = s?.isOn ?? false; let accent = HavenColor.domain(.climate)
        let unavailable = e?.isUnavailable ?? false
        // **Lit by what the equipment is doing, not by what mode it is in.** `GlassTile`'s fill is
        // the loudest thing a tile can say — an accent wash, a coloured border and a glow — and
        // spending it on "the thermostat is switched on" lights every heated room in the house all
        // winter, which is the same as lighting none of them. `isConditioning` (HavenCore, with
        // tests) is true only while the equipment is actually running, so the wash now means "this
        // room is being heated right now" and goes out when the room reaches its target.
        //
        // `on` is still read, one line below, for the power button: the button commands the *mode*,
        // so it has to reflect the mode. The two differ on purpose and the tile shows both — a warm
        // thermometer with no wash is a thermostat on and idle.
        GlassTile(active: s?.isConditioning ?? false, accent: accent, unavailable: unavailable) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 0) {
                    // Unlike the other tiles' icons, this one is always tinted `accent` regardless of
                    // on/off by design — but that means an unreachable thermostat needs its own guard
                    // rather than inheriting one from an `on`/`off` check that was never gating it.
                    Image(systemName: "thermometer.medium").font(.system(size: 20)).foregroundStyle(Emphasis.accent.color(unavailable: unavailable, accent: accent)).symbolRenderingMode(.hierarchical)
                    Spacer(minLength: 0)
                    // Two different questions, deliberately given two different answers. `unavailable`
                    // (`isUnavailable`, which is `unavailable` *or* `unknown`) decides how the button
                    // is *tinted*, because neither state is one to draw a confident accent for.
                    // Whether it can be *pressed* is `state == "unavailable"` alone: an `unknown`
                    // thermostat is reachable and simply hasn't reported a mode, `HomeStore`'s
                    // command guard lets it through on exactly that distinction, and `LockTile`'s tap
                    // has always stayed live for the same reason. Disabling it here would take away
                    // the user's one way to resolve the state — see `LockModal` for the long form.
                    powerButton(on: on, unavailable: unavailable, unreachable: e?.state == "unavailable",
                                accent: accent, modes: s?.modes ?? [])
                }
                Spacer(minLength: 2)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    // Unguarded, this was a bigger version of the same problem the icon above
                    // fixes: `targetTemp` is read straight from attributes regardless of state, so
                    // an unreachable thermostat that still has a cached `temperature` attribute
                    // would show its last-known target in full accent colour — a state claim in
                    // the tile's most prominent text. Same guard shape as the icon.
                    //
                    // `lineLimit(1).fixedSize()` is not new styling, it is a wrap this tile has
                    // always had and the gallery makes obvious: at four columns "21°" broke after
                    // the digits and hung the degree sign on a line of its own. The number is the
                    // one thing on the tile that must not be ambiguous — "2" over "3°" for a
                    // 23-degree target is worse than a truncated mode label — so it takes the space
                    // it needs and the secondary text beside it, already `lineLimit(1)`, gives way.
                    Text(s?.targetTemp.map { "\(Int($0))°" } ?? "—").font(.system(size: 24, weight: .bold)).foregroundStyle(Emphasis.accent.color(unavailable: unavailable, accent: accent))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    // Already unconditionally `.secondary` regardless of availability — a
                    // hierarchy choice, not an on/off one — so no guard is needed here to satisfy
                    // "unavailable text is secondary".
                    //
                    // **The mode only, with no `· fan auto` tail.** The fan segment has never once
                    // been legible here: at a quarter of the screen, beside a 24pt temperature,
                    // this text has room for two or three characters, and every one it spends on a
                    // fan speed it takes from the only thing that distinguishes heating from
                    // cooling on a tile whose fill is climate-orange either way. The fan mode is
                    // still in `ClimateModal`, where there is width for it.
                    Text(s.map { TileName.words($0.hvacMode) } ?? "").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle()).onTapGesture { navigation.presentedEntityId = entityId }.onLongPressGesture(minimumDuration: 0.35) { navigation.presentedEntityId = entityId }
        // `.contain`, not `.combine`: this tile now holds a real button, and combining would fold
        // it into a single label a VoiceOver user could read but not operate — the same reason
        // `MediaPlayerTile` uses `.contain`. The label below is the container's, spoken on entry;
        // the power button keeps its own, and the tap-to-open gesture — which is not a `Button` and
        // so is invisible to VoiceOver either way — becomes a named action.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(s.map { AccessibilitySummary.climate(TileName.of(entityId, e), $0) } ?? TileName.of(entityId, e))
        .accessibilityAction(named: "Open controls") { navigation.presentedEntityId = entityId }
    }

    /// On/off in the corner of the tile, so heating can be killed without opening anything.
    ///
    /// **It commands the mode, and is therefore driven by `isOn`, not by the fill.** Tinting it by
    /// `isConditioning` would give a thermostat that is on and merely idle a grey power button —
    /// a switch that reads as off while it is on, which is the oldest ambiguity in this kind of
    /// control and the reason the two states are kept apart in this file at all.
    ///
    /// Turning *on* picks the same mode `ClimateModal`'s header toggle does — the first declared
    /// non-`off` mode, or `heat` if the device declared none — so the tile and the sheet cannot
    /// send different commands for the same gesture.
    ///
    /// Disabled rather than hidden when unreachable, matching `ModalHeader`'s toggle: the command
    /// primitives refuse an unreachable entity outright (`HomeStore.fireAndForget`), so a live
    /// button here would send nothing and look broken, while removing it would leave a hole that
    /// says nothing about why. `unreachable` is `state == "unavailable"` and nothing else — see the
    /// call site for why an `unknown` thermostat keeps a working button on a dimmed tile.
    ///
    /// Nothing is written optimistically, because `setClimateMode` writes nothing — a climate
    /// entity's state is a *mode string*, not `on`/`off`, and the only honest guess at the mode
    /// Home Assistant will settle on is the one we just asked for. So the button waits for the
    /// echo, exactly as the modal's toggle already does.
    private func powerButton(on: Bool, unavailable: Bool, unreachable: Bool,
                             accent: Color, modes: [String]) -> some View {
        Button {
            store.setClimateMode(entityId, mode: on ? "off" : (modes.first { $0 != "off" } ?? "heat"))
        } label: {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(on ? Emphasis.accent.color(unavailable: unavailable, accent: accent) : .secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(on ? accent.opacity(unavailable ? 0 : 0.18) : HavenColor.glassFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(unreachable)
        // `.buttonStyle(.plain)` does not dim a disabled button, so without this an unreachable
        // thermostat and an `unknown` one — both struck, both with a grey power glyph — are
        // pixel-identical while only one of them can be pressed. The gallery shows the pair side by
        // side, which is how that was caught. A control that silently does nothing is the failure
        // `ModalHeader`'s toggle comment describes; this is the tile-sized version of saying so.
        .opacity(unreachable ? 0.45 : 1)
        .accessibilityLabel(on ? "Turn off" : "Turn on")
        // The button sits inside the tile's own tap-to-open gesture. A `Button` wins the taps
        // within its bounds, but the surrounding `.contentShape(Rectangle())` means the tile is
        // hit-testable underneath it, so the shape is stated here too rather than left to the
        // glyph's own bounds — a `power` symbol is a thin ring, and its transparent middle would
        // otherwise open the modal.
    }
}
