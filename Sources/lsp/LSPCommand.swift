import ArgumentParser

/// The tool's one version string — surfaced by `lsp --version` and reused as the
/// MCP server's advertised version (see `LSPMCPServer`).
let lspVersion = "0.1.0"

/// `lsp` — interrogate a project through `sourcekit-lsp` (LSPKit / JSONFoundation).
///
/// The root command is just the subcommand registry; each verb lives in its own
/// file under `Commands/` as an `LSPCommand.<Name>` `AsyncParsableCommand`.
///
/// Position arguments (`<line> <col>`) are **0-based**, and the column is a UTF-16
/// offset — the LSP convention. Printed locations are 1-based, editor-style.
@main
struct LSPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lsp",
        abstract: "Interrogate a project through sourcekit-lsp.",
        version: lspVersion,
        subcommands: [
            Where.self,
            Decl.self,
            Check.self,
            Symbols.self,
            Hover.self,
            Definition.self,
            References.self,
            Capabilities.self,
            MCP.self
        ]
    )
}
