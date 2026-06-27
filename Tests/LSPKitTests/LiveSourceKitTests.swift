import Foundation
import Testing
@testable import LSPKit

/// Drives a real `sourcekit-lsp` end-to-end over JSONFoundation's unified JSON-RPC
/// runtime — the Swift equivalent of `probe.py`, and the proof that LSPKit speaks
/// the `Content-Length` wire correctly. Skips (rather than fails) where
/// `sourcekit-lsp` isn't installed, so it's safe on CI without a toolchain.
@Suite struct LiveSourceKitTests {
    @Test func handshakeOpensFileAndListsSymbols() async throws {
        guard sourceKitAvailable() else {
            print("skipping: sourcekit-lsp not found")
            return
        }

        // A self-contained temp package so `rootUri` points at a real project.
        let root = try makeTempPackage(source: """
        public struct Widget {
            public var name: String
            public func greet() -> String { "hi, \\(name)" }
        }

        public enum Color { case red, green, blue }
        """)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let file = root + "/Sources/Demo/Demo.swift"

        let client = try LSPClient(launch: LSPServer.sourceKit())
        await client.start()

        let initialize = try await client.initialize(rootURI: LSPURI.file(root))
        #expect(initialize.capabilityNames.contains("documentSymbolProvider"))

        try await client.initialized()
        try await client.didOpen(path: file)

        let symbols = try await client.documentSymbol(path: file)
        let names = symbols.map(\.name)
        #expect(names.contains("Widget"))
        #expect(names.contains("Color"))

        if let widget = symbols.first(where: { $0.name == "Widget" }) {
            #expect(widget.symbolKind == .struct)
            #expect(widget.children?.contains { $0.name == "greet()" } == true)
        }

        await client.shutdownAndExit()
    }

    // MARK: - Helpers

    private func sourceKitAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "sourcekit-lsp"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func makeTempPackage(source: String) throws -> String {
        let base = NSTemporaryDirectory() + "lspkit-test-" + UUID().uuidString
        let demo = base + "/Sources/Demo"
        try FileManager.default.createDirectory(atPath: demo, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.1
        import PackageDescription
        let package = Package(name: "Demo", targets: [.target(name: "Demo")])
        """.write(toFile: base + "/Package.swift", atomically: true, encoding: .utf8)
        try source.write(toFile: demo + "/Demo.swift", atomically: true, encoding: .utf8)
        return base
    }
}
