import Foundation
import Testing
@testable import LSPKit

// Path ⇄ URI conversion and project-root discovery — every query passes its
// file argument through these before it reaches the server.

@Suite struct PathHelperTests {
    @Test func uriRoundTripsPathsWithSpaces() {
        let path = "/tmp/My Project/File.swift"
        let uri = LSPURI.file(path)
        #expect(uri.hasPrefix("file://"))
        #expect(uri.contains("%20"))
        #expect(LSPURI.path(uri) == path)
    }

    @Test func pathRejectsNonFileURIs() {
        #expect(LSPURI.path("https://example.com/a.swift") == nil)
        #expect(LSPURI.path("not a uri") == nil)
    }

    @Test func documentKeyCollapsesURIAndPathSpellings() {
        let path = "/tmp/Project/Sources/../Sources/File.swift"
        let viaURI = LSPClient.documentKey(LSPURI.file("/tmp/Project/Sources/File.swift"))
        let viaPath = LSPClient.documentKey(path)
        #expect(viaURI == viaPath)
    }

    @Test func projectRootWalksUpToPackageSwift() throws {
        let base = NSTemporaryDirectory() + "lspkit-root-" + UUID().uuidString
        let nested = base + "/Sources/Demo"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        FileManager.default.createFile(atPath: base + "/Package.swift", contents: Data())
        FileManager.default.createFile(atPath: nested + "/Demo.swift", contents: Data())

        #expect(enclosingProjectRoot(for: nested + "/Demo.swift") == base)
        #expect(enclosingProjectRoot(for: nested) == base)
    }

    @Test func projectRootFallsBackToTheInputsOwnDirectory() throws {
        // No Package.swift anywhere up the temp tree segment we create.
        let base = NSTemporaryDirectory() + "lspkit-noroot-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let file = base + "/Loose.swift"
        FileManager.default.createFile(atPath: file, contents: Data())

        // For a file: its directory. For a directory: the directory itself —
        // not its parent.
        #expect(enclosingProjectRoot(for: file) == base)
        #expect(enclosingProjectRoot(for: base) == base)
    }

    @Test func languageIdCoversTheCFamilyAndFallsBackToSwift() {
        #expect(lspLanguageId(forPath: "a.m") == "objective-c")
        #expect(lspLanguageId(forPath: "a.mm") == "objective-cpp")
        #expect(lspLanguageId(forPath: "a.hpp") == "cpp")
        #expect(lspLanguageId(forPath: "a.CC") == "cpp")
        #expect(lspLanguageId(forPath: "a.unknown") == "swift")
    }
}
