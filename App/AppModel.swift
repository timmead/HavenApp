import SwiftUI
import HavenCore

@MainActor @Observable
final class AppModel {
    enum Phase { case loggedOut, connecting, ready, error(String) }
    var phase: Phase = .loggedOut
    var serverURLText = "http://homeassistant.local:8123"
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
        print("Haven: OAuth starting against \(url.absoluteString)")
        do {
            let t = try await oauth.login(baseURL: url, web: web, http: http)
            print("Haven: token exchange OK (access \(t.accessToken.prefix(6))…, hasRefresh=\(t.refreshToken != nil))")
            try tokens.save(t)
            await connect(token: t.accessToken)
        } catch {
            print("Haven: sign-in FAILED at OAuth/token stage: \(error)")
            phase = .error("Sign-in failed: \(error)")
        }
    }

    private func connect(token: String) async {
        guard let base = baseURL else { return }
        phase = .connecting
        let wsURL = HAConfig(baseURL: base).webSocketURL
        var attempt = 0
        while true {
            do {
                print("Haven: WS connecting to \(wsURL.absoluteString) (attempt \(attempt + 1))")
                let conn = NWWebSocketConnection(url: wsURL)
                let client = HAWebSocketClient(connection: conn)
                try await client.authenticate(token: token)
                print("Haven: WS auth_ok")
                await client.startHeartbeat()
                let home = HomeConnection(client: client)
                store.attach(home)
                try await store.bootstrap()
                print("Haven: bootstrap OK — \(store.home.floors.count) floors, \(store.states.count) entities")
                phase = .ready
                return
            } catch {
                attempt += 1
                print("Haven: connect attempt \(attempt) FAILED: \(error)")
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
