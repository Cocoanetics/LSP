# LSP

Greenfield exploration: drive a Language Server (starting with `sourcekit-lsp`)
from Swift via [JSONFoundation](https://github.com/Cocoanetics/JSONFoundation)'s
JSON-RPC types — en route to exposing **any** LSP as a CLI and an MCP server
(the same shape [SwiftACP](https://github.com/Cocoanetics/SwiftACP) gives ACP).

**Start with [GOALS.md](GOALS.md)** — the plan, the architecture, and the
gotchas (notably: LSP uses `Content-Length` header framing, *not* the
newline-delimited JSON-RPC that ACP/MCP-over-stdio use — which is why raw
`xcrun sourcekit-lsp` never answers).

```sh
python3 probe.py     # validated: drives sourcekit-lsp end-to-end and prints symbols
swift build          # the (empty) Swift scaffold
```
