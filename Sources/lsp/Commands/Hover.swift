import ArgumentParser
import LSPKit

extension LSPCommand {
    /// `lsp hover <file> <line> <col>` — hover text at a 0-based position.
    struct Hover: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "hover",
            abstract: "Hover text at a 0-based line:column (column is a UTF-16 offset)."
        )

        @Argument(help: "The file.")
        var file: String

        @Argument(help: "0-based line number.")
        var line: Int

        @Argument(help: "0-based column (UTF-16 offset).")
        var column: Int

        func run() async throws {
            let path = absolute(file)
            try await LSPRunner.withClient(root: enclosingProjectRoot(for: path)) { client in
                try await client.didOpen(path: path)
                if let hover = try await client.hover(path: path, line: line, character: column) {
                    print(hover.value)
                } else {
                    print("(no hover)")
                }
            }
        }
    }
}
