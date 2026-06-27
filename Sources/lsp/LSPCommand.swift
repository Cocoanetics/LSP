//
//  `lsp` — a thin CLI over LSPKit's `LSPClient`, the Swift counterpart of the
//  validated `probe.py` flow: spawn `sourcekit-lsp`, run the lifecycle handshake,
//  `didOpen` a file, and interrogate it.
//
//  Usage:
//    lsp where <query> [project-dir]          find symbols by name across the project
//    lsp symbols <file.swift>                 list the file's document symbols
//    lsp hover <file.swift> <line> <col>      hover at a 0-based line:column
//    lsp definition <file.swift> <line> <col> jump-to-definition target(s)
//    lsp capabilities <file-or-dir>           initialize and print server capabilities
//
//  Lines/columns are 0-based; the column is a UTF-16 offset (LSP convention).
//

import Foundation
import LSPKit

@main
struct LSPCommand {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            exit(EXIT_FAILURE)
        }

        do {
            switch command {
            case "where":
                try await whereSymbol(arguments: Array(arguments.dropFirst()))
            case "symbols":
                try await symbols(arguments: Array(arguments.dropFirst()))
            case "hover":
                try await hover(arguments: Array(arguments.dropFirst()))
            case "definition":
                try await definition(arguments: Array(arguments.dropFirst()))
            case "capabilities":
                try await capabilities(arguments: Array(arguments.dropFirst()))
            case "-h", "--help", "help":
                printUsage()
            default:
                FileHandle.standardError.write(Data("Unknown command: \(command)\n\n".utf8))
                printUsage()
                exit(EXIT_FAILURE)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    // MARK: - Commands

    /// `workspace/symbol`: the name → location front door. Roots the server at the
    /// project enclosing `<target>` (default: the current directory), then searches
    /// the background index — waiting for it to warm up if the first hits are empty.
    static func whereSymbol(arguments: [String]) async throws {
        guard let query = arguments.first, !query.isEmpty else {
            throw usageError("where <query> [project-dir]")
        }
        let target = arguments.count >= 2 ? arguments[1] : "."
        let root = enclosingProjectRoot(for: absolute(target))

        let client = try LSPClient(launch: LSPServer.sourceKit())
        await client.start()
        _ = try await client.initialize(rootURI: LSPURI.file(root))
        try await client.initialized()

        let matches = try await searchWaitingForIndex(client, query: query)
        if matches.isEmpty {
            print("(no symbols matching \"\(query)\")")
        } else {
            for match in matches { print(formatSymbol(match)) }
        }
        await client.shutdownAndExit()
    }

    /// `workspace/symbol` reads the background index, which builds asynchronously
    /// after `initialize`. Retry on an empty result — a few short waits — so a cold
    /// project gets a chance to index before we conclude "no matches". A genuinely
    /// absent symbol just costs the full (bounded) wait.
    static func searchWaitingForIndex(
        _ client: LSPClient, query: String, attempts: Int = 12, delayMilliseconds: UInt64 = 500
    ) async throws -> [LSPSymbolInformation] {
        for attempt in 1...attempts {
            // Drop compiler-synthesized symbols (mangled `$s…` names from macro
            // expansions like Swift Testing's `@Test`) — never useful to a reader.
            let matches = try await client.workspaceSymbol(query)
                .filter { !$0.name.hasPrefix("$") }
            if !matches.isEmpty { return matches }
            if attempt < attempts {
                try await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
            }
        }
        return []
    }

    /// Reproduce the POC: handshake, open the file, print its symbol tree.
    static func symbols(arguments: [String]) async throws {
        guard let file = arguments.first else { throw usageError("symbols <file>") }
        let path = absolute(file)
        let client = try await connected(forFile: path)
        try await client.didOpen(path: path)
        let tree = try await client.documentSymbol(path: path)
        if tree.isEmpty {
            print("(no symbols)")
        } else {
            for symbol in tree { printSymbol(symbol, indent: 0) }
        }
        await client.shutdownAndExit()
    }

    static func hover(arguments: [String]) async throws {
        guard arguments.count >= 3,
              let line = Int(arguments[1]), let column = Int(arguments[2]) else {
            throw usageError("hover <file> <line> <col>")
        }
        let path = absolute(arguments[0])
        let client = try await connected(forFile: path)
        try await client.didOpen(path: path)
        if let hover = try await client.hover(path: path, line: line, character: column) {
            print(hover.value)
        } else {
            print("(no hover)")
        }
        await client.shutdownAndExit()
    }

    static func definition(arguments: [String]) async throws {
        guard arguments.count >= 3,
              let line = Int(arguments[1]), let column = Int(arguments[2]) else {
            throw usageError("definition <file> <line> <col>")
        }
        let path = absolute(arguments[0])
        let client = try await connected(forFile: path)
        try await client.didOpen(path: path)
        let locations = try await client.definition(path: path, line: line, character: column)
        if locations.isEmpty {
            print("(no definition)")
        } else {
            for location in locations { print(format(location)) }
        }
        await client.shutdownAndExit()
    }

    static func capabilities(arguments: [String]) async throws {
        guard let target = arguments.first else { throw usageError("capabilities <file-or-dir>") }
        let path = absolute(target)
        let client = try LSPClient(launch: LSPServer.sourceKit())
        await client.start()
        let result = try await client.initialize(rootURI: LSPURI.file(enclosingProjectRoot(for: path)))
        if let name = result.serverName {
            print("server: \(name)\(result.serverVersion.map { " \($0)" } ?? "")")
        }
        print("capabilities (\(result.capabilityNames.count)):")
        for capability in result.capabilityNames { print("  - \(capability)") }
        await client.shutdownAndExit()
    }

    // MARK: - Shared handshake

    /// Spawn `sourcekit-lsp`, `initialize` (rooted at the file's package), and send
    /// `initialized` — leaving the client ready for `didOpen` + queries.
    static func connected(forFile path: String) async throws -> LSPClient {
        let client = try LSPClient(launch: LSPServer.sourceKit())
        await client.start()
        _ = try await client.initialize(rootURI: LSPURI.file(enclosingProjectRoot(for: path)))
        try await client.initialized()
        return client
    }

    // MARK: - Output

    static func printSymbol(_ symbol: LSPDocumentSymbol, indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        let kind = symbol.symbolKind?.displayName ?? "kind \(symbol.kind)"
        let detail = symbol.detail.map { " — \($0)" } ?? ""
        print("\(pad)\(symbol.name) [\(kind)]\(detail)")
        for child in symbol.children ?? [] { printSymbol(child, indent: indent + 1) }
    }

    static func formatSymbol(_ symbol: LSPSymbolInformation) -> String {
        let kind = symbol.symbolKind?.displayName ?? "kind \(symbol.kind)"
        let container = symbol.containerName.flatMap { $0.isEmpty ? nil : " (in \($0))" } ?? ""
        return "\(format(symbol.location))  \(symbol.name) [\(kind)]\(container)"
    }

    static func format(_ location: LSPLocation) -> String {
        let path = LSPURI.path(location.uri) ?? location.uri
        let start = location.range.start
        return "\(path):\(start.line + 1):\(start.character + 1)"
    }

    static func absolute(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).isAbsolutePath
            ? expanded
            : FileManager.default.currentDirectoryPath + "/" + expanded
    }

    static func usageError(_ form: String) -> Error {
        NSError(domain: "lsp", code: 2, userInfo: [NSLocalizedDescriptionKey: "usage: lsp \(form)"])
    }

    static func printUsage() {
        print("""
        lsp — interrogate a project through sourcekit-lsp (LSPKit / JSONFoundation).

        Usage:
          lsp where <query> [project-dir]          find symbols by name across the project
          lsp symbols <file.swift>                 list the file's document symbols
          lsp hover <file.swift> <line> <col>      hover text at a 0-based line:column
          lsp definition <file.swift> <line> <col> jump-to-definition target(s)
          lsp capabilities <file-or-dir>           print the server's capabilities

        Lines and columns are 0-based; columns are UTF-16 offsets (LSP convention).
        """)
    }
}
