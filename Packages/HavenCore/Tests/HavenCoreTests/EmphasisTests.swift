import Testing
@testable import HavenCore

/// The one rule the tile sweep kept getting wrong, now in one place with a test on it.
@Suite struct EmphasisTests {
    /// Exhaustive over `CaseIterable` rather than three hand-written cases: the property is "*no*
    /// emphasis survives unreachability", and a case added later that quietly did survive is
    /// exactly the regression worth catching. A hand-written list would not have covered it.
    @Test func nothingSurvivesUnreachability() {
        for emphasis in Emphasis.allCases {
            #expect(emphasis.resolved(unavailable: true) == .secondary,
                    "\(emphasis) still asserted something about an unreachable device")
        }
    }

    /// The mirror image, and the half that stops the rule being satisfied by a function that
    /// returns `.secondary` unconditionally — which would pass the test above and render every
    /// tile in the app permanently grey.
    @Test func areachableDeviceKeepsTheEmphasisTheTileChose() {
        for emphasis in Emphasis.allCases {
            #expect(emphasis.resolved(unavailable: false) == emphasis)
        }
    }
}
