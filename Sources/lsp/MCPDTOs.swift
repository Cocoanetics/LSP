import Foundation
import LSPKit
import SwiftMCP

// JSON shapes the tools return to the MCP client. Positions are 1-based and paths
// are absolute filesystem paths (unambiguous for the agent). Symbol kinds and
// diagnostic severities are rendered as names, not raw LSP integers.
//
// `@Schema` (JSONFoundation, re-exported by SwiftMCP) makes each type
// `SchemaRepresentable`, so the tools advertise a structured `outputSchema` built
// from the doc comments below — the agent sees the field semantics up front.

/// `check_file` result: the diagnostics plus a quick error/warning tally.
@Schema
struct CheckResult: Codable, Sendable {
    /// The checked file, as an absolute path.
    var file: String
    /// How many diagnostics are errors.
    var errors: Int
    /// How many diagnostics are warnings.
    var warnings: Int
    var diagnostics: [DiagnosticItem]

    init(file: String, diagnostics: [LSPDiagnostic]) {
        let tally = diagnosticTally(diagnostics)
        self.file = file
        self.errors = tally.errors
        self.warnings = tally.warnings
        self.diagnostics = diagnostics.map(DiagnosticItem.init)
    }
}

/// One diagnostic at a 1-based position.
@Schema
struct DiagnosticItem: Codable, Sendable {
    /// `error`, `warning`, `information`, or `hint`.
    var severity: String
    /// 1-based line number.
    var line: Int
    /// 1-based column number.
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
@Schema
struct SymbolMatch: Codable, Sendable {
    var name: String
    /// The symbol kind as a name (`class`, `function`, …).
    var kind: String
    /// The enclosing symbol (a type, extension, or file), when the server reports one.
    var containerName: String?
    /// Absolute filesystem path to the declaring file.
    var path: String
    /// 1-based line number.
    var line: Int
    /// 1-based column number.
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
@Schema
struct DeclarationMatch: Codable, Sendable {
    var name: String
    /// The symbol kind as a name (`class`, `function`, …).
    var kind: String
    /// The enclosing symbol (a type, extension, or file), when the server reports one.
    var containerName: String?
    /// Absolute filesystem path to the declaring file.
    var path: String
    /// 1-based line number.
    var line: Int
    /// 1-based column number.
    var column: Int
    /// The declaration signature (the hover's fenced code block).
    var signature: String?
    /// The doc-comment prose, when requested and present.
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
@Schema
struct Location: Codable, Sendable {
    /// Absolute filesystem path.
    var path: String
    /// 1-based line number.
    var line: Int
    /// 1-based column number.
    var column: Int

    init(_ location: LSPLocation) {
        let start = location.range.start
        self.path = LSPURI.path(location.uri) ?? location.uri
        self.line = start.line + 1
        self.column = start.character + 1
    }
}

/// A node of the `document_symbols` hierarchy.
///
/// Deliberately *not* `@Schema`: the recursive `children` property would send the
/// schema generator into unbounded recursion. `document_symbols` stays without an
/// advertised output schema.
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

// `severityName(_:)` and `diagnosticTally(_:)` are shared with the CLI commands
// (see Support/Output.swift).
