import Foundation
import LSPKit

/// Owns a single, long-lived `sourcekit-lsp` rooted at the project, so the
/// background index is built **once** and stays warm across MCP tool calls — the
/// opposite of the `lsp` CLI, which spawns a fresh, cold server per command.
///
/// The server is started lazily on first use and memoized via a `Task`, so
/// concurrent first calls await the same handshake instead of racing to spawn two.
/// If the server dies (crash, or an external `kill`), the session detects it via
/// `waitForExit` and respawns on the next call — rather than handing out a dead,
/// closed client forever.
actor LSPSession {
    /// The project root sourcekit-lsp is initialized against (its `rootUri`).
    let root: String
    /// The in-flight or completed spawn — non-`nil` means "use this one"; cleared
    /// by the exit monitor (server died) or a failed startup, either of which makes
    /// the next `client()` respawn.
    private var startup: Task<LSPClient, Error>?
    /// Bumped per spawn, so a stale exit monitor (or a failed startup racing a
    /// `shutdown()`/respawn) can recognize it has been superseded and must not
    /// clear a newer spawn's `startup`.
    private var generation = 0

    init(root: String) {
        self.root = root
    }

    /// The started, handshaken client — spawning + initializing on first call,
    /// reused (warm index) thereafter, and respawned if the previous server exited.
    func client() async throws -> LSPClient {
        if let startup { return try await startup.value }

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
            // Fan the server's `$/progress` out to whatever sinks are registered —
            // the MCP tools bridge indexing progress to their caller. The handler
            // yields synchronously into a stream and one consumer per spawn delivers
            // in arrival order; a Task per event would race and let 50% overtake 30%.
            let (events, continuation) = AsyncStream.makeStream(of: LSPProgress.self)
            await client.setProgressHandler { continuation.yield($0) }
            Task { [weak self] in
                for await progress in events { await self?.deliverProgress(progress) }
            }
            // Watch the server: when it exits, end the progress stream and clear
            // `startup` so the next `client()` respawns instead of reusing a closed
            // connection.
            Task { [weak self] in
                _ = await client.waitForExit()
                continuation.finish()
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
        startup = nil
    }

    // MARK: - Progress fan-out

    /// Sinks that want the server's `$/progress` (an MCP tool, for the span of one
    /// request, bridging indexing progress to its caller's progress token). Keyed so
    /// each can unsubscribe when its request finishes.
    private var progressSinks: [UUID: @Sendable (LSPProgress) -> Void] = [:]

    /// Register a progress sink; returns its id, to pass to ``removeProgressSink(_:)``.
    func addProgressSink(_ sink: @escaping @Sendable (LSPProgress) -> Void) -> UUID {
        let id = UUID()
        progressSinks[id] = sink
        return id
    }

    func removeProgressSink(_ id: UUID) {
        progressSinks[id] = nil
    }

    private func deliverProgress(_ progress: LSPProgress) {
        for sink in progressSinks.values { sink(progress) }
    }

    /// Orderly teardown — terminate the language server. Called from the MCP
    /// server's `shutdown()` hook after the transport stops.
    func shutdown() async {
        let current = startup
        startup = nil
        if let client = try? await current?.value {
            await client.shutdownAndExit()
        }
    }

    /// Resolve a tool-supplied path to an absolute one: `~` expanded, and relative
    /// paths taken against the project root.
    func resolve(_ file: String) -> String {
        // Agents routinely send arguments with a trailing newline (`"Foo.swift\n"`);
        // left in, it corrupts the path and nothing resolves. Trim before expanding.
        let trimmed = file.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath { return expanded }
        return (root as NSString).appendingPathComponent(expanded)
    }
}
