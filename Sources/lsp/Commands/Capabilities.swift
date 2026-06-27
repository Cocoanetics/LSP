import ArgumentParser
import LSPKit

extension LSPCommand {
    /// `lsp capabilities <file-or-dir>` — initialize and print what the server can do.
    /// Its lifecycle is special (no `initialized`, and it reads the `initialize`
    /// result), so it drives the client directly rather than via `LSPRunner`.
    struct Capabilities: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "capabilities",
            abstract: "Print the server's advertised capabilities."
        )

        @Argument(help: "A file or directory in the project to root the server at.")
        var target: String

        func run() async throws {
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
    }
}
