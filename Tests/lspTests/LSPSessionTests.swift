import Testing
@testable import lsp

// Path resolution for tool-supplied file arguments — no server is spawned.

@Suite struct LSPSessionTests {
    @Test func resolveTrimsAndAnchorsRelativePaths() async {
        let session = LSPSession(root: "/Work/App")

        // Agents routinely send a trailing newline; regression test for the trim.
        #expect(await session.resolve("Sources/A.swift\n") == "/Work/App/Sources/A.swift")
        #expect(await session.resolve("  Sources/A.swift  ") == "/Work/App/Sources/A.swift")

        // Absolute paths pass through untouched.
        #expect(await session.resolve("/elsewhere/B.swift") == "/elsewhere/B.swift")
    }
}
