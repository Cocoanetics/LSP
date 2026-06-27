import Foundation
import LSPKit
import SwiftMCP

/// An MCP server exposing `sourcekit-lsp`'s code intelligence as tools, backed by a
/// warm `LSPSession`. The headline use is `check_file`: validate an edit's syntax
/// and semantics before paying for a full build or test run. Symbol search, hover,
/// definition, and references round out an LLM's "interrogate the code" loop.
///
/// Positions are **1-based** here (line 1 = first line, column 1 = first character),
/// matching what an editor shows; they're converted to LSP's 0-based internally.
@MCPServer(name: "lsp", version: "0.1.0")
actor LSPMCPServer {
    private let session: LSPSession

    init(session: LSPSession) {
        self.session = session
    }

    /// Cleanly terminate the language server when the transport stops.
    func shutdown() async {
        await session.shutdown()
    }

    // MARK: - Diagnostics

    /// Check a file for errors and warnings using the language server's in-memory
    /// type-check — syntax errors, undefined types/symbols, and type mismatches —
    /// without running a build. Call this to validate a freshly edited file before
    /// kicking off a full build or test run.
    /// - Parameter file: Path to the file to check (absolute, or relative to the project root).
    @MCPTool
    func check_file(file: String) async throws -> CheckResult {
        let client = try await session.client()
        let path = await session.resolve(file)
        // Semantic diagnostics need the file's target prepared; `prepareIndex` blocks
        // on `workspace/synchronize` to ensure that. The cost is paid once — the warm
        // session keeps the index ready for later checks.
        let diagnostics = try await client.diagnostics(forPath: path, prepareIndex: true)
        return CheckResult(file: path, diagnostics: diagnostics)
    }

    // MARK: - Symbol search

    /// Find symbols by name across the whole project (index-backed fuzzy search) —
    /// the way to turn a name into file locations without reading files.
    /// - Parameter query: The symbol name (or fragment) to search for.
    /// - Parameter scope: Which sources to search: "project" (default), "dependencies", or "all".
    /// - Parameter exact: When true, return only symbols whose name is exactly `query`.
    @MCPTool
    func find_symbol(query: String, scope: String = "project", exact: Bool = false) async throws -> [SymbolMatch] {
        try await searchSymbols(query: query, scope: scope, exact: exact).map(SymbolMatch.init)
    }

    /// Show a symbol's declaration — its signature, and optionally its doc comment —
    /// found by name across the project. Returns one entry per match (overloads,
    /// same-named types, …).
    /// - Parameter query: The symbol name to look up.
    /// - Parameter scope: Which sources to search: "project" (default), "dependencies", or "all".
    /// - Parameter exact: When true, only symbols whose name is exactly `query`.
    /// - Parameter includeDocumentation: When true, include the full doc comment, not just the signature.
    @MCPTool
    func declaration(
        query: String, scope: String = "project", exact: Bool = false, includeDocumentation: Bool = false
    ) async throws -> [DeclarationMatch] {
        let client = try await session.client()
        let matches = try await searchSymbols(query: query, scope: scope, exact: exact)
        var results: [DeclarationMatch] = []
        for symbol in matches {
            guard let path = LSPURI.path(symbol.location.uri) else { continue }
            _ = try? await client.syncDocument(path: path)
            let start = symbol.location.range.start
            let hover = try? await client.hover(path: path, line: start.line, character: start.character)
            results.append(DeclarationMatch(
                symbol,
                signature: hover.map { lspSignature(fromHoverMarkdown: $0.value) },
                documentation: includeDocumentation ? hover?.value : nil))
        }
        return results
    }

    // MARK: - Position queries

    /// Get hover information (type, signature, documentation) for the symbol at a
    /// position in a file. Returns the rendered Markdown, or a note if there's none.
    /// - Parameter file: Path to the file (absolute, or relative to the project root).
    /// - Parameter line: 1-based line number.
    /// - Parameter column: 1-based column number.
    @MCPTool
    func hover(file: String, line: Int, column: Int) async throws -> String {
        let (client, path) = try await openedClient(forFile: file)
        let hover = try await client.hover(path: path, line: line - 1, character: column - 1)
        return hover?.value ?? "(no hover information at \(line):\(column))"
    }

    /// Find where the symbol at a position is defined.
    /// - Parameter file: Path to the file (absolute, or relative to the project root).
    /// - Parameter line: 1-based line number.
    /// - Parameter column: 1-based column number.
    @MCPTool
    func definition(file: String, line: Int, column: Int) async throws -> [Location] {
        let (client, path) = try await openedClient(forFile: file)
        return try await client.definition(path: path, line: line - 1, character: column - 1).map(Location.init)
    }

    /// Find all references to the symbol at a position (project-wide; depends on the
    /// background index being ready).
    /// - Parameter file: Path to the file (absolute, or relative to the project root).
    /// - Parameter line: 1-based line number.
    /// - Parameter column: 1-based column number.
    @MCPTool
    func references(file: String, line: Int, column: Int) async throws -> [Location] {
        let client = try await session.client()
        let path = await session.resolve(file)
        try await client.syncDocument(path: path)
        try await client.waitForIndex()
        return try await client.references(path: path, line: line - 1, character: column - 1).map(Location.init)
    }

    /// List the document symbols (types, methods, properties) declared in a file, as
    /// a hierarchy.
    /// - Parameter file: Path to the file (absolute, or relative to the project root).
    @MCPTool
    func document_symbols(file: String) async throws -> [SymbolNode] {
        let (client, path) = try await openedClient(forFile: file)
        return try await client.documentSymbol(path: path).map(SymbolNode.init)
    }

    // MARK: - Shared

    /// Warm client + index, then a scope/exact-filtered `workspace/symbol` search.
    private func searchSymbols(query: String, scope: String, exact: Bool) async throws -> [LSPSymbolInformation] {
        let client = try await session.client()
        try await client.waitForIndex()
        let raw = try await client.workspaceSymbol(query)
        return lspFilterSymbols(raw, query: query, scope: LSPSymbolScope(flag: scope) ?? .project, exact: exact)
    }

    /// Resolve `file`, get the warm client, and open the document so position queries
    /// answer against current content.
    private func openedClient(forFile file: String) async throws -> (LSPClient, String) {
        let client = try await session.client()
        let path = await session.resolve(file)
        try await client.syncDocument(path: path)
        return (client, path)
    }
}
