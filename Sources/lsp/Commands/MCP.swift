import ArgumentParser
import Foundation
import Logging
import LSPKit
import SwiftMCP

extension LSPCommand {
    /// `lsp mcp [project-dir]` — run as an MCP server over stdio, exposing the queries
    /// as tools (`check_file`, `find_symbol`, `declaration`, `hover`, `definition`,
    /// `references`, `document_symbols`) backed by one warm `sourcekit-lsp`.
    ///
    ///   { "mcpServers": { "lsp": { "type": "stdio",
    ///       "command": "/path/to/lsp", "args": ["mcp", "/path/to/project"] } } }
    ///
    /// Blocks, serving until the transport closes or a signal arrives.
    struct MCP: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mcp",
            abstract: "Run as an MCP server over stdio (tools for an agent)."
        )

        @Argument(help: "Project directory (default: current).")
        var projectDir: String?

        func run() async throws {
            // stdout carries the MCP JSON-RPC; logs must go to stderr or they corrupt it.
            LoggingSystem.bootstrap { StreamLogHandler.standardError(label: $0) }

            let root = projectRoot(for: projectDir)
            var logger = Logger(label: "com.cocoanetics.lsp.mcp")
            logger.logLevel = .notice
            logger.notice("lsp mcp starting", metadata: ["root": .string(root)])

            let session = LSPSession(root: root)
            let server = LSPMCPServer(session: session)
            try await server.serve(over: [StdioTransport()], logger: logger)
        }
    }
}
