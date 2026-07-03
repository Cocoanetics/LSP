import Foundation
import Testing
@testable import LSPKit

// The pure query helpers `where`/`decl` and the MCP tools funnel every symbol
// search through — scope filtering, exact matching, and hover-markdown slicing.

@Suite struct QuerySupportTests {
    @Test func baseNameDropsArgumentLabels() {
        #expect(lspBaseName(of: "MCPTool(name:description:)") == "MCPTool")
        #expect(lspBaseName(of: "greet()") == "greet")
        #expect(lspBaseName(of: "Widget") == "Widget")
    }

    @Test func scopeSplitsOnBuildCheckouts() {
        let project = "file:///Work/App/Sources/App/Main.swift"
        let dependency = "file:///Work/App/.build/checkouts/swift-nio/Sources/NIO/Channel.swift"
        #expect(LSPSymbolScope.project.includes(uri: project))
        #expect(!LSPSymbolScope.project.includes(uri: dependency))
        #expect(LSPSymbolScope.dependencies.includes(uri: dependency))
        #expect(!LSPSymbolScope.dependencies.includes(uri: project))
        #expect(LSPSymbolScope.all.includes(uri: project))
        #expect(LSPSymbolScope.all.includes(uri: dependency))
    }

    @Test func filterDropsMangledAndAppliesExact() {
        func symbol(_ name: String, uri: String = "file:///Work/App/Sources/A.swift") -> LSPSymbolInformation {
            let zero = LSPPosition(line: 0, character: 0)
            return LSPSymbolInformation(
                name: name, kind: LSPSymbolKind.class.rawValue,
                location: LSPLocation(uri: uri, range: LSPRange(start: zero, end: zero)))
        }
        let symbols = [
            symbol("Widget"),
            symbol("WidgetFactory"),
            symbol("Widget(name:)"),
            symbol("$s6WidgetV4nameSSvg"), // compiler-synthesized
            symbol("Widget", uri: "file:///Work/App/.build/checkouts/dep/Sources/D.swift")
        ]

        let fuzzy = lspFilterSymbols(symbols, query: "Widget", scope: .project, exact: false)
        #expect(fuzzy.map(\.name) == ["Widget", "WidgetFactory", "Widget(name:)"])

        let exact = lspFilterSymbols(symbols, query: "Widget", scope: .project, exact: true)
        #expect(exact.map(\.name) == ["Widget", "Widget(name:)"])
    }

    @Test func signatureExtractsFirstFence() {
        let markdown = """
        ```swift
        public struct Widget
        ```
        A widget.

        More prose.
        """
        #expect(lspSignature(fromHoverMarkdown: markdown) == "public struct Widget")
    }

    @Test func signatureFallsBackToTrimmedTextWithoutFence() {
        #expect(lspSignature(fromHoverMarkdown: "  just text  \n") == "just text")
    }

    @Test func documentationIsTheProseAfterTheSignature() {
        let markdown = """
        ```swift
        public struct Widget
        ```
        A widget.

        ```swift
        let example = Widget()
        ```
        """
        #expect(lspDocumentation(fromHoverMarkdown: markdown) == """
        A widget.

        ```swift
        let example = Widget()
        ```
        """)
    }

    @Test func documentationIsNilWhenSignatureOnly() {
        #expect(lspDocumentation(fromHoverMarkdown: "```swift\nfunc f()\n```") == nil)
        #expect(lspDocumentation(fromHoverMarkdown: "no fences at all") == nil)
    }
}
