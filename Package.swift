// swift-tools-version: 6.1
import PackageDescription

// Building this package needs a Swift 6.3+ toolchain (Xcode 26.4+). SwiftMCP
// reaches swift-subprocess purely through trait-conditioned edges (`Client` →
// JSONFoundation's `Subprocess`), and SwiftPM 6.2 cannot see a trait-gated
// product that deep in the graph — it fails with "product 'Subprocess' … not
// found" whatever this manifest declares. SwiftPM 6.3 resolves it, but only
// with the swift-subprocess resolver hint below.

// LSPKit drives a Language Server (starting with `sourcekit-lsp`) from Swift over
// JSON-RPC, and exposes it as a CLI and an MCP server (`lsp` / `lsp mcp`) — the
// same shape SwiftACP gives ACP.
//
// The JSON-RPC stack is **entirely reused** from JSONFoundation 2.1+, which now
// owns the unified runtime the three sibling projects (SwiftMCP, SwiftACP, LSP)
// used to hand-roll:
//
//   JSONFoundation  `JSONValue` · the `JSONRPCMessage` envelope
//   JSONRPCPeer     the transport-agnostic correlator + dispatcher (`JSONRPCPeer`)
//   JSONRPCWire     framing codecs — `ContentLengthFraming` is LSP's wire format
//   JSONRPCStdio    `ProcessTransport` — a zero-dependency `Foundation.Process`
//                   stdio transport, generic over the framing
//
// LSP differs from ACP/MCP on exactly one axis — `Content-Length` header framing
// instead of newline-delimited JSON — and that axis is a value
// (`ContentLengthFraming`) plugged into the shared transport. So LSPKit writes no
// transport and no peer of its own: it is just typed LSP methods over
// `JSONRPCPeer(transport: ProcessTransport(launch:, framing: ContentLengthFraming()))`.
let package = Package(
    name: "LSP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LSPKit", targets: ["LSPKit"]),
        .executable(name: "lsp", targets: ["lsp"])
    ],
    dependencies: [
        // The unified JSON-RPC runtime: the envelope (`JSONFoundation`), the peer
        // (`JSONRPCPeer`), the `Content-Length` framing codec (`JSONRPCWire`), and
        // the zero-dependency `Foundation.Process` stdio transport (`JSONRPCStdio`).
        // The runtime API LSPKit uses has been stable since 2.1; the 2.5.0 floor is
        // for behavior, not API — it fixes the exact stack LSP sits on (spec-valid
        // `result: null` in the peer's auto-acknowledgements, full batch delivery,
        // and a cancellation-aware `sendRequest`).
        // The fine-grained products below are deliberate: the 2.5 `JSONRPC` umbrella
        // also re-exports the TCP/SSE transports (pulling SwiftCross) that LSPKit
        // never touches.
        .package(url: "https://github.com/Cocoanetics/JSONFoundation.git", from: "2.5.0"),
        // The MCP server layer — `@MCPServer`/`@MCPTool` + the stdio and HTTP+SSE
        // transports — the same SwiftMCP that backs SwiftACP's `acpxd`. (Server-only
        // use, but the default `Client` trait must stay on: the `@MCPServer` macro
        // expands a nested `Client` type that references `MCPServerProxy`.)
        .package(url: "https://github.com/Cocoanetics/SwiftMCP.git", from: "1.9.0"),
        // `serve(over:logger:)` takes a swift-log `Logger`; 1.1.0 is the floor for
        // `StreamLogHandler.standardError`, which `lsp mcp` bootstraps.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.1.0"),
        // The CLI is structured as swift-argument-parser subcommands.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Not imported anywhere — a resolver hint. SwiftPM 6.3 fails to resolve
        // swift-subprocess along SwiftMCP's trait-conditioned edges ("exhausted
        // attempts…") unless it is also named at the top level. Drop this once
        // SwiftPM resolves trait-conditioned dependencies on its own again.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.5.0")
    ],
    targets: [
        .target(
            name: "LSPKit",
            dependencies: [
                .product(name: "JSONFoundation", package: "JSONFoundation"),
                .product(name: "JSONRPCPeer", package: "JSONFoundation"),
                .product(name: "JSONRPCWire", package: "JSONFoundation"),
                .product(name: "JSONRPCStdio", package: "JSONFoundation")
            ]
        ),
        .executableTarget(
            name: "lsp",
            dependencies: [
                "LSPKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                // The `lsp mcp` subcommand serves the tools over an MCP stdio transport.
                .product(name: "SwiftMCP", package: "SwiftMCP"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "LSPKitTests",
            dependencies: ["LSPKit"]
        ),
        // Tests the executable's own logic (DTO conversions, progress state, output
        // formatting) — SwiftPM links the `lsp` module into the test bundle.
        .testTarget(
            name: "lspTests",
            dependencies: ["lsp"]
        )
    ]
)
