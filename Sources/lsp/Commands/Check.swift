import ArgumentParser
import LSPKit

extension LSPCommand {
    /// `lsp check <file>` — lint one file via LSP diagnostics: syntax *and* semantic
    /// errors from sourcekit-lsp's in-memory type-check, no full build needed.
    /// `LSPClient.diagnostics` opens the file, gates on `workspace/synchronize` (so
    /// the target is prepared and the semantic diagnostics are accurate, not just
    /// syntactic), and waits for the publish stream to settle — the same wait the
    /// `check_file` MCP tool uses.
    struct Check: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "check",
            abstract: "Report syntax/semantic errors in a file (LSP diagnostics)."
        )

        @Argument(help: "The file to check.")
        var file: String

        @Flag(help: "Emit the diagnostics as JSON.")
        var json = false

        func run() async throws {
            let path = absolute(file)
            let root = enclosingProjectRoot(for: path)
            let uri = LSPURI.file(path)
            let indexing = IndexingMonitor()

            let diagnostics = try await LSPRunner.withClient(
                root: root,
                configure: { client in await client.setProgressHandler { indexing.handle($0) } }
            ) { client in
                let published = try await client.diagnostics(forPath: path, prepareIndex: true)
                indexing.finish()
                return published.sorted {
                    ($0.range.start.line, $0.range.start.character) < ($1.range.start.line, $1.range.start.character)
                }
            }

            if json {
                printJSON(diagnostics.map { DiagnosticResult($0, root: root, uri: uri) })
            } else if diagnostics.isEmpty {
                print("no issues")
            } else {
                for diagnostic in diagnostics {
                    print(formatDiagnostic(diagnostic, root: root, uri: uri))
                }
                let tally = diagnosticTally(diagnostics)
                print("\(tally.errors) error\(tally.errors == 1 ? "" : "s"), "
                    + "\(tally.warnings) warning\(tally.warnings == 1 ? "" : "s")")
            }
        }
    }
}
