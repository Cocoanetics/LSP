import ArgumentParser
import LSPKit

extension LSPCommand {
    /// `lsp references <file> <line> <col>` — every use of the symbol at a position.
    /// Unlike `definition`, results are cross-file, so we wait for the index (with the
    /// progress bar) before querying — otherwise early results are incomplete.
    struct References: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "references",
            abstract: "Uses of the symbol at a 0-based position (project-wide)."
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
            let indexing = IndexingMonitor()
            try await LSPRunner.withClient(
                root: root,
                configure: { client in await client.setProgressHandler { indexing.handle($0) } }
            ) { client in
                try await client.didOpen(path: path)
                try await client.waitForIndex()
                indexing.finish()
                let locations = try await client.references(path: path, line: line, character: column)
                if locations.isEmpty {
                    print("(no references)")
                } else {
                    for location in locations { print(formatLocation(location, root: root)) }
                }
            }
        }
    }
}
