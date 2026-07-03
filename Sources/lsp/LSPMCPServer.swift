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
// The macro takes the version's *source text*, so it must be a string literal —
// keep it in sync with `lspVersion` (LSPCommand.swift).
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
        let diagnostics = try await withIndexProgress {
            try await client.diagnostics(forPath: path, prepareIndex: true)
        }
        return CheckResult(file: path, diagnostics: diagnostics)
    }

    // MARK: - Symbol search

    /// Find symbols by name across the whole project (index-backed fuzzy search) —
    /// the way to turn a name into file locations without reading files.
    /// - Parameter query: The symbol name (or fragment) to search for.
    /// - Parameter scope: Which sources to search (default: the project's own sources).
    /// - Parameter exact: When true, return only symbols whose name is exactly `query`.
    @MCPTool
    func find_symbol(query: String, scope: LSPSymbolScope = .project, exact: Bool = false) async throws -> [SymbolMatch] {
        try await searchSymbols(query: query, scope: scope, exact: exact).map(SymbolMatch.init)
    }

    /// Show a symbol's declaration — its signature, and optionally its doc comment —
    /// found by name across the project. Returns one entry per match (overloads,
    /// same-named types, …).
    /// - Parameter query: The symbol name to look up.
    /// - Parameter scope: Which sources to search (default: the project's own sources).
    /// - Parameter exact: When true, only symbols whose name is exactly `query`.
    /// - Parameter includeDocumentation: When true, also return the symbol's doc comment (the `documentation` field, separate from the signature).
    @MCPTool
    func declaration(
        query: String, scope: LSPSymbolScope = .project, exact: Bool = false, includeDocumentation: Bool = false
    ) async throws -> [DeclarationMatch] {
        let client = try await session.client()
        let matches = try await searchSymbols(query: query, scope: scope, exact: exact)
        return await declarationHovers(for: matches, client: client).map { match, hover in
            DeclarationMatch(
                match,
                signature: hover.map { lspSignature(fromHoverMarkdown: $0.value) },
                documentation: includeDocumentation
                    ? hover.flatMap { lspDocumentation(fromHoverMarkdown: $0.value) }
                    : nil)
        }
    }

    // MARK: - Position queries

    /// Get hover information (type, signature, documentation) for the symbol at a
    /// position in a file. Returns the rendered Markdown, or a note if there's none.
    /// - Parameter file: Path to the file (absolute, or relative to the project root).
    /// - Parameter line: 1-based line number.
    /// - Parameter column: 1-based column number (UTF-16 units, as an editor shows).
    @MCPTool
    func hover(file: String, line: Int, column: Int) async throws -> String {
        try await withIndexProgress {
            let (client, path) = try await openedClient(forFile: file)
            let hover = try await client.hover(path: path, line: line - 1, character: column - 1)
            return hover?.value ?? "(no hover information at \(line):\(column))"
        }
    }

    /// Find where the symbol at a position is defined.
    /// - Parameter file: Path to the file (absolute, or relative to the project root).
    /// - Parameter line: 1-based line number.
    /// - Parameter column: 1-based column number (UTF-16 units, as an editor shows).
    @MCPTool
    func definition(file: String, line: Int, column: Int) async throws -> [Location] {
        try await withIndexProgress {
            let (client, path) = try await openedClient(forFile: file)
            return try await client.definition(path: path, line: line - 1, character: column - 1).map(Location.init)
        }
    }

    /// Find all references to the symbol at a position, project-wide. Waits for
    /// background indexing to finish before answering, so results are complete — the
    /// first call on a cold project can take a while (and reports indexing progress).
    /// - Parameter file: Path to the file (absolute, or relative to the project root).
    /// - Parameter line: 1-based line number.
    /// - Parameter column: 1-based column number (UTF-16 units, as an editor shows).
    @MCPTool
    func references(file: String, line: Int, column: Int) async throws -> [Location] {
        let (client, path) = try await openedClient(forFile: file)
        return try await withIndexProgress {
            try await client.waitForIndex()
            return try await client.references(path: path, line: line - 1, character: column - 1).map(Location.init)
        }
    }

    /// List the document symbols (types, methods, properties) declared in a file, as
    /// a hierarchy.
    /// - Parameter file: Path to the file (absolute, or relative to the project root).
    @MCPTool
    func document_symbols(file: String) async throws -> [SymbolNode] {
        try await withIndexProgress {
            let (client, path) = try await openedClient(forFile: file)
            return try await client.documentSymbol(path: path).map(SymbolNode.init)
        }
    }

    // MARK: - Shared

    /// Run `body` while forwarding `sourcekit-lsp`'s background-indexing `$/progress`
    /// to the caller's MCP progress token — so a cold call (waiting on the index or a
    /// target's preparation) streams progress instead of blocking silently. A no-op
    /// when the client supplied no `progressToken`, and silent on warm calls (no
    /// indexing → no events). Concurrent tool calls each register their own sink, so
    /// they don't clobber one another.
    private func withIndexProgress<T>(_ body: () async throws -> T) async throws -> T {
        guard let progressToken = RequestContext.current?.meta?.progressToken,
              let mcpSession = Session.current else {
            return try await body()
        }
        // One serial sender per request keeps the notifications in emission order —
        // a Task per event would race, and the caller could see progress go backwards.
        let (events, continuation) = AsyncStream.makeStream(of: (percent: Int, message: String?).self)
        let state = IndexProgressState()
        let sinkID = await session.addProgressSink { progress in
            guard let update = state.update(progress) else { return }
            continuation.yield((update.percent, update.message))
        }
        Task {
            for await event in events {
                await mcpSession.sendProgressNotification(
                    progressToken: progressToken, progress: Double(event.percent), total: 100,
                    message: event.message)
            }
        }
        defer { continuation.finish() }
        do {
            let result = try await body()
            await session.removeProgressSink(sinkID)
            return result
        } catch {
            await session.removeProgressSink(sinkID)
            throw error
        }
    }

    /// Warm client + index, then a scope/exact-filtered `workspace/symbol` search.
    private func searchSymbols(query: String, scope: LSPSymbolScope, exact: Bool) async throws -> [LSPSymbolInformation] {
        // Trim first: agents often send `"LSP\n"`, and the trailing newline makes both
        // the fuzzy `workspace/symbol` query and the `exact` name comparison miss.
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = try await session.client()
        return try await withIndexProgress {
            try await client.waitForIndex()
            let raw = try await client.workspaceSymbol(query)
            return lspFilterSymbols(raw, query: query, scope: scope, exact: exact)
        }
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
