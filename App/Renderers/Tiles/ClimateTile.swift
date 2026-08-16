import SwiftUI
import HavenCore

/// The two approved climate tile renderings.
enum ClimateTileSize {
    /// 2×1. A target temperature, a mode summary, and the controls that fit beside them.
    case compact
    /// 4×2. The room's actual temperature large, the setpoint as a control rather than a readout,
    /// and every mode the unit declares as its own button.
    case large
}

extension ClimateTileSize {
    /// The rendering a span asks for. See `DeviceTileView.tile`.
    init(span: TileSpan) {
        self = span.columns >= 4 ? .large : .compact
    }
}

struct ClimateTile: View {
    let entityId: String
    var size: ClimateTileSize = .compact
    @Environment(HomeStore.self) private var store
    @Environment(Navigation.self) private var navigation
    /// Which surface this tile is on — set by `ConfigurableTile`, and what a tap in
    /// configuration mode removes it from.
    @Environment(\.havenSurface) private var surface
    var body: some View {
        switch size {
        case .compact: compact
        case .large: large
        }
    }

    /// **The 4×2: what the sheet offers, without opening it.**
    ///
    /// The compact tile is a readout with two controls squeezed beside it — the target temperature
    /// is its largest text, and the mode is a word at the bottom. Four times the area does not mean
    /// the same thing bigger; it means the things that were compressed get to be themselves. So the
    /// *room's* temperature leads, because that is what you look at a thermostat to find out, the
    /// setpoint becomes a control with its own two buttons rather than a number with steppers in the
    /// corner, and every mode the unit declares gets a labelled button instead of a summary you
    /// have to open a sheet to change.
    private var large: some View {
        let e = store.state(entityId)
        let s = e.map(ClimateState.init)
        let on = s?.isOn ?? false
        let accent = HavenColor.climate(s?.function ?? .unspecified)
        let unavailable = e?.isUnavailable ?? false
        return GlassTile(active: s?.isConditioning ?? false, accent: accent,
                         unavailable: unavailable) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 16))
                        .foregroundStyle((on ? Emphasis.accent : .secondary)
                            .color(unavailable: unavailable, accent: accent))
                        .symbolRenderingMode(.hierarchical)
                    Text(store.displayName(of: entityId))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(Emphasis.primary.color(unavailable: unavailable,
                                                                accent: accent))
                    Spacer(minLength: 0)
                    powerButton(on: on, unavailable: unavailable,
                                unreachable: e?.state == "unavailable",
                                accent: accent, modes: s?.modes ?? [])
                }
                Spacer(minLength: 6)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // **The room's temperature, not the target.** The compact tile leads with the
                    // setpoint because at two columns there is room for one number and the setpoint
                    // is the one you can change. Here both fit, and what a thermostat is for is
                    // telling you how warm the room actually is.
                    Text(s?.currentTemp.map { "\(String(format: "%.1f", $0))°" } ?? "—")
                        .font(.system(size: 34, weight: .bold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(Emphasis.primary.color(unavailable: unavailable,
                                                                accent: accent))
                    Spacer(minLength: 0)
                    // The setpoint as a control: the number between its own two buttons rather
                    // than a readout with steppers in a far corner. Only while it is on, for the
                    // reason the compact tile records — a target for a thermostat that is off is a
                    // setting with no visible effect.
                    if on {
                        HStack(spacing: 8) {
                            stepper("minus", label: "Decrease target temperature",
                                    unavailable: unavailable, unreachable: e?.state == "unavailable",
                                    accent: accent, target: s?.targetTemp, delta: -1)
                            Text(s?.targetTemp.map { "\(Int($0))°" } ?? "—")
                                .font(.system(size: 20, weight: .bold))
                                .lineLimit(1)
                                .frame(minWidth: 42)
                                .foregroundStyle(Emphasis.accent.color(unavailable: unavailable,
                                                                       accent: accent))
                            stepper("plus", label: "Increase target temperature",
                                    unavailable: unavailable, unreachable: e?.state == "unavailable",
                                    accent: accent, target: s?.targetTemp, delta: 1)
                        }
                    }
                }
                Spacer(minLength: 6)
                modeRow(s, accent: accent, unavailable: unavailable,
                        unreachable: e?.state == "unavailable")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { navigation.open(entityId, on: surface) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(s.map { AccessibilitySummary.climate(store.displayName(of: entityId), $0) } ?? store.displayName(of: entityId))
        .accessibilityAction(named: "Open controls") { navigation.open(entityId, on: surface) }
    }

    /// Every mode the unit declares, as a button.
    ///
    /// **The unit's own list, in the unit's own order** — not a fixed set. Home Assistant reports
    /// `hvac_modes` per device and they genuinely differ: a heat-only radiator valve declares two,
    /// a heat pump five. Inventing modes a device does not have would send commands it will refuse.
    ///
    /// Labels shrink rather than truncate. "Heat Cool" beside four others at this width is tight,
    /// and a mode clipped to "Heat C…" is a control you cannot identify.
    @ViewBuilder
    private func modeRow(_ s: ClimateState?, accent: Color, unavailable: Bool,
                         unreachable: Bool) -> some View {
        if let s, !s.modes.isEmpty {
            HStack(spacing: 6) {
                ForEach(s.modes, id: \.self) { mode in
                    let selected = mode == s.hvacMode
                    Button {
                        store.setClimateMode(entityId, mode: mode)
                    } label: {
                        Text(TileName.words(mode))
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(selected
                                ? Emphasis.accent.color(unavailable: unavailable, accent: accent)
                                : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected ? accent.opacity(0.16) : HavenColor.glassFill))
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(unreachable)
                    // `.buttonStyle(.plain)` does not dim a disabled control — the same note the
                    // stepper and the power button carry.
                    .opacity(unreachable ? 0.45 : 1)
                    .accessibilityLabel(TileName.words(mode))
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    private var compact: some View {
        let e = store.state(entityId); let s = e.map(ClimateState.init)
        let on = s?.isOn ?? false
        // **Heating and cooling are not the same colour.** One climate accent made a room being
        // cooled to 19° look exactly like one being heated to 21°, which is the difference a glance
        // at a dashboard is for. `function` reads Home Assistant's action first and its mode second
        // — HavenCore, with tests, because it is a reading of HA's vocabulary rather than a matter
        // of taste — and `HavenColor.climate` maps it. `heat_cool` and `off` keep the domain colour;
        // there is no true colour for a thermostat that will do either and is doing neither.
        let accent = HavenColor.climate(s?.function ?? .unspecified)
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
        return GlassTile(active: s?.isConditioning ?? false, accent: accent, unavailable: unavailable) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 0) {
                    // **Accent while it is on, `.secondary` while it is off** — the rule every
                    // other tile already follows (`LightTile`, `SwitchTile`, `CoverTile` all draw
                    // an off device's icon and title `.secondary`).
                    //
                    // This tile used to be the exception, tinted accent whatever its state, and now
                    // that the accent says *which* function a thermostat performs the exception had
                    // become actively misleading: an off unit was still a confident red or blue
                    // thermometer, which is the colour this branch's other work made mean "heating"
                    // and "cooling". Grey says the true thing, and says it the way the rest of the
                    // grid says it.
                    //
                    // `Emphasis` resolves unreachability on top of this, so the `unavailable` case
                    // is unchanged and still lands on `.secondary` by its own route.
                    Image(systemName: "thermometer.medium").font(.system(size: 20)).foregroundStyle((on ? Emphasis.accent : .secondary).color(unavailable: unavailable, accent: accent)).symbolRenderingMode(.hierarchical)
                    Spacer(minLength: 0)
                    // The controls are spaced rather than touching: three 26pt circles butted
                    // together read as one segmented control, which would suggest the power button
                    // is a third *value* alongside up and down rather than a different kind of
                    // thing. The tile is two columns wide (~172pt, see below), so the gap is
                    // affordable — it was zero because the layout was first written against the
                    // 1×1 the gallery was wrongly drawing.
                    HStack(spacing: 8) {
                        // **Only while it is on**, rather than disabled while it is off. A target
                        // temperature for a thermostat that is off is a setting with no effect, and
                        // `setClimateTemp` on an off unit is a command whose result the user cannot
                        // see; the sheet is where that belongs. Off, the row is the power button
                        // alone — which is the one control an off thermostat does need.
                        //
                        // There is room for all three because this tile is **two columns wide** on
                        // every surface that draws it — `SubsectionView`, the one container both
                        // surfaces render, sizes the whole Climate subsection from
                        // `SubsectionKind.climate.defaultSpan(on:)` — roughly 172pt rather than the
                        // 83 a 1×1 gets.
                        if on {
                            stepper("minus", label: "Decrease target temperature",
                                    unavailable: unavailable, unreachable: e?.state == "unavailable",
                                    accent: accent, target: s?.targetTemp, delta: -1)
                            stepper("plus", label: "Increase target temperature",
                                    unavailable: unavailable, unreachable: e?.state == "unavailable",
                                    accent: accent, target: s?.targetTemp, delta: 1)
                        }
                        // Two different questions, deliberately given two different answers.
                        // `unavailable` (`isUnavailable`, which is `unavailable` *or* `unknown`)
                        // decides how the button is *tinted*, because neither state is one to draw a
                        // confident accent for. Whether it can be *pressed* is `state ==
                        // "unavailable"` alone: an `unknown` thermostat is reachable and simply
                        // hasn't reported a mode, `HomeStore`'s command guard lets it through on
                        // exactly that distinction, and `LockTile`'s tap has always stayed live for
                        // the same reason. Disabling it here would take away the user's one way to
                        // resolve the state — see `LockModal` for the long form.
                        powerButton(on: on, unavailable: unavailable, unreachable: e?.state == "unavailable",
                                    accent: accent, modes: s?.modes ?? [])
                    }
                }
                Spacer(minLength: 2)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    // Unguarded, this was a bigger version of the same problem the icon above
                    // fixes: `targetTemp` is read straight from attributes regardless of state, so
                    // an unreachable thermostat that still has a cached `temperature` attribute
                    // would show its last-known target in full accent colour — a state claim in
                    // the tile's most prominent text. Same guard shape as the icon.
                    //
                    // `lineLimit(1).fixedSize()` keeps the number on one line. It is the largest
                    // thing on the tile and the one that must not be ambiguous — "2" over "3°" for
                    // a 23-degree target is worse than a truncated mode label — so it takes the
                    // width it needs and the secondary text beside it, already `lineLimit(1)`,
                    // gives way.
                    //
                    // Off is `.secondary` for the same reason the icon above is: the accent now
                    // names a *function*, so a grey 23° is an off thermostat's target and a red one
                    // would be a heating claim.
                    Text(s?.targetTemp.map { "\(Int($0))°" } ?? "—").font(.system(size: 24, weight: .bold)).foregroundStyle((on ? Emphasis.accent : .secondary).color(unavailable: unavailable, accent: accent))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    // Already unconditionally `.secondary` regardless of availability — a
                    // hierarchy choice, not an on/off one — so no guard is needed here to satisfy
                    // "unavailable text is secondary".
                    //
                    // The mode and the fan speed, as they always were. A previous commit dropped the
                    // `· fan auto` tail on the grounds that it could not fit — measured against
                    // `TileGallery`, which was drawing this tile through its 4-column row while
                    // both real surfaces give it two. At the width it actually has, both fit with
                    // room to spare, so the tail is back and the gallery has been corrected to stop
                    // producing that class of mistake.
                    Text(s.map { "\(TileName.words($0.hvacMode))\($0.fanMode.map { " · Fan \(TileName.words($0))" } ?? "")" } ?? "").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle()).onTapGesture { navigation.open(entityId, on: surface) }.onLongPressGesture(minimumDuration: 0.35) { navigation.open(entityId, on: surface) }
        // `.contain`, not `.combine`: this tile now holds a real button, and combining would fold
        // it into a single label a VoiceOver user could read but not operate — the same reason
        // `MediaPlayerTile` uses `.contain`. The label below is the container's, spoken on entry;
        // the power button keeps its own, and the tap-to-open gesture — which is not a `Button` and
        // so is invisible to VoiceOver either way — becomes a named action.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(s.map { AccessibilitySummary.climate(store.displayName(of: entityId), $0) } ?? store.displayName(of: entityId))
        .accessibilityAction(named: "Open controls") { navigation.open(entityId, on: surface) }
    }

    /// One degree down or up, without opening the sheet.
    ///
    /// **Nothing is written optimistically, and the number therefore moves when Home Assistant
    /// echoes** rather than under the finger. That is `setClimateTemp`'s existing behaviour and
    /// `ClimateModal`'s ± buttons have always had it; making it optimistic is a real improvement
    /// and belongs to both surfaces at once, not to this one quietly. What it must not do is *look*
    /// optimistic, which is why there is no local preview state here to drift out of step with the
    /// thermostat.
    ///
    /// **A flat 1°, not `target_temp_step`.** Both this tile and the sheet render the target as a
    /// whole number, so on a unit whose step is 0.5 an honest reading of the attribute would show
    /// every other tap doing nothing at all. A step the display cannot represent is worse than a
    /// coarse one.
    ///
    /// No target temperature at all — a thermostat that has not reported one — leaves the buttons
    /// visible but inert rather than guessing a base to add to. The alternative is inventing a
    /// setpoint for the user's home out of nothing.
    private func stepper(_ symbol: String, label: String, unavailable: Bool, unreachable: Bool,
                         accent: Color, target: Double?, delta: Double) -> some View {
        Button {
            if let target { store.setClimateTemp(entityId, temp: target + delta) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Emphasis.accent.color(unavailable: unavailable, accent: accent))
                .frame(width: 26, height: 26)
                .background(Circle().fill(HavenColor.glassFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(unreachable || target == nil)
        // Same reason as the power button's: `.buttonStyle(.plain)` does not dim a disabled
        // control, and a stepper that cannot act must not look identical to one that can.
        .opacity((unreachable || target == nil) ? 0.45 : 1)
        .accessibilityLabel(label)
    }

    /// On/off in the corner of the tile, so heating can be killed without opening anything.
    ///
    /// **It commands the mode, and is therefore driven by `isOn`, not by the fill.** Tinting it by
    /// `isConditioning` would give a thermostat that is on and merely idle a grey power button —
    /// a switch that reads as off while it is on, which is the oldest ambiguity in this kind of
    /// control and the reason the two states are kept apart in this file at all.
    ///
    /// Turning *on* picks `ClimateState.modeWhenTurningOn` — the same rule `ClimateModal`'s header
    /// toggle calls — so the tile and the sheet cannot send different commands for the same
    /// gesture.
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
            store.setClimateMode(entityId, mode: on ? "off" : ClimateState.modeWhenTurningOn(from: modes))
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
