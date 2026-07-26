import SwiftUI
import HavenCore

/// Renders whatever `HavenOnboardingStep.presentation` says and forwards the user's taps. There is
/// deliberately no `if` about onboarding *logic* anywhere below — no "which step is this", no
/// "should this be confirmed", no "did it work". Those all live in HavenCore, where they're
/// tested; this target has no test bundle. The only branching here is presentational: show a hint
/// row if there is one, show a button if there's a label for it.
struct OnboardingView: View {
    @Environment(\.openURL) private var openURL
    let model: OnboardingModel

    var body: some View {
        let p = model.presentation
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(p)
                    Text(p.explanation)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let hint = p.didNotLandHint { notice(hint, symbol: "clock.badge.questionmark") }
                    if let failure = model.failureMessage { notice(failure, symbol: "exclamationmark.triangle") }
                    if model.flow.isAwaitingRestart { waitingForRestart }
                    actions(p)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Set up Haven")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Not now") { model.isPresented = false }
                }
            }
            .alert(
                model.pendingConfirmation?.title ?? "",
                isPresented: Binding(
                    get: { model.pendingConfirmation != nil },
                    set: { if !$0 { model.cancelConfirmation() } }
                ),
                presenting: model.pendingConfirmation
            ) { confirmation in
                Button(confirmation.confirmLabel, role: confirmation.isDestructive ? .destructive : nil) {
                    Task { await model.confirmPendingMutation() }
                }
                Button("Cancel", role: .cancel) { model.cancelConfirmation() }
            } message: { confirmation in
                Text(confirmation.message)
            }
        }
    }

    private func header(_ p: HavenOnboardingPresentation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: p.symbolName)
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            Text(p.title)
                .font(.system(size: 20, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A muted attention row — used both for "the step you just took hasn't shown up yet" and for
    /// a failed call's own message. Same treatment for both: neither is an error the user caused.
    private func notice(_ text: String, symbol: String) -> some View {
        FacetCard {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(HavenColor.warning)
                Text(text)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var waitingForRestart: some View {
        FacetCard {
            HStack(spacing: 9) {
                ProgressView()
                Text("Waiting for Home Assistant to come back…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actions(_ p: HavenOnboardingPresentation) -> some View {
        VStack(spacing: 10) {
            if let label = p.actionLabel {
                Button(label) { model.performPrimaryAction { openURL($0) } }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(model.isBusy || model.flow.isAwaitingRestart)
            }
            if p.allowsRecheck {
                Button("Check again") { Task { await model.probe() } }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(model.isBusy || model.flow.isAwaitingRestart)
            }
            if model.isBusy { ProgressView() }
        }
        .padding(.top, 4)
    }
}
