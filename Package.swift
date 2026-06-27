// swift-tools-version: 6.1
import PackageDescription

// LSPKit drives a Language Server (starting with `sourcekit-lsp`) from Swift over
// JSON-RPC, and exposes it as a CLI (`lsp`) — the same shape SwiftACP gives ACP.
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
        // 2.3.0 is the floor SwiftMCP requires, and is API-compatible with the 2.1+
        // runtime LSPKit uses.
        .package(url: "https://github.com/Cocoanetics/JSONFoundation.git", from: "2.3.0"),
        // The MCP server layer — `@MCPServer`/`@MCPTool` + the stdio transport — the
        // same SwiftMCP that backs SwiftACP's `acpxd`.
        .package(url: "https://github.com/Cocoanetics/SwiftMCP.git", from: "1.8.0"),
        // `serve(over:logger:)` takes a swift-log `Logger`.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        // The CLI is structured as swift-argument-parser subcommands.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
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
        )
    ]
)
