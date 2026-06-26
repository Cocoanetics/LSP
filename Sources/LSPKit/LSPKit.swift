//
//  LSPKit — talk to a Language Server (LSP) from Swift.
//
//  Status: greenfield scaffold. See ../../GOALS.md for the plan, and
//  ../../probe.py for the validated Content-Length-framed wire flow this should
//  reproduce in Swift.
//
//  Build order (smallest new surface first):
//    1. LSPFramedTransport — Content-Length framing over a subprocess
//       (copy SwiftACP's SubprocessTransport; swap newline framing for
//       `Content-Length: <n>\r\n\r\n<json>`).
//    2. A JSON-RPC peer — copy SwiftACP's JSONRPCConnection (correlation +
//       dispatch). Flag the duplication; it wants to be a shared package one day.
//    3. LSPClient — initialize / initialized / didOpen / documentSymbol / hover …
//    4. CLI (`lsp`) + an MCP server exposing the queries as tools.
//

import JSONFoundation

/// Placeholder so the module compiles. Replace with the real client API.
public enum LSPKit {
    public static let about = "Greenfield LSP client — see GOALS.md"
}
