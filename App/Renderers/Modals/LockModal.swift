import SwiftUI
import HavenCore

/// The one renderer that deliberately does **not** put its primary action in the header.
///
/// Every other modal follows `ModalHeader`'s rule: the primary on/off is a toggle at the top, in
/// one predictable place. A lock is the exception, and the reason is that locking is not a state
/// you flip — it is a consequential action on the boundary of the user's home. A toggle at the top
/// of a sheet is one careless swipe from unlocking a door, and it is exactly the gesture a thumb
/// makes while reaching for the grabber just above it.
///
/// So the state stays in the header, where the eye already looks for it, and the *action* is a
/// large, deliberate, centred button that has to be aimed at. The exception is recorded on
/// `ModalHeader` itself so the two cannot drift into looking like an oversight.
struct LockModal: View {
    let entityId: String
    @Environment(HomeStore.self) private var store

    var body: some View {
        let e = store.state(entityId)
        let s = e.map(LockState.init)
        let locked = s?.isLocked ?? false
        let jammed = s?.isJammed ?? false
        // `isLocked`/`isJammed` both read `false` for an `unavailable` state string exactly as they
        // would for a genuinely unlocked lock (see `LockState`), so left alone this header asserted
        // "Unlocked", drew `lock.open.fill` in lock-blue, and offered a confident full-width "Lock"
        // button one tap from a tile that was just struck through to say we don't know — the state
        // claim this whole branch's thesis exists to remove, on the one modal that thesis is about.
        //
        // `unavailable` and `unknown` are read apart here rather than folded into one
        // `EntityState.isUnavailable` check: an `unavailable` lock cannot be reached at all, but an
        // `unknown` one is reachable and simply has not reported a position yet. Conflating them
        // previously made this file assert "This lock can't be reached right now" about a lock HA
        // can reach just fine — precisely the kind of claim this branch exists to remove, now in
        // the caption instead of the header. `HomeStore.toggleLock` makes the matching distinction
        // on the command side.
        let unavailable = e?.state == "unavailable"
        let unknown = e?.state == "unknown"
        let subtitle = unavailable ? "Unavailable"
            : (unknown ? "Unknown" : (jammed ? "Jammed" : (locked ? "Locked" : "Unlocked")))
        let symbol = (unavailable || unknown) ? "questionmark.circle"
            : (jammed ? "lock.trianglebadge.exclamationmark" : (locked ? "lock.fill" : "lock.open.fill"))
        // **The accent is the lock's state, and an unlocked door is not a resting state.**
        // `LockTile` has always said so — it draws an unlocked lock in `warning`, the same amber a
        // jam gets — and this file did not, resolving locked *and* unlocked to the same calm
        // lock-green. So the tile that made you open the sheet stopped agreeing with the sheet the
        // moment it opened: the one surface with room to act on the thing was the one that stopped
        // pointing at it. Read against the tile, not invented here.
        //
        // It tints the header icon as well as the action button below, and that is the point
        // rather than a side effect: it is the same amber on the same padlock in both places, so
        // the sheet reads as a larger version of the tile it came from.
        let accent = (unavailable || unknown) ? Color.secondary
            : ((jammed || !locked) ? HavenColor.warning : HavenColor.domain(.lock))
        VStack(spacing: 20) {
            // No `toggle:` at all, in either state — see the type's doc comment.
            // `accent` and `subtitle` above already account for unreachability *and* for `unknown`,
            // which the header cannot know about — so they stay this file's, and the header is told
            // the one thing it needs to resolve the rest. The overlap is idempotent: it resolves an
            // already-secondary accent to secondary.
            ModalHeader(systemImage: symbol, title: TileName.of(entityId, e), subtitle: subtitle,
                        accent: accent, unavailable: unavailable)
            actionButton(locked: locked, jammed: jammed, unavailable: unavailable, unknown: unknown, accent: accent)
        }
    }

    /// Lock or unlock, as one large button naming the thing it is about to do.
    ///
    /// The label is the *action*, never the current state — "Unlock" on a locked door — because a
    /// button labelled with the state it is in is the oldest ambiguity in this kind of control.
    ///
    /// The colour is the *state*, though, and comes in from `accent` above: green while the door is
    /// locked, amber while it is not. So the button says what it will do and shows what is true —
    /// "Lock" in amber on an open door, "Unlock" in green on a shut one — which is why the label
    /// never has to carry the state as well.
    ///
    /// A jammed lock still gets a button, and this is the deliberate part: its *position* is
    /// unknown, not its controls. The header's toggle used to be omitted outright when jammed,
    /// which was right for a toggle — a two-position switch has to claim a position — but leaving
    /// a jammed lock with no action at all strands the user in the one situation where they most
    /// need one. It offers "Lock" (a jam is usually a failure to close), says plainly that the
    /// position is unknown, and carries the warning colour — the same amber an unlocked door gets,
    /// which is right rather than a collision: neither one is a shut door.
    ///
    /// An `unknown` lock gets the same live button, for the same reason and worded for its own
    /// case: it has not reported a position at all (never mind reported a jam), and a tap is the
    /// one thing that might resolve that. Disabling it would take away the user's only way to
    /// find out — see the header's doc comment for why `unknown` is kept apart from `unavailable`
    /// throughout this file.
    ///
    /// **An unreachable (`unavailable`) lock is different, and gets `.disabled(true)` rather than
    /// a jammed- or unknown-style live button.** The label stays "Lock" — never "Unavailable" —
    /// because this file's own rule, two paragraphs above, is that the label is the *action*,
    /// never the current state; a disabled button that renamed itself to the state would restate
    /// the subtitle a second time and revive exactly the ambiguity this file exists to avoid.
    /// Disabling instead of merely captioning it matters behaviourally, not just visually:
    /// `HomeStore.toggleLock` now refuses an id whose `state == "unavailable"` outright, but
    /// before that guard existed a live button here would have optimistically written `state =
    /// "locked"` on tap and left it there forever — Home Assistant does not throw for an
    /// unreachable entity and pushes no state to correct it — manufacturing the very state claim
    /// this branch's thesis exists to kill.
    @ViewBuilder
    private func actionButton(locked: Bool, jammed: Bool, unavailable: Bool, unknown: Bool, accent: Color) -> some View {
        VStack(spacing: 8) {
            // `toggleLock` is correct for the jammed and unknown cases without a special path: it
            // locks anything whose state is not already `locked`, and neither `jammed` nor
            // `unknown` is `locked`. It is *not* called at all when `unavailable`, since the button
            // below is disabled in that case (and `toggleLock` itself now refuses that id too).
            Button {
                store.toggleLock(entityId)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: unavailable ? "questionmark.circle"
                          : (jammed ? "lock.fill" : (locked ? "lock.open.fill" : "lock.fill")))
                        .font(.system(size: 17, weight: .semibold))
                    Text(jammed ? "Lock" : (locked ? "Unlock" : "Lock"))
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(unavailable ? AnyShapeStyle(Color.secondary.opacity(0.4)) : AnyShapeStyle(accent)))
            }
            .buttonStyle(.plain)
            .disabled(unavailable)

            if unavailable {
                Text("This lock can't be reached right now, so its position is unknown.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else if jammed {
                Text("This lock reported a jam, so its position is unknown.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else if unknown {
                // Distinct from the jammed caption on purpose: this lock has not reported a jam —
                // it has not reported anything. Saying "can't be reached" here would be exactly
                // the false claim this file's header comment describes; this says only what is
                // true, that a position hasn't come in.
                Text("This lock hasn't reported its position yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

#if DEBUG
/// All four lock states, for the same reason `TileGallery` exists: the colour a modal draws in a
/// given state is view code with no test coverage, and this file spent a long time resolving locked
/// and unlocked to the same green without anyone noticing — because nothing renders it side by
/// side. Compare against `TileGallery`'s Lock row; the two are meant to agree.
private struct LockModalGallery: View {
    // Same shape as `TileGallery`: the store is built on the main actor and held in `@State`,
    // because `HomeStore.states` is main-actor isolated and a `#Preview` body is not.
    @State private var store = LockModalGallery.populatedStore()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                LockModal(entityId: "lock.locked")
                LockModal(entityId: "lock.unlocked")
                LockModal(entityId: "lock.jammed")
                LockModal(entityId: "lock.unavailable")
            }
            .padding()
        }
        .environment(store)
    }

    @MainActor
    private static func populatedStore() -> HomeStore {
        let store = HomeStore()
        func set(_ id: String, _ state: String, _ name: String) {
            store.states[id] = EntityState(entityId: id, state: state,
                                           attributes: ["friendly_name": .string(name)],
                                           lastUpdated: Date(timeIntervalSince1970: 0))
        }
        set("lock.locked", "locked", "Front")
        set("lock.unlocked", "unlocked", "Back")
        set("lock.jammed", "jammed", "Side")
        set("lock.unavailable", "unavailable", "Shed")
        return store
    }
}

#Preview("Lock modal — locked, unlocked, jammed, unavailable") {
    LockModalGallery()
}
#endif
