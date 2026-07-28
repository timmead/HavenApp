import SwiftUI

/// What the app shows while it is reaching Home Assistant and has nothing worth interrupting the
/// user about.
///
/// **This is the launch experience, not an error state.** It appears on every cold launch with a
/// saved session, for the few hundred milliseconds a healthy connect takes, so it has to read as
/// the app coming up rather than as something having gone wrong. That is why there is no spinner,
/// no attempt count, and no buttons: those belong to `RootView`'s trouble screen, which takes over
/// once a connection has been going long enough to be worth explaining.
///
/// The mark is a **placeholder for the animated logo** that will replace it. Everything about it is
/// meant to be thrown away except the shape of the arrangement — one calm mark, centred, with the
/// caption subordinate to it.
struct ConnectingView: View {
    /// Honoured for the same reason `PulsingDot` honours it: a slow, indefinite, repeating
    /// animation is exactly the kind this setting exists to switch off, and a person who has asked
    /// for less motion should get a still mark rather than a breathing one.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        VStack(spacing: 22) {
            mark
            Text("Connecting…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        // One element, one label: a VoiceOver user hears the state once rather than a mark and a
        // caption separately.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connecting to Home Assistant")
    }

    /// The stand-in for the logo. A rounded square rather than a circle so that swapping in a real
    /// mark does not change the layout's centre of gravity.
    private var mark: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.accentColor.opacity(0.18))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1.5)
            }
            .overlay {
                Image(systemName: "house.fill")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 96, height: 96)
            // Scale and opacity together, gently: the point is to look alive, not to draw the eye.
            .scaleEffect(breathing ? 1.04 : 0.96)
            .opacity(breathing ? 1 : 0.72)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.3).repeatForever(autoreverses: true),
                       value: breathing)
            .onAppear { if !reduceMotion { breathing = true } }
    }
}

#if DEBUG
#Preview("Connecting") {
    ConnectingView()
}
#endif
