//
//  `lsp` — a thin CLI over LSPKit's `LSPClient`, the Swift counterpart of the
//  validated `probe.py` flow: spawn `sourcekit-lsp`, run the lifecycle handshake,
//  `didOpen` a file, and interrogate it.
//
//  Usage:
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
          lsp symbols <file.swift>                 list the file's document symbols
          lsp hover <file.swift> <line> <col>      hover text at a 0-based line:column
          lsp definition <file.swift> <line> <col> jump-to-definition target(s)
          lsp capabilities <file-or-dir>           print the server's capabilities

        Lines and columns are 0-based; columns are UTF-16 offsets (LSP convention).
        """)
    }
}
