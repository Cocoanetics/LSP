// swift-tools-version: 6.1
import PackageDescription

// Greenfield — see GOALS.md. This scaffold only wires the JSONFoundation
// dependency and gives you a target to build into; restructure freely.
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
        // The JSON-RPC envelope. params/result are JSONValue (2.0+) — ideal for
        // LSP's arbitrarily-shaped payloads. The Content-Length transport framing
        // is yours to add (JSONFoundation is wire-model only).
        .package(url: "https://github.com/Cocoanetics/JSONFoundation.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "LSPKit",
            dependencies: [
                .product(name: "JSONFoundation", package: "JSONFoundation")
            ]
        ),
        .executableTarget(
            name: "lsp",
            dependencies: ["LSPKit"]
        ),
        .testTarget(
            name: "LSPKitTests",
            dependencies: ["LSPKit"]
        )
    ]
)
