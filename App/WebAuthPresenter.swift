import AuthenticationServices
import UIKit
import HavenCore

@MainActor
final class WebAuthPresenter: NSObject, WebAuthSession, ASWebAuthenticationPresentationContextProviding {
    nonisolated func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            Task { @MainActor in
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { cb, err in
                    if let cb { cont.resume(returning: cb) }
                    else { cont.resume(throwing: err ?? WSError(code: "oauth", message: "cancelled")) }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                session.start()
            }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
