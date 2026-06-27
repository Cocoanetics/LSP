import Foundation
import LSPKit

// JSON shapes the tools return to the MCP client. Positions are 1-based and paths
// are absolute filesystem paths (unambiguous for the agent). Symbol kinds and
// diagnostic severities are rendered as names, not raw LSP integers.

/// `check_file` result: the diagnostics plus a quick error/warning tally.
struct CheckResult: Codable, Sendable {
    var file: String
    var errors: Int
    var warnings: Int
    var diagnostics: [DiagnosticItem]

    init(file: String, diagnostics: [LSPDiagnostic]) {
        self.file = file
        self.errors = diagnostics.filter { $0.severity == 1 }.count
        self.warnings = diagnostics.filter { $0.severity == 2 }.count
        self.diagnostics = diagnostics.map(DiagnosticItem.init)
    }
}

/// One diagnostic at a 1-based position.
struct DiagnosticItem: Codable, Sendable {
    var severity: String
    var line: Int
    var column: Int
    var message: String

    init(_ diagnostic: LSPDiagnostic) {
        self.severity = severityName(diagnostic.severity)
        self.line = diagnostic.range.start.line + 1
        self.column = diagnostic.range.start.character + 1
        self.message = diagnostic.message
    }
}

/// A `find_symbol` hit.
struct SymbolMatch: Codable, Sendable {
    var name: String
    var kind: String
    var containerName: String?
    var path: String
    var line: Int
    var column: Int

    init(_ symbol: LSPSymbolInformation) {
        self.name = symbol.name
        self.kind = symbol.symbolKind?.displayName ?? "kind \(symbol.kind)"
        self.containerName = symbol.containerName?.isEmpty == false ? symbol.containerName : nil
        let start = symbol.location.range.start
        self.path = LSPURI.path(symbol.location.uri) ?? symbol.location.uri
        self.line = start.line + 1
        self.column = start.character + 1
    }
}

/// A `declaration` hit: the symbol plus its resolved declaration text.
struct DeclarationMatch: Codable, Sendable {
    var name: String
    var kind: String
    var containerName: String?
    var path: String
    var line: Int
    var column: Int
    var signature: String?
    var documentation: String?

    init(_ symbol: LSPSymbolInformation, signature: String?, documentation: String?) {
        let match = SymbolMatch(symbol)
        self.name = match.name
        self.kind = match.kind
        self.containerName = match.containerName
        self.path = match.path
        self.line = match.line
        self.column = match.column
        self.signature = signature
        self.documentation = documentation
    }
}

/// A `file:line:column` location (1-based).
struct Location: Codable, Sendable {
    var path: String
    var line: Int
    var column: Int

    init(_ location: LSPLocation) {
        let start = location.range.start
        self.path = LSPURI.path(location.uri) ?? location.uri
        self.line = start.line + 1
        self.column = start.character + 1
    }
}

/// A node of the `document_symbols` hierarchy.
struct SymbolNode: Codable, Sendable {
    var name: String
    var kind: String
    var line: Int
    var column: Int
    var children: [SymbolNode]?

    init(_ symbol: LSPDocumentSymbol) {
        self.name = symbol.name
        self.kind = symbol.symbolKind?.displayName ?? "kind \(symbol.kind)"
        self.line = symbol.selectionRange.start.line + 1
        self.column = symbol.selectionRange.start.character + 1
        let children = (symbol.children ?? []).map(SymbolNode.init)
        self.children = children.isEmpty ? nil : children
    }
}

// `severityName(_:)` is shared with the CLI commands (see Support/Output.swift).
