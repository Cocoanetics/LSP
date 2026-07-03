import ArgumentParser
import Foundation
import Logging
import LSPKit
import SwiftMCP

extension LSPCommand {
    /// `lsp mcp [project-dir]` — run as an MCP server, exposing the queries as tools
    /// (`check_file`, `find_symbol`, `declaration`, `hover`, `definition`,
    /// `references`, `document_symbols`) backed by one warm `sourcekit-lsp`.
    ///
    /// Two transports, selected by `--http-port`:
    ///
    /// - **stdio** (default) — the client launches `lsp mcp` and speaks over the pipe:
    ///
    ///   { "mcpServers": { "lsp": { "type": "stdio",
    ///       "command": "/path/to/lsp", "args": ["mcp", "/path/to/project"] } } }
    ///
    /// - **HTTP** (`--http-port 8080`) — a long-running server outward clients
    ///   connect to at `http://<host>:<port>/mcp` (streamable HTTP; the legacy SSE
    ///   endpoint stays available at `/sse`), the same shape SwiftACP's `acpxd`
    ///   and the SwiftMCP demo expose.
    ///
    /// Blocks, serving until the transport closes or a signal (SIGINT/SIGTERM) arrives;
    /// `serve(over:)` owns the run loop, traps the signals, and shuts the session down.
    struct MCP: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mcp",
            abstract: "Run as an MCP server (stdio, or HTTP with --http-port)."
        )

        @Argument(help: "Project directory (default: current).")
        var projectDir: String?

        @Option(name: .customLong("http-port"),
                help: "Serve over HTTP on this port instead of stdio.")
        var httpPort: Int?

        @Option(name: .customLong("http-host"),
                help: "Bind address for HTTP (loopback by default; pass 0.0.0.0 to expose).")
        var httpHost: String = "127.0.0.1"

        @Option(name: .customLong("token"),
                help: "Require this bearer token for HTTP requests (unauthenticated if omitted).")
        var token: String?

        func run() async throws {
            // stdout carries the stdio MCP JSON-RPC; logs must go to stderr or they corrupt it.
            LoggingSystem.bootstrap { StreamLogHandler.standardError(label: $0) }

            let root = projectRoot(for: projectDir)
            var logger = Logger(label: "com.cocoanetics.lsp.mcp")
            logger.logLevel = .notice

            let session = LSPSession(root: root)
            let server = LSPMCPServer(session: session)

            // `serve(over:)` builds the ServiceGroup, traps SIGINT/SIGTERM, and calls the
            // server's `shutdown()` once the transport stops — so both paths tear the
            // sourcekit-lsp session down cleanly.
            let transports: [any MCPTransport]
            if let httpPort {
                let http = HTTPSSETransport(host: httpHost, port: httpPort)
                if let token {
                    http.authorizationHandler = { provided in
                        provided == token ? .authorized : .unauthorized("Invalid or missing bearer token")
                    }
                }
                transports = [http]
                logger.notice("lsp mcp serving over HTTP", metadata: [
                    "root": .string(root),
                    "endpoint": .string("http://\(httpHost):\(httpPort)/mcp"),
                    "legacySSE": .string("http://\(httpHost):\(httpPort)/sse"),
                    "auth": .string(token == nil ? "none" : "bearer")
                ])
            } else {
                transports = [StdioTransport()]
                logger.notice("lsp mcp serving over stdio", metadata: ["root": .string(root)])
            }

            try await server.serve(over: transports, logger: logger)
        }
    }
}
