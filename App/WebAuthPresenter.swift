import AuthenticationServices
import UIKit
import HavenCore

/// The two things `WebAuthPresenter` needs from a system auth session. Exists so a test can drive
/// the cancellation path: `ASWebAuthenticationSession` presents real browser UI, so the shipping
/// type can never appear in a unit test, and the continuation-resume rules below are precisely
/// what needs covering.
@MainActor
protocol WebAuthUISession: AnyObject {
    @discardableResult func start() -> Bool
    func cancel()
}

extension ASWebAuthenticationSession: WebAuthUISession {}

/// Builds one system auth session. The context provider is passed in rather than captured so the
/// default factory can stay a plain value with no reference to the presenter that owns it.
typealias WebAuthUISessionFactory = @MainActor (
    _ url: URL,
    _ callbackScheme: String,
    _ contextProvider: any ASWebAuthenticationPresentationContextProviding,
    _ completion: @escaping @Sendable (URL?, (any Error)?) -> Void
) -> any WebAuthUISession

@MainActor
final class WebAuthPresenter: NSObject, WebAuthSession, ASWebAuthenticationPresentationContextProviding {
    private let makeSession: WebAuthUISessionFactory

    init(makeSession: @escaping WebAuthUISessionFactory = { url, scheme, context, completion in
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme,
                                                 completionHandler: completion)
        session.presentationContextProvider = context
        session.prefersEphemeralWebBrowserSession = false
        return session
    }) {
        self.makeSession = makeSession
        super.init()
    }

    /// Presents the system sign-in sheet and returns the callback URL it produces.
    ///
    /// **Two guards here, and both are load-bearing.** Without the cancellation handler, cancelling
    /// the awaiting task while the sheet is open leaves the continuation unresumed and that task
    /// hangs for the life of the process. That is reachable in the shipping app, not a theoretical
    /// concern: `signIn()` awaits this, and `signOut()`/`requireReauthentication()` cancel the
    /// `connectTask` it runs inside. Without the resume-once gate in `SessionState`, a `cancel()`
    /// that *also* fires the completion handler resumes twice, which traps rather than throws.
    ///
    /// Whether `ASWebAuthenticationSession.cancel()` invokes its completion handler is not
    /// reliably documented, so this is written to be correct either way rather than to match one
    /// reading of it: `cancel()` resumes with `CancellationError` itself, and the gate makes a
    /// completion that arrives afterwards a no-op. `WebAuthCancellationTests` pins both directions
    /// — one fake stays silent on cancel, the other fires — so neither behaviour can regress.
    nonisolated func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        let state = SessionState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                Task { @MainActor in
                    // Resumes immediately if cancellation already ran — see `attach`.
                    state.attach(cont)
                    // Starting a sheet nobody is waiting for would present browser UI over an app
                    // that has already signed out.
                    guard !state.isCancelled else { return }
                    let session = self.makeSession(url, callbackScheme, self) { cb, err in
                        Task { @MainActor in
                            if let cb { state.finish(.success(cb)) }
                            else {
                                state.finish(.failure(
                                    err ?? WSError(code: "oauth", message: "cancelled")))
                            }
                        }
                    }
                    state.session = session
                    session.start()
                }
            }
        } onCancel: {
            Task { @MainActor in state.cancel() }
        }
    }

    /// The state shared between the continuation body, the completion handler and the cancellation
    /// handler, isolated to the main actor so all three agree on who resumed first.
    ///
    /// It exists because the three run in an order nothing controls. The session is created inside
    /// a nested `Task`, so cancellation can arrive before there is anything to cancel — hence
    /// `isCancelled` being checked after `attach`, and a result being held until a continuation
    /// shows up to receive it.
    @MainActor
    private final class SessionState {
        var session: (any WebAuthUISession)?
        private(set) var isCancelled = false
        private var continuation: CheckedContinuation<URL, any Error>?
        /// A result that arrived before the continuation did, waiting to be handed over.
        private var pending: Result<URL, any Error>?
        private var hasResumed = false

        nonisolated init() {}

        func attach(_ cont: CheckedContinuation<URL, any Error>) {
            guard !hasResumed else { return }
            if let pending {
                hasResumed = true
                self.pending = nil
                cont.resume(with: pending)
                return
            }
            continuation = cont
        }

        /// Resumes the continuation, or records the result until one arrives. Only the first call
        /// has any effect.
        func finish(_ result: Result<URL, any Error>) {
            guard !hasResumed else { return }
            guard let cont = continuation else {
                pending = result
                return
            }
            hasResumed = true
            continuation = nil
            cont.resume(with: result)
        }

        /// Closes the sheet and ends the await.
        ///
        /// Resumes with `CancellationError` rather than trusting `cancel()` to fire the completion
        /// handler. If it does fire, `finish`'s gate discards the second result; if it does not,
        /// this is the only thing that unblocks the caller.
        func cancel() {
            isCancelled = true
            session?.cancel()
            session = nil
            finish(.failure(CancellationError()))
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
