import Testing
@testable import lsp
@testable import LSPKit

// The strings every CLI result is rendered through.

@Suite struct OutputTests {
    @Test func shortenMakesProjectPathsRelative() {
        let uri = "file:///Work/App/Sources/App/Main.swift"
        #expect(shorten(uri, root: "/Work/App") == "Sources/App/Main.swift")
        #expect(shorten(uri, root: "/Work/App/") == "Sources/App/Main.swift")
    }

    @Test func shortenStripsCheckoutsPrefixForDependencies() {
        let uri = "file:///Work/App/.build/checkouts/swift-nio/Sources/NIO/Channel.swift"
        #expect(shorten(uri, root: "/Work/App") == "swift-nio/Sources/NIO/Channel.swift")
    }

    @Test func shortenLeavesForeignPathsAbsolute() {
        #expect(shorten("file:///Other/Place/File.swift", root: "/Work/App") == "/Other/Place/File.swift")
    }

    @Test func severityNamesFollowTheLSPSpec() {
        #expect(severityName(1) == "error")
        #expect(severityName(2) == "warning")
        #expect(severityName(3) == "information")
        #expect(severityName(4) == "hint")
        #expect(severityName(nil) == "error") // unspecified is an error per spec
    }

    @Test func formatLocationIsOneBased() {
        let location = LSPLocation(
            uri: "file:///Work/App/Sources/A.swift",
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 3)))
        #expect(formatLocation(location, root: "/Work/App") == "Sources/A.swift:1:1")
    }
}
