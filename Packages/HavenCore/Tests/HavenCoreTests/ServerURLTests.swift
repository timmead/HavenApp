import Foundation
import Testing
@testable import HavenCore

@Suite struct ServerURLTests {
    private func host(_ typed: String) -> String? {
        guard case .success(let url) = ServerURL.normalize(typed) else { return nil }
        return url.host()
    }

    private func failure(_ typed: String) -> ServerURL.Invalid? {
        guard case .failure(let reason) = ServerURL.normalize(typed) else { return nil }
        return reason
    }

    // MARK: - The tolerance this exists for

    @Test func acceptsABareHostAndPort() {
        #expect(host("homeassistant.local:8123") == "homeassistant.local")
        #expect(host("192.168.1.10:8123") == "192.168.1.10")
        // The colon after the host must not be mistaken for a scheme separator.
        #expect(host("ha:8123") == "ha")
    }

    @Test func acceptsBothSupportedSchemes() {
        #expect(host("http://homeassistant.local:8123") == "homeassistant.local")
        #expect(host("https://abc.ui.nabu.casa") == "abc.ui.nabu.casa")
        #expect(host("HTTPS://ABC.UI.NABU.CASA") == "ABC.UI.NABU.CASA")
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(host("  homeassistant.local:8123\n") == "homeassistant.local")
    }

    // MARK: - The bug: a mistyped scheme was rewritten, not rejected

    /// Each of these previously became `http://<the whole thing>`, which parsed cleanly with the
    /// broken scheme as the *host* and satisfied a guard that reads as though it forbids exactly
    /// that. A dropped or transposed character in `http://` is an ordinary typo, and the old
    /// behaviour turned it into an authentication attempt against a host the user never named —
    /// then saved it.
    @Test func rejectsAMistypedSchemeInsteadOfRewritingIt() {
        // The colon is missing, so `http` would otherwise be taken as the host.
        #expect(host("http//homeassistant.local") != "http")
        #expect(failure("http//homeassistant.local") == .malformedScheme("http"))
        #expect(failure("https//homeassistant.local") == .malformedScheme("https"))

        // Transposed letters — a scheme, just not one we speak.
        #expect(host("htp://homeassistant.local") != "htp")
        #expect(failure("htp://homeassistant.local") == .unsupportedScheme("htp"))
    }

    /// A hostname containing dots and a port is the exact input the tolerant branch exists for,
    /// and RFC 3986 permits `.` inside a scheme name — so recognising a scheme by its colon alone
    /// would reject `homeassistant.local:8123` as a scheme called `homeassistant.local`.
    /// Recognising it by the following `//` is what keeps the two apart.
    @Test func aDottedHostWithAPortIsNotAScheme() {
        #expect(host("homeassistant.local:8123") == "homeassistant.local")
        #expect(failure("homeassistant.local:8123") == nil)
    }

    @Test func rejectsSchemesWeCannotSpeak() {
        #expect(failure("ftp://homeassistant.local:8123") == .unsupportedScheme("ftp"))
        // Home Assistant's own companion-app scheme is a plausible paste, and is still not
        // something this app can open a WebSocket to.
        #expect(failure("homeassistant://navigate/lovelace") == .unsupportedScheme("homeassistant"))
    }

    /// The message names what was typed rather than saying "invalid URL" about something the user
    /// can plainly see is a URL.
    @Test func theUnsupportedSchemeMessageNamesTheScheme() {
        #expect(failure("ftp://ha.local")?.message.contains("ftp") == true)
    }

    // MARK: - Nothing without a host

    @Test func rejectsEmptyInput() {
        #expect(failure("") == .empty)
        #expect(failure("   ") == .empty)
    }

    @Test func rejectsAnAddressWithNoHost() {
        #expect(failure("http://") == .noHost)
        #expect(failure("http://:8123") == .noHost)
    }
}
