import ArgumentParser
import Foundation
import LSPKit

/// Spawns a one-shot `sourcekit-lsp`, runs the lifecycle handshake, hands the live
/// client to `body`, and tears the server down afterwards — on success or throw.
/// The CLI counterpart of the persistent `LSPSession` the MCP server uses.
enum LSPRunner {
    /// Initialize at `root`, send `initialized`, run `body`, then `shutdown`+`exit`.
    /// `configure` runs *before* `start()` so a command can install progress or
    /// diagnostics handlers in time to catch the first notifications.
    static func withClient<T>(
        root: String,
        configure: (LSPClient) async -> Void = { _ in },
        _ body: (LSPClient) async throws -> T
    ) async throws -> T {
        let client = try LSPClient(launch: LSPServer.sourceKit())
        await configure(client)
        await client.start()
        _ = try await client.initialize(rootURI: LSPURI.file(root))
        try await client.initialized()
        do {
            let result = try await body(client)
            await client.shutdownAndExit()
            return result
        } catch {
            await client.shutdownAndExit()
            throw error
        }
    }
}

/// Resolve a CLI path argument to an absolute one: `~` expanded, relative paths
/// taken against the current directory.
func absolute(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return (expanded as NSString).isAbsolutePath
        ? expanded
        : FileManager.default.currentDirectoryPath + "/" + expanded
}

/// The standardized, absolute package root enclosing `target` (default: cwd) — a
/// clean prefix for shortening file paths against.
func projectRoot(for target: String?) -> String {
    let resolved = enclosingProjectRoot(for: absolute(target ?? "."))
    return (resolved as NSString).standardizingPath
}

// `--scope` parses straight into LSPKit's scope enum. As a `String`-backed
// `CaseIterable`, ArgumentParser derives the value list ("project", "dependencies",
// "all") and completion for free.
extension LSPSymbolScope: ExpressibleByArgument {}
