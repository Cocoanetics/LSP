import ArgumentParser

/// `lsp` — interrogate a project through `sourcekit-lsp` (LSPKit / JSONFoundation).
///
/// The root command is just the subcommand registry; each verb lives in its own
/// file under `Commands/` as an `LSPCommand.<Name>` `AsyncParsableCommand`.
///
/// Positions (`<line> <col>`) are **0-based**, and the column is a UTF-16 offset —
/// the LSP convention.
@main
struct LSPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lsp",
        abstract: "Interrogate a project through sourcekit-lsp.",
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
