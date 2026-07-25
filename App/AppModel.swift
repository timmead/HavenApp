import SwiftUI
import HavenCore

@MainActor @Observable
final class AppModel {
    enum Phase { case loggedOut, connecting, ready, error(String) }
    var phase: Phase = .loggedOut
    var serverURLText = ""
    let store = HomeStore()

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
        guard let url = URL(string: serverURLText), url.scheme != nil else {
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
                phase = .error("Connection lost — retrying…")
                try? await Task.sleep(for: policy.delay(forAttempt: attempt))
            }
        }
    }

    private func savedBaseURL() -> URL? {
        UserDefaults.standard.string(forKey: "baseURL").flatMap(URL.init(string:))
    }
}
