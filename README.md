# LSP

Drive a Language Server (starting with `sourcekit-lsp`) from Swift via
[JSONFoundation](https://github.com/Cocoanetics/JSONFoundation)'s **unified
JSON-RPC runtime** — en route to exposing **any** LSP as a CLI and an MCP server
(the same shape [SwiftACP](https://github.com/Cocoanetics/SwiftACP) gives ACP).

LSP differs from ACP/MCP on exactly one axis — `Content-Length` header framing
instead of newline-delimited JSON. JSONFoundation 2.1+ now owns the whole stack
(the peer, the framing codecs, the stdio transport), so LSPKit writes **no**
transport and **no** peer of its own — just the typed LSP methods:

```swift
import LSPKit

let client = try LSPClient(launch: LSPServer.sourceKit())   // spawns sourcekit-lsp
try await client.start()
_ = try await client.initialize(rootURI: LSPURI.file(projectDir))
try await client.initialized()
try await client.didOpen(path: file)
for symbol in try await client.documentSymbol(path: file) { print(symbol.name) }
await client.shutdownAndExit()
```

## CLI

```sh
swift build --scratch-path /Volumes/SSD/SwiftPM/LSP

lsp symbols    Foo.swift            # the file's document-symbol tree
lsp hover      Foo.swift 7 12       # hover text at 0-based line:column
lsp definition Foo.swift 11 30      # jump-to-definition target(s)
lsp capabilities Foo.swift          # what the server advertises
```

Lines/columns are 0-based; columns are UTF-16 offsets (LSP convention).

`python3 probe.py` is the original throwaway reference flow (Python). The Swift
implementation reproduces it; see [GOALS.md](GOALS.md) for the roadmap (CLI done;
MCP server next).
