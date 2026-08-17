import SwiftUI
import HavenCore

/// The three approved climate tile renderings.
enum ClimateTileSize {
    /// 2×1. A target temperature, a mode summary, and the controls that fit beside them.
    case compact
    /// 4×1. The same readout on one line with the width it never had: the room's temperature and
    /// what the unit is set to on the left, the setpoint between its own two buttons on the right.
    case row
    /// 4×2. The room's actual temperature large, the setpoint as a control rather than a readout,
    /// and every mode the unit declares as its own button.
    case large
}

extension ClimateTileSize {
    /// The rendering a span asks for. See `DeviceTileView.tile`.
    ///
    /// The three cases are exactly `TileSpan.available(for: .climate)`, listed in the same order, so
    /// the two can be read against each other — that list's own rule is that nothing is offered
    /// which cannot be drawn.
    ///
    /// **A tuple switch, where this used to be `span.columns >= 4 ? .large : .compact`.** That test
    /// read the width alone, which was sound while four columns meant two rows and nothing else; the
    /// moment a 4×1 was offered (tile refinements, item 4) it would have sent one to `.large` — a
    /// three-row `VStack` inside a tile one row tall. The rows are half the question now.
    ///
    /// **The fallback is `.compact`, the smallest**, and it is the one case kept explicitly beside
    /// its own identical `default:` so the switch reads straight down against the list above. An
    /// unrecognised span therefore draws the rendering that fits anywhere rather than the one that
    /// fits least often.
    init(span: TileSpan) {
        switch (span.columns, span.rows) {
        case (2, 1): self = .compact
        case (4, 1): self = .row
        case (4, 2): self = .large
        default: self = .compact
        }
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
        case .row: row
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
    ///
    /// **`row` now sits between the two, and it took the first two of those three.** A 4×1 has the
    /// width for the room's temperature and for the setpoint-as-control, and this size shares both
    /// with it through `setpointControl`. What is left as this size's own is the part that needs a
    /// *second* row to exist at all: `modeRow` (see `row`'s note on why it cannot go on one line)
    /// and the device's name.
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
                    // **The only climate rendering that shows a name at all** — `compact` (2×1) has
                    // never had room for one and `row` (4×1) has the width but not the line to
                    // spend it on (see its own note), so both already satisfy "omitted when hidden"
                    // without a line changing. Absent from the layout rather than blanked, the
                    // same rule `TileLabel`/`StateFace` apply, so the power button gets the space
                    // back instead of a gap beside it.
                    if !store.labelHidden(of: entityId) {
                        Text(store.displayName(of: entityId))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(Emphasis.primary.color(unavailable: unavailable,
                                                                    accent: accent))
                    }
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
                    // telling you how warm the room actually is. `row` makes the same call at 4×1,
                    // one size down, for the same reason.
                    Text(s?.currentTemp.map { "\(String(format: "%.1f", $0))°" } ?? "—")
                        .font(.system(size: 34, weight: .bold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(Emphasis.primary.color(unavailable: unavailable,
                                                                accent: accent))
                    Spacer(minLength: 0)
                    setpointControl(s, on: on, unavailable: unavailable,
                                    unreachable: e?.state == "unavailable", accent: accent)
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

    /// **The 4×1: the 2×1's readout, given the width it never had.**
    ///
    /// `compact` has roughly 148pt of content to spend on a 24pt number, a mode word and two
    /// controls, and it shows the *target* rather than the room because one number is all that fits
    /// and the target is the one you can change. The tail on that mode word was once dropped
    /// outright for not fitting; `compact` records the measurement that put it back. A whole row
    /// removes the constraint rather than easing it — the room's temperature leads, as it does on
    /// the 4×2 and for the same reason, and the target comes out of the corner to sit between its
    /// own two buttons through the same `setpointControl` the 4×2 draws.
    ///
    /// **The mode row was cut, and the constraint that cut it is width, not height.** The design
    /// record (tile refinements, item 4) asks for the steppers *and* the mode row inline — the
    /// sheet's top strip as a tile — and the arithmetic does not allow it. Counting once, from the
    /// constants in this file: four columns is ~337pt of content (a 393pt phone, 16pt page padding
    /// either side, less `GlassTile`'s 10/14 insets). The furniture takes ~206 of it — the icon ~22,
    /// `setpointControl` 110 (26 + 8 + 42 + 8 + 26), the power button 26, four 10pt gaps and the
    /// 8pt `Spacer` minimum — and the current temperature another ~68, so **~275 is spoken for and
    /// ~60 is left**. A mode row's buttons each take `maxWidth: .infinity` of whatever remains: two
    /// modes get ~30pt apiece against a "Heat Cool" that runs nearer 52 at 11pt, and a heat pump
    /// declaring five or seven gets a fifth of that. Dropping the power button (the mode row does
    /// carry `off`) or the steppers only moves the figure to ~33pt. It is not a layout to tune: a
    /// mode row needs a row, which is what the 4×2 gives it.
    ///
    /// **That ~60pt and the ~60pt the mode-and-fan tail is short of are the same slack, described
    /// twice — not two budgets.** Worth writing down, because the two figures appear a few lines
    /// apart below and read like a contradiction otherwise. There is one pool of leftover width on
    /// this line; the tail already wants ~95 of it and truncates. A mode row would therefore
    /// *displace* the tail rather than sit beside it, so the choice was never "steppers and modes"
    /// but "the word that says what the thermostat is doing, or a row of buttons too narrow to
    /// read". That strengthens the cut rather than qualifying it.
    ///
    /// **No fixture would have caught that**, which is why it is settled here rather than at the
    /// canvas. Every climate fixture in `TileGallery` declares exactly two `hvac_modes`, so the
    /// crush a real five-mode unit would take is invisible in the one place that draws this tile.
    /// The modes stay one tap away, in the sheet this tile opens.
    ///
    /// **No name, matching `compact`** — climate's other single-row size — so a household that hides
    /// a label has nothing to hide here and Task 2's rule is satisfied without a branch.
    ///
    /// **The binding case for that is a thermostat that is `on`**, which is the one to design
    /// against. On, this line carries a setpoint *and* a full mode-and-fan tail — "Fan Only · Fan
    /// High" is a real ~95pt string at 11pt — and there is nowhere for a name to go. Off, the
    /// picture is the opposite and the obvious objection is fair: `setpointControl` disappears, the
    /// tail shrinks to a single word, and the row is a reading and a power button with a long gap
    /// between them (see `TileGallery.climateRow4x1`, which pictures exactly that). It is still not
    /// where a name goes — a name that appeared only while the heating was off, and vanished the
    /// moment it came on, would be worse than none. The name belongs to the 4×2, which is the size
    /// with a line to put it on whatever the unit is doing.
    ///
    /// On is genuinely tight rather than rhetorically tight: the mode-and-fan tail wants ~95pt and
    /// this line gives it ~60, so it is *already* the thing truncating (see its own comment below).
    /// A name would take that width from a slot that has none to give.
    ///
    /// **It takes its own height, and it must keep taking it.** A 4×1 is a *single-row* span, and
    /// single-row is the one case both hosts size by measurement rather than by proposal:
    /// `RoomGrid.rowHeight` measures `sizeThatFits(.unspecified)` on single-row subviews and hands
    /// the tallest one's height to every row, and `SubsectionView.tileHeight` returns nil for a
    /// single row so each tile asks for what it wants. A `maxHeight: .infinity` here would be greedy
    /// rather than exact — the trap `SubsectionView.tileHeight`'s comment records having fallen into
    /// and removed — which is the exact opposite of what `large` needs. Same file, opposite rules,
    /// because the spans differ; `MediaPlayerTile.row` carries this note for the same reason.
    ///
    /// Nothing on this line has an opinion about its own size. The tallest thing is a 24pt number in
    /// a ~29pt line box against 26pt control circles, well inside `GlassTile`'s 66pt content floor,
    /// so this tile measures what every other single-row tile measures and the steppers appearing
    /// when the unit is switched on does not change it. That matters more here than on a 1×1: a
    /// Climate subsection sizes all its tiles alike, so at 4×1 this tile *is* the measured row
    /// height for its whole container, and anything added to the line that measures past the floor —
    /// a chart, an image with an aspect ratio, a second text line — grows every row in it.
    private var row: some View {
        let e = store.state(entityId); let s = e.map(ClimateState.init)
        let on = s?.isOn ?? false
        let accent = HavenColor.climate(s?.function ?? .unspecified)
        let unavailable = e?.isUnavailable ?? false
        // `.leading` — horizontally leading, vertically centred. This line is ~29pt of content
        // inside `GlassTile`'s 66pt floor, so hanging it from the top would float it above ~37pt of
        // nothing; `compact` may sit at the top because it has a second line to put there and this
        // size deliberately does not. `MediaPlayerTile.row` is that parameter's only other caller,
        // for the identical reason — see `GlassTile.alignment`, where the two are one rule.
        return GlassTile(active: s?.isConditioning ?? false, accent: accent,
                         unavailable: unavailable, alignment: .leading) {
            HStack(spacing: 10) {
                // Accent while on, `.secondary` while off — `compact`'s rule, which is the grid's
                // rule; the long form is on that tile.
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 20))
                    .foregroundStyle((on ? Emphasis.accent : .secondary)
                        .color(unavailable: unavailable, accent: accent))
                    .symbolRenderingMode(.hierarchical)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // `Emphasis.primary`, not the on/off accent `compact` gives *its* largest
                    // number. The two are showing different values: `compact`'s is the target, which
                    // is a setting and so goes grey when the unit is off, while this is the room's
                    // own temperature — a reading, true whatever the thermostat is doing. The 4×2
                    // draws the same value the same way.
                    //
                    // `lineLimit(1).fixedSize()` for the reason `compact` gives: it is the largest
                    // text on the tile and the one that must not be ambiguous, so it takes the width
                    // it needs and the word beside it — already `lineLimit(1)` — gives way.
                    Text(s?.currentTemp.map { "\(String(format: "%.1f", $0))°" } ?? "—")
                        .font(.system(size: 24, weight: .bold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(Emphasis.primary.color(unavailable: unavailable,
                                                                accent: accent))
                    // **The same string `compact` draws, one point larger — and with less room for
                    // it, not more.** The intuition that a wider tile is a roomier one is wrong
                    // here, and it is worth being exact about why: `compact` gives this text a line
                    // of its own beneath the target number, so it has some 105pt to spend at 10pt,
                    // while this size shares a single line with the setpoint cluster and the power
                    // button and has nearer 60pt at 11pt. A full tail wants ~95 — "Fan Only · Fan
                    // High" is a real reading — so it truncates here and does not on the *narrower*
                    // tile.
                    //
                    // That is the trade, taken deliberately: the row buys legibility, since a size
                    // meant to be read across a room should not set its only words at the size two
                    // columns forced, and it pays in length. The tail is what gives, by
                    // construction — `lineLimit(1)` here meets a temperature that keeps its full
                    // width through `fixedSize` above, so the number stays unambiguous and the word
                    // beside it shortens.
                    //
                    // It is also the strongest single argument for cutting the mode row rather than
                    // squeezing it (see this size's doc comment): if a two-word fan mode cannot
                    // finish on this line, five mode buttons were never going to start.
                    Text(s.map { "\(TileName.words($0.hvacMode))\($0.fanMode.map { " · Fan \(TileName.words($0))" } ?? "")" } ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                setpointControl(s, on: on, unavailable: unavailable,
                                unreachable: e?.state == "unavailable", accent: accent)
                // Kept even though `setpointControl` disappears when the unit is off: off, this row
                // is the readout and this button, which is the one control an off thermostat needs.
                // The two-questions split `compact` documents at length applies unchanged — tinted
                // by `unavailable`, pressable by `state == "unavailable"` alone.
                powerButton(on: on, unavailable: unavailable, unreachable: e?.state == "unavailable",
                            accent: accent, modes: s?.modes ?? [])
            }
            .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
        // Tap alone, where `compact` also carries a long press doing the identical thing. One
        // gesture with one meaning — and it is the gesture that reaches the modes this size cut.
        .onTapGesture { navigation.open(entityId, on: surface) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(s.map { AccessibilitySummary.climate(store.displayName(of: entityId), $0) } ?? store.displayName(of: entityId))
        .accessibilityAction(named: "Open controls") { navigation.open(entityId, on: surface) }
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
                        // There is room for all three because this tile is **never narrower than two
                        // columns**, on either surface, however the household sizes it —
                        // `SubsectionKind.climate.availableSpans` (`TileSpan.available(for:
                        // .climate)`) offers 2×1, 4×1 and 4×2, with no 1-column option to fall back
                        // to. Roughly 172pt is the floor, not just today's default. (The list read
                        // "only 2×1 or 4×2" until the 4×1 arrived; the claim is unchanged, since
                        // what holds it up is the absence of a 1-column option and not the length
                        // of the list.)
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

    /// The setpoint as a control: the number between its own two buttons, rather than a readout
    /// with steppers in a far corner. Drawn by the two sizes with a row to give it — the 4×1 and
    /// the 4×2.
    ///
    /// **Shared for the rule, not for the `HStack`.** Both sites draw it *only while the unit is
    /// on*, because a target temperature for a thermostat that is off is a setting with no visible
    /// effect and `setClimateTemp` on an off unit is a command whose result the user cannot see —
    /// the long form is on `compact`, and it is a fact about thermostats rather than about either
    /// layout. Two copies of a three-element row would only be tedious; two copies of *when a
    /// setpoint may be shown at all* is somewhere for that answer to fall out of step.
    ///
    /// **No scale parameters, deliberately.** Task 3's `transportCluster` took them because its two
    /// call sites genuinely differ — white over an album cover against the domain accent on glass —
    /// and here they do not: 26pt circles around a 20pt number are what fits on one line, and the
    /// 4×2 has no reason to be larger for having more room. Parameters would be inventing a
    /// difference. If one ever appears, this signature is where it goes.
    ///
    /// `compact`'s cornered pair stays inline and separate rather than becoming a third caller: it
    /// is a deliberately cut-down control with **no number between the buttons**, because at two
    /// columns the number is already the tile.
    @ViewBuilder
    private func setpointControl(_ s: ClimateState?, on: Bool, unavailable: Bool,
                                 unreachable: Bool, accent: Color) -> some View {
        if on {
            HStack(spacing: 8) {
                stepper("minus", label: "Decrease target temperature",
                        unavailable: unavailable, unreachable: unreachable,
                        accent: accent, target: s?.targetTemp, delta: -1)
                Text(s?.targetTemp.map { "\(Int($0))°" } ?? "—")
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                    .frame(minWidth: 42)
                    .foregroundStyle(Emphasis.accent.color(unavailable: unavailable, accent: accent))
                stepper("plus", label: "Increase target temperature",
                        unavailable: unavailable, unreachable: unreachable,
                        accent: accent, target: s?.targetTemp, delta: 1)
            }
        }
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
