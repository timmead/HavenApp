import SwiftUI
import HavenCore

@MainActor @Observable
final class AppModel {
    enum Phase { case loggedOut, connecting, retrying(attempt: Int), ready, error(String) }
    var phase: Phase = .loggedOut
    var serverURLText = "http://homeassistant.local:8123"
    let store = HomeStore()

    private let tokens: TokenStore = KeychainTokenStore()
    private let oauth = OAuthClient()
    private let http = URLSessionHTTP()
    private let web = WebAuthPresenter()
    private let policy = ReconnectPolicy()
    private var baseURL: URL?
    private var tokenProvider: TokenProvider?
    /// The active connect loop. Retrying is now unbounded, so this must be explicitly
    /// cancellable — otherwise a stale loop from a previous session could keep retrying in the
    /// background and later flip `phase` back to `.ready` after a `signOut()`.
    private var connectTask: Task<Void, Never>?

    func restoreIfPossible() async {
        guard tokens.load() != nil, let url = savedBaseURL() else { return }
        baseURL = url
        tokenProvider = TokenProvider(baseURL: url, store: tokens, oauth: oauth, http: http)
        await startConnecting()
    }

    func signIn() async {
        let raw = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate a missing scheme (users often type just "homeassistant.local:8123").
        let hasScheme = raw.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) != nil
        let normalized = hasScheme ? raw : "http://\(raw)"
        guard !raw.isEmpty,
              let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else {
            phase = .error("Enter a valid URL like http://homeassistant.local:8123"); return
        }
        serverURLText = normalized
        baseURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: "baseURL")
        phase = .connecting
        havenLog.info("OAuth starting against \(url.absoluteString, privacy: .public)")
        do {
            let t = try await oauth.login(baseURL: url, web: web, http: http)
            havenLog.info("token exchange OK (hasRefresh=\(t.refreshToken != nil, privacy: .public))")
            try tokens.save(t)
            tokenProvider = TokenProvider(baseURL: url, store: tokens, oauth: oauth, http: http)
            await startConnecting()
        } catch {
            havenLog.error("sign-in failed at OAuth/token stage: \(error, privacy: .public)")
            phase = .error("Sign-in failed: \(error.localizedDescription)")
        }
    }

    /// Clear the saved session and return to the login screen (also used to change server).
    func signOut() {
        connectTask?.cancel(); connectTask = nil
        tokens.clear()
        UserDefaults.standard.removeObject(forKey: "baseURL")
        baseURL = nil
        tokenProvider = nil
        store.reset()
        phase = .loggedOut
    }

    /// The stored session can no longer produce a usable token — either the refresh grant was
    /// itself invalid/revoked, or Home Assistant rejected the (freshly refreshed) token outright.
    /// Unlike `signOut()`, this keeps the server URL around so the user only has to re-authorize,
    /// not retype the host.
    private func requireReauthentication() {
        connectTask?.cancel(); connectTask = nil
        tokens.clear()
        tokenProvider = nil
        store.reset()
        phase = .loggedOut
    }

    /// Runs `connect()` in a cancellable task. Retrying is unbounded, so a stale loop from a
    /// previous session must be stoppable — otherwise it could keep retrying in the background
    /// and later flip `phase` back to `.ready` after a `signOut()`/`requireReauthentication()`.
    private func startConnecting() async {
        connectTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.connect()
        }
        connectTask = task
        await task.value
    }

    private func connect() async {
        guard let base = baseURL, let tokenProvider else { return }
        phase = .connecting
        let wsURL = HAConfig(baseURL: base).webSocketURL
        var attempt = 0
        // Home Assistant can reject a token TokenProvider believed was still valid (revoked out
        // of band, or clock skew) — allow exactly one forced refresh to recover from that before
        // treating a further rejection as terminal.
        var didForceRefreshAfterAuthInvalid = false
        while true {
            if Task.isCancelled { return }
            do {
                let token = try await tokenProvider.validAccessToken(now: Date())
                havenLog.info("WS connecting to \(wsURL.absoluteString, privacy: .public) (attempt \(attempt + 1, privacy: .public))")
                let conn = NWWebSocketConnection(url: wsURL)
                let client = HAWebSocketClient(connection: conn)
                try await client.authenticate(token: token)
                havenLog.info("WS auth_ok")
                await client.startHeartbeat()
                let home = HomeConnection(client: client)
                store.attach(home)
                try await store.bootstrap()
                havenLog.info("bootstrap OK — \(self.store.home.floors.count, privacy: .public) floors, \(self.store.states.count, privacy: .public) entities")
                if Task.isCancelled { return }
                phase = .ready
                return
            } catch TokenProviderError.reauthenticationRequired {
                havenLog.error("token refresh requires reauthentication — signing out")
                requireReauthentication()
                return
            } catch let wsError as WSError where wsError.code == "auth_invalid" {
                guard !didForceRefreshAfterAuthInvalid else {
                    havenLog.error("token still invalid after a forced refresh — signing out")
                    requireReauthentication()
                    return
                }
                didForceRefreshAfterAuthInvalid = true
                havenLog.error("Home Assistant rejected the access token as invalid — forcing a refresh")
                do {
                    _ = try await tokenProvider.forceRefresh()
                    // Retry immediately with the fresh token; doesn't count as a backoff attempt.
                } catch TokenProviderError.reauthenticationRequired {
                    havenLog.error("forced refresh requires reauthentication — signing out")
                    requireReauthentication()
                    return
                } catch {
                    attempt += 1
                    havenLog.error("forced refresh failed: \(error, privacy: .public)")
                    phase = .retrying(attempt: attempt)
                    try? await Task.sleep(for: policy.delay(forAttempt: attempt))
                }
            } catch {
                attempt += 1
                havenLog.error("connect attempt \(attempt, privacy: .public) failed: \(error, privacy: .public)")
                phase = .retrying(attempt: attempt)
                try? await Task.sleep(for: policy.delay(forAttempt: attempt))
            }
        }
    }

    private func savedBaseURL() -> URL? {
        UserDefaults.standard.string(forKey: "baseURL").flatMap(URL.init(string:))
    }
}
