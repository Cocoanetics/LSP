import LSPKit

/// Wait for the background index, then run a scope/exact-filtered `workspace/symbol`
/// search. Shared by `where` and `decl`.
///
/// We block on `workspace/synchronize` (via `waitForIndex`) until the index is
/// complete, **then** query — never trusting a partial index, which would answer
/// immediately with incomplete, often junk matches. `synchronize` returns at once
/// when the index is already up to date, so the warm path stays fast.
func searchAfterIndexing(
    _ client: LSPClient, query: String, scope: LSPSymbolScope, exact: Bool, indexing: IndexingMonitor
) async throws -> [LSPSymbolInformation] {
    try await client.waitForIndex()
    indexing.finish() // clear any bar the final `$/progress` didn't.
    return lspFilterSymbols(try await client.workspaceSymbol(query), query: query, scope: scope, exact: exact)
}

/// Resolve symbol matches to their declaration hovers: each match's file is synced
/// once (hover answers against the in-memory document), then `hover` is asked at the
/// match's selection start. Matches without a `file://` location are dropped. Shared
/// by `lsp decl` and the MCP `declaration` tool, which differ only in rendering.
func declarationHovers(
    for matches: [LSPSymbolInformation], client: LSPClient
) async -> [(match: LSPSymbolInformation, hover: LSPHover?)] {
    var syncedFiles: Set<String> = []
    var resolved: [(match: LSPSymbolInformation, hover: LSPHover?)] = []
    for match in matches {
        guard let path = LSPURI.path(match.location.uri) else { continue }
        if syncedFiles.insert(path).inserted {
            _ = try? await client.syncDocument(path: path)
        }
        let start = match.location.range.start
        let hover = (try? await client.hover(path: path, line: start.line, character: start.character)) ?? nil
        resolved.append((match, hover))
    }
    return resolved
}
