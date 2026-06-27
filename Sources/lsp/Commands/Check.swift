import ArgumentParser
import LSPKit

extension LSPCommand {
    /// `lsp check <file>` — lint one file via LSP diagnostics: syntax *and* semantic
    /// errors from sourcekit-lsp's in-memory type-check, no full build needed.
    /// `didOpen` hands the server the text; it pushes `publishDiagnostics` after
    /// type-checking. We gate on `workspace/synchronize` so the target is prepared and
    /// the semantic diagnostics are accurate, not just syntactic.
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
            let indexing = IndexingMonitor()
            let collector = DiagnosticsCollector(targetPath: path)

            let diagnostics = try await LSPRunner.withClient(
                root: root,
                configure: { client in
                    await client.setProgressHandler { indexing.handle($0) }
                    await client.setDiagnosticsHandler { collector.record(uri: $0.uri, diagnostics: $0.diagnostics) }
                }
            ) { client in
                try await client.didOpen(path: path)
                // Prepare the target so semantic diagnostics resolve project symbols.
                try await client.waitForIndex()
                indexing.finish()
                await collector.waitForFirstPublish(fallbackMilliseconds: 3_000)
                return collector.diagnostics.sorted {
                    ($0.range.start.line, $0.range.start.character) < ($1.range.start.line, $1.range.start.character)
                }
            }

            if json {
                printJSON(diagnostics.map { DiagnosticResult($0, root: root, uri: collector.targetURI) })
            } else if diagnostics.isEmpty {
                print("no issues")
            } else {
                for diagnostic in diagnostics {
                    print(formatDiagnostic(diagnostic, root: root, uri: collector.targetURI))
                }
                let errors = diagnostics.filter { $0.severity == 1 }.count
                let warnings = diagnostics.filter { $0.severity == 2 }.count
                print("\(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")")
            }
        }
    }
}
