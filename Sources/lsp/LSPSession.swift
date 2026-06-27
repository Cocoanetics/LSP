import Foundation
import LSPKit

/// Owns a single, long-lived `sourcekit-lsp` rooted at the project, so the
/// background index is built **once** and stays warm across MCP tool calls — the
/// opposite of the `lsp` CLI, which spawns a fresh, cold server per command.
///
/// The server is started lazily on first use and memoized via a `Task`, so
/// concurrent first calls share one handshake instead of racing to spawn two. If
/// the server dies (crash, or an external `kill`), the session detects it via
/// `waitForExit` and respawns on the next call — rather than handing out a dead,
/// closed client forever.
actor LSPSession {
    /// The project root sourcekit-lsp is initialized against (its `rootUri`).
    let root: String
    private var startup: Task<LSPClient, Error>?
    /// Bumped per spawn; `liveGeneration` names the spawn whose server is still up,
    /// so a late exit-monitor can't invalidate a client that already replaced it.
    private var generation = 0
    private var liveGeneration = -1

    init(root: String) {
        self.root = root
    }

    /// The started, handshaken client — spawning + initializing on first call,
    /// reused (warm index) thereafter, and respawned if the previous server exited.
    func client() async throws -> LSPClient {
        if let startup, liveGeneration == generation {
            return try await startup.value
        }

        generation += 1
        let generation = generation
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
            let client = try await task.value
            liveGeneration = generation
            // Watch the server: when it exits, mark this generation dead so the next
            // `client()` respawns instead of reusing a closed connection.
            Task { [weak self] in
                _ = await client.waitForExit()
                await self?.handleExit(of: generation)
            }
            return client
        } catch {
            if self.generation == generation { startup = nil } // let a later call retry
            throw error
        }
    }

    private func handleExit(of generation: Int) {
        guard generation == self.generation else { return } // already superseded
        liveGeneration = -1
        startup = nil
    }

    /// Orderly teardown — terminate the language server. Called from the MCP
    /// server's `shutdown()` hook after the transport stops.
    func shutdown() async {
        let current = startup
        startup = nil
        liveGeneration = -1
        if let client = try? await current?.value {
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
