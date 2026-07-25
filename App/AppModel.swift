import SwiftUI
import HavenCore

@MainActor @Observable
final class AppModel {
    enum Phase { case loggedOut, connecting, ready, error(String) }
    var phase: Phase = .loggedOut
    var serverURLText = ""
    let store = HomeStore()

    private let maxConnectAttempts = 5
    private let tokens: TokenStore = KeychainTokenStore()
    private let oauth = OAuthClient()
    private let http = URLSessionHTTP()
    private let web = WebAuthPresenter()
    private let policy = ReconnectPolicy()
    private var baseURL: URL?

    func restoreIfPossible() async {
        guard let saved = tokens.load(), let url = savedBaseURL() else { return }
        baseURL = url
        await connect(token: saved.accessToken)
    }

    func signIn() async {
        guard let url = URL(string: serverURLText),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            phase = .error("Enter a valid URL like http://homeassistant.local:8123"); return
        }
        baseURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: "baseURL")
        phase = .connecting
        do {
            let t = try await oauth.login(baseURL: url, web: web, http: http)
            try tokens.save(t)
            await connect(token: t.accessToken)
        } catch { phase = .error("Sign-in failed: \(error)") }
    }

    private func connect(token: String) async {
        guard let base = baseURL else { return }
        phase = .connecting
        var attempt = 0
        while true {
            do {
                let conn = URLSessionWebSocketConnection(url: HAConfig(baseURL: base).webSocketURL)
                let client = HAWebSocketClient(connection: conn)
                try await client.authenticate(token: token)
                await client.startHeartbeat()
                let home = HomeConnection(client: client)
                store.attach(home)
                try await store.bootstrap()
                phase = .ready
                return
            } catch {
                attempt += 1
                if attempt >= maxConnectAttempts {
                    phase = .error("Couldn't connect after \(attempt) attempts. Check the server URL and sign in again.")
                    return
                }
                phase = .error("Connection lost — retrying… (\(attempt))")
                try? await Task.sleep(for: policy.delay(forAttempt: attempt))
            }
        }
    }

    private func savedBaseURL() -> URL? {
        UserDefaults.standard.string(forKey: "baseURL").flatMap(URL.init(string:))
    }
}
