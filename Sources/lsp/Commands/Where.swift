import ArgumentParser
import LSPKit

extension LSPCommand {
    /// `lsp where <query> [project-dir]` — the name → location front door.
    struct Where: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "where",
            abstract: "Find symbols by name across the project (index-backed)."
        )

        @Argument(help: "The symbol name (or fragment) to search for.")
        var query: String

        @Argument(help: "Project directory (default: current).")
        var projectDir: String?

        @Option(help: "Which sources to search: project, dependencies, or all.")
        var scope: LSPSymbolScope = .project

        @Flag(help: "Only symbols whose name is exactly <query>.")
        var exact = false

        @Flag(help: "Emit the full result as JSON.")
        var json = false

        func run() async throws {
            let root = projectRoot(for: projectDir)
            let indexing = IndexingMonitor()
            let matches = try await LSPRunner.withClient(
                root: root,
                configure: { client in await client.setProgressHandler { indexing.handle($0) } }
            ) { client in
                try await searchAfterIndexing(client, query: query, scope: scope, exact: exact, indexing: indexing)
            }

            if json {
                printJSON(matches.map(SymbolResult.init))
            } else if matches.isEmpty {
                print("(no symbols matching \"\(query)\")")
            } else {
                for match in matches { print(formatSymbol(match, root: root)) }
            }
        }
    }
}
