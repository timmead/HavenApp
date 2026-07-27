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
        let subtitle = jammed ? "Jammed" : (locked ? "Locked" : "Unlocked")
        let symbol = jammed ? "lock.trianglebadge.exclamationmark" : (locked ? "lock.fill" : "lock.open.fill")
        let accent = jammed ? HavenColor.warning : HavenColor.domain(.lock)
        VStack(spacing: 20) {
            // No `toggle:` at all, in either state — see the type's doc comment.
            ModalHeader(systemImage: symbol, title: TileName.of(entityId, e), subtitle: subtitle, accent: accent)
            actionButton(locked: locked, jammed: jammed, accent: accent)
        }
    }

    /// Lock or unlock, as one large button naming the thing it is about to do.
    ///
    /// The label is the *action*, never the current state — "Unlock" on a locked door — because a
    /// button labelled with the state it is in is the oldest ambiguity in this kind of control.
    ///
    /// A jammed lock still gets a button, and this is the deliberate part: its *position* is
    /// unknown, not its controls. The header's toggle used to be omitted outright when jammed,
    /// which was right for a toggle — a two-position switch has to claim a position — but leaving
    /// a jammed lock with no action at all strands the user in the one situation where they most
    /// need one. It offers "Lock" (a jam is usually a failure to close), says plainly that the
    /// position is unknown, and carries the warning colour.
    @ViewBuilder
    private func actionButton(locked: Bool, jammed: Bool, accent: Color) -> some View {
        VStack(spacing: 8) {
            // `toggleLock` is correct for the jammed case without a special path: it locks anything
            // whose state is not already `locked`, and `jammed` is not `locked`.
            Button {
                store.toggleLock(entityId)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: jammed ? "lock.fill" : (locked ? "lock.open.fill" : "lock.fill"))
                        .font(.system(size: 17, weight: .semibold))
                    Text(jammed ? "Lock" : (locked ? "Unlock" : "Lock"))
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(accent))
            }
            .buttonStyle(.plain)

            if jammed {
                Text("This lock reported a jam, so its position is unknown.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
