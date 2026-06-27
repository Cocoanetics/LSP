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
