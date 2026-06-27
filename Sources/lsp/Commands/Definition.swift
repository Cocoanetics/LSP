import ArgumentParser
import LSPKit

extension LSPCommand {
    /// `lsp definition <file> <line> <col>` — where the symbol at a position is defined.
    struct Definition: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "definition",
            abstract: "Jump-to-definition target(s) for a 0-based position."
        )

        @Argument(help: "The file.")
        var file: String

        @Argument(help: "0-based line number.")
        var line: Int

        @Argument(help: "0-based column (UTF-16 offset).")
        var column: Int

        func run() async throws {
            let path = absolute(file)
            let root = enclosingProjectRoot(for: path)
            try await LSPRunner.withClient(root: root) { client in
                try await client.didOpen(path: path)
                let locations = try await client.definition(path: path, line: line, character: column)
                if locations.isEmpty {
                    print("(no definition)")
                } else {
                    for location in locations { print(formatLocation(location, root: root)) }
                }
            }
        }
    }
}
