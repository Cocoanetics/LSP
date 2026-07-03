import ArgumentParser
import LSPKit

extension LSPCommand {
    /// `lsp decl <query> [project-dir]` — the one-shot of `where` → `hover`: find a
    /// symbol by name, then print its declaration at each match (signature alone, the
    /// full hover with `--full`, or a structured array with `--json`).
    struct Decl: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "decl",
            abstract: "Print a symbol's declaration (signature; +doc with --full)."
        )

        @Argument(help: "The symbol name to look up.")
        var query: String

        @Argument(help: "Project directory (default: current).")
        var projectDir: String?

        @Option(help: "Which sources to search: project, dependencies, or all.")
        var scope: LSPSymbolScope = .project

        @Flag(help: "Only symbols whose name is exactly <query>.")
        var exact = false

        @Flag(help: "Include the doc comment, not just the signature.")
        var full = false

        @Flag(help: "Emit the full result as JSON.")
        var json = false

        func run() async throws {
            let root = projectRoot(for: projectDir)
            let indexing = IndexingMonitor()
            try await LSPRunner.withClient(
                root: root,
                configure: { client in await client.setProgressHandler { indexing.handle($0) } }
            ) { client in
                let matches = try await searchAfterIndexing(
                    client, query: query, scope: scope, exact: exact, indexing: indexing)
                if matches.isEmpty {
                    print(json ? "[]" : "(no symbols matching \"\(query)\")")
                    return
                }

                let resolved = await declarationHovers(for: matches, client: client)

                if json {
                    printJSON(resolved.map { match, hover in
                        DeclarationResult(
                            name: match.name,
                            kind: match.symbolKind,
                            containerName: match.containerName,
                            location: match.location,
                            signature: hover.map { lspSignature(fromHoverMarkdown: $0.value) },
                            documentation: hover.flatMap { lspDocumentation(fromHoverMarkdown: $0.value) })
                    })
                    return
                }

                for (index, entry) in resolved.enumerated() {
                    if index > 0 { print("") }
                    print(formatSymbol(entry.match, root: root))
                    if let hover = entry.hover {
                        let body = full ? hover.value : lspSignature(fromHoverMarkdown: hover.value)
                        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                            print("  \(line)")
                        }
                    } else {
                        print("  (no declaration info)")
                    }
                }
            }
        }
    }
}
