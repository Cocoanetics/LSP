import ArgumentParser
import LSPKit

extension LSPCommand {
    /// `lsp symbols <file>` — the file's hierarchical document-symbol tree.
    struct Symbols: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "symbols",
            abstract: "List the file's document symbols."
        )

        @Argument(help: "The file to list symbols for.")
        var file: String

        func run() async throws {
            let path = absolute(file)
            try await LSPRunner.withClient(root: enclosingProjectRoot(for: path)) { client in
                try await client.didOpen(path: path)
                let tree = try await client.documentSymbol(path: path)
                if tree.isEmpty {
                    print("(no symbols)")
                } else {
                    for symbol in tree { printSymbol(symbol, indent: 0) }
                }
            }
        }
    }
}
