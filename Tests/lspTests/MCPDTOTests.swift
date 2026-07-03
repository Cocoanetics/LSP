import Foundation
import Testing
@testable import lsp
@testable import LSPKit

// Pins the tool-result contract: positions are 1-based, kinds and severities are
// names, and the error/warning tally matches the diagnostics. An off-by-one here
// would ship silently — the MCP client has no way to notice.

@Suite struct MCPDTOTests {
    private let range = LSPRange(
        start: LSPPosition(line: 11, character: 4),
        end: LSPPosition(line: 11, character: 10))

    @Test func checkResultTalliesAndConvertsPositions() {
        let diagnostics = [
            LSPDiagnostic(range: range, severity: 1, message: "boom"),
            LSPDiagnostic(range: range, severity: 2, message: "meh"),
            LSPDiagnostic(range: range, severity: nil, message: "unspecified = error"),
            LSPDiagnostic(range: range, severity: 4, message: "hint")
        ]
        let result = CheckResult(file: "/tmp/a.swift", diagnostics: diagnostics)
        #expect(result.errors == 2) // severity 1 + unspecified
        #expect(result.warnings == 1)
        #expect(result.diagnostics.first?.line == 12)
        #expect(result.diagnostics.first?.column == 5)
        #expect(result.diagnostics.first?.severity == "error")
        #expect(result.diagnostics.last?.severity == "hint")
    }

    @Test func symbolMatchIsOneBasedWithNamedKind() {
        let symbol = LSPSymbolInformation(
            name: "Widget", kind: LSPSymbolKind.struct.rawValue,
            location: LSPLocation(uri: "file:///Work/App/Sources/A.swift", range: range),
            containerName: "")
        let match = SymbolMatch(symbol)
        #expect(match.path == "/Work/App/Sources/A.swift")
        #expect(match.line == 12)
        #expect(match.column == 5)
        #expect(match.kind == "struct")
        #expect(match.containerName == nil) // empty container is dropped
    }

    @Test func locationIsOneBased() {
        let location = Location(LSPLocation(uri: "file:///a.swift", range: range))
        #expect(location.line == 12)
        #expect(location.column == 5)
    }

    @Test func symbolNodeUsesSelectionRangeAndPrunesEmptyChildren() {
        let symbol = LSPDocumentSymbol(
            name: "Widget", kind: LSPSymbolKind.struct.rawValue,
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 9, character: 1)),
            selectionRange: range,
            children: [])
        let node = SymbolNode(symbol)
        #expect(node.line == 12) // selectionRange, not range
        #expect(node.column == 5)
        #expect(node.children == nil)
    }
}
