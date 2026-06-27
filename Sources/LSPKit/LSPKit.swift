//
//  LSPKit — talk to a Language Server (LSP) from Swift.
//
//  The JSON-RPC stack is JSONFoundation's unified runtime (`JSONRPCPeer` +
//  `ContentLengthFraming` + `JSONRPCStdio.ProcessTransport`); LSPKit adds only the
//  LSP semantics on top. Entry points:
//
//    - `LSPClient`   — typed lifecycle + interrogation methods over a server.
//    - `LSPServer`   — launch descriptors (`sourcekit-lsp`, or any command).
//    - `LSP*` models — positions, ranges, symbols, hover, locations.
//
//  See GOALS.md for the roadmap (CLI done; MCP server next).
//

/// Namespace for LSPKit metadata.
public enum LSPKit {
    /// The library version.
    public static let version = "0.1.0"
}
