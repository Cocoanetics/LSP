import Foundation
import LSPKit

/// Owns a single, long-lived `sourcekit-lsp` rooted at the project, so the
/// background index is built **once** and stays warm across MCP tool calls — the
/// opposite of the `lsp` CLI, which spawns a fresh, cold server per command.
///
/// The server is started lazily on first use and memoized via a `Task`, so
/// concurrent first calls share one handshake instead of racing to spawn two.
actor LSPSession {
    /// The project root sourcekit-lsp is initialized against (its `rootUri`).
    let root: String
    private var startup: Task<LSPClient, Error>?

    init(root: String) {
        self.root = root
    }

    /// The started, handshaken client — spawning + initializing on first call,
    /// reused (warm index) thereafter.
    func client() async throws -> LSPClient {
        if let startup { return try await startup.value }
        let root = root
        let task = Task { () throws -> LSPClient in
            let client = try LSPClient(launch: LSPServer.sourceKit())
            await client.start()
            _ = try await client.initialize(rootURI: LSPURI.file(root))
            try await client.initialized()
            return client
        }
        startup = task
        do {
            return try await task.value
        } catch {
            startup = nil // let a later call retry a failed spawn
            throw error
        }
    }

    /// Orderly teardown — terminate the language server. Called from the MCP
    /// server's `shutdown()` hook after the transport stops.
    func shutdown() async {
        guard let startup else { return }
        self.startup = nil
        if let client = try? await startup.value {
            await client.shutdownAndExit()
        }
    }

    /// Resolve a tool-supplied path to an absolute one: `~` expanded, and relative
    /// paths taken against the project root.
    func resolve(_ file: String) -> String {
        let expanded = (file as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath { return expanded }
        return (root as NSString).appendingPathComponent(expanded)
    }
}
