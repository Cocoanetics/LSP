# LSP

Drive a **Language Server** (starting with `sourcekit-lsp`) from Swift, and expose
its code intelligence as a **CLI** and an **MCP server** an AI agent can call.

`LSP` is built on [JSONFoundation](https://github.com/Cocoanetics/JSONFoundation)'s
**unified JSON-RPC runtime** — and is, in fact, the testbed that proved that runtime
generalizes. LSP, [ACP](https://github.com/Cocoanetics/SwiftACP), and
[MCP](https://github.com/Cocoanetics/SwiftMCP) are all JSON-RPC over stdio; they
differ on exactly **one** axis — LSP uses HTTP-style `Content-Length` header framing
where ACP/MCP use newline-delimited JSON. JSONFoundation 2.1+ owns the whole stack
(the peer, both framing codecs, the stdio transport), so LSPKit writes **no**
transport and **no** peer of its own — just the typed LSP methods on top:

```swift
import LSPKit

let client = try LSPClient(launch: LSPServer.sourceKit())   // spawns sourcekit-lsp
await client.start()
_ = try await client.initialize(rootURI: LSPURI.file(projectDir))
try await client.initialized()
try await client.didOpen(path: file)
for symbol in try await client.documentSymbol(path: file) { print(symbol.name) }
await client.shutdownAndExit()
```

The high-value end state is the **MCP server**: precise, compiler-grade code
intelligence — "check this file for errors", "where is `Foo` defined", "find every
reference to this symbol" — handed to an agent as tools, without it having to read and
parse source itself.

---

## What's in the box

| Product | What it is |
| --- | --- |
| **`LSPKit`** | A library: `LSPClient` (typed LSP lifecycle + queries), `LSPServer` (launch descriptors), and the `LSP*` value types. |
| **`lsp`** | An executable that is both a **CLI** (`lsp symbols Foo.swift`) and an **MCP server** (`lsp mcp`). |

## Requirements

- **macOS 14+** and a **Swift 6.1** toolchain.
- `sourcekit-lsp`, resolved through `xcrun` — i.e. an installed **Xcode** or Command
  Line Tools. (Other servers work too — see [Other language servers](#other-language-servers).)

## Build

```sh
git clone https://github.com/Cocoanetics/LSP.git
cd LSP
swift build            # or: swift build -c release
```

The built `lsp` binary lands in `.build/debug/lsp` (or `.build/release/lsp`).

---

## CLI

Every subcommand spawns a fresh `sourcekit-lsp`, runs the LSP handshake against the
enclosing Swift package, answers, and tears the server down.

```sh
lsp where       Foo                      # find symbols named "Foo" project-wide (index-backed)
lsp decl        Foo                      # print the declaration/signature of "Foo"
lsp check       Sources/App/Foo.swift    # syntax + semantic errors, no build required
lsp symbols     Sources/App/Foo.swift    # the file's document-symbol tree
lsp hover       Sources/App/Foo.swift 7 12   # hover text at a 0-based line:column
lsp definition  Sources/App/Foo.swift 11 30  # jump-to-definition target(s)
lsp references  Sources/App/Foo.swift 11 30  # every use of the symbol, project-wide
lsp capabilities Sources/App/Foo.swift   # what the server advertises
lsp mcp         .                        # run as an MCP server over stdio (see below)
```

| Command | Purpose | Notable options |
| --- | --- | --- |
| `where <query> [dir]` | Find symbols by name across the project (index-backed). | `--scope project\|dependencies\|all`, `--exact`, `--json` |
| `decl <query> [dir]` | Print a symbol's declaration (signature; full doc with `--full`). | `--scope`, `--exact`, `--full`, `--json` |
| `check <file>` | Report syntax/semantic errors (LSP diagnostics), no build. | `--json` |
| `symbols <file>` | List the file's document symbols as a hierarchy. | |
| `hover <file> <line> <col>` | Hover text (type, signature, docs) at a position. | |
| `definition <file> <line> <col>` | Where the symbol at a position is defined. | |
| `references <file> <line> <col>` | Every use of the symbol at a position, project-wide. | |
| `capabilities <file-or-dir>` | Print the server's advertised capabilities. | |
| `mcp [dir]` | Run as an MCP server (stdio, or HTTP+SSE). | `--http-port`, `--http-host`, `--token` |

**Positions in the CLI are 0-based**, and the column is a **UTF-16** code-unit offset
— the LSP convention. (The MCP tools below are 1-based, matching what an editor shows.)

`where`/`decl`/`references` depend on `sourcekit-lsp`'s **background index**; a
progress bar is shown on stderr while it builds, so `--json` on stdout stays clean and
pipeable.

---

## MCP server — code intelligence for an agent

`lsp mcp [project-dir]` runs the same queries as an **MCP server over stdio**, backed by
a single long-lived `sourcekit-lsp` whose index is built once and stays warm across
calls. Point any MCP client (Claude Code, etc.) at it:

```jsonc
{
  "mcpServers": {
    "lsp": {
      "type": "stdio",
      "command": "/absolute/path/to/LSP/.build/release/lsp",
      "args": ["mcp", "/absolute/path/to/your/project"]
    }
  }
}
```

During development you can skip the build step and let SwiftPM run it (this repo ships a
[`.mcp.json`](.mcp.json) that does exactly this for its own directory):

```jsonc
{ "mcpServers": { "lsp": { "type": "stdio",
    "command": "swift", "args": ["run", "lsp", "mcp", "."] } } }
```

### HTTP+SSE

For a long-running server that outward clients connect to (rather than launch), pass
`--http-port` to serve over HTTP+SSE instead of stdio — the same shape SwiftACP's
`acpxd` and the SwiftMCP demo expose:

```sh
lsp mcp /path/to/project --http-port 8080                 # http://127.0.0.1:8080/mcp
lsp mcp /path/to/project --http-port 8080 --token secret  # require a bearer token
lsp mcp /path/to/project --http-port 8080 --http-host 0.0.0.0  # expose beyond loopback
```

| Option | Meaning |
| --- | --- |
| `--http-port <port>` | Serve over HTTP+SSE on this port instead of stdio. The MCP endpoint is `/<host>:<port>/mcp`. |
| `--http-host <host>` | Bind address. Defaults to `127.0.0.1` (loopback); pass `0.0.0.0` only if you intend it to be reachable from other machines. |
| `--token <token>` | Require this bearer token on every request. **Omitted ⇒ unauthenticated** — fine on loopback, risky when combined with `--http-host 0.0.0.0`. |

### Tools

| Tool | What it answers |
| --- | --- |
| `check_file(file)` | Syntax + semantic errors from an in-memory type-check — validate an edit **before** paying for a full build. |
| `find_symbol(query, scope, exact)` | Turn a name into file locations, without reading files. |
| `declaration(query, scope, exact, includeDocumentation)` | A symbol's signature (and optionally its doc comment), by name. |
| `hover(file, line, column)` | Type / signature / docs at a position. |
| `definition(file, line, column)` | Where the symbol at a position is defined. |
| `references(file, line, column)` | Every use of the symbol at a position, project-wide. |
| `document_symbols(file)` | The types/methods/properties declared in a file, as a tree. |

**MCP tool positions are 1-based** (line 1 = first line, column 1 = first character),
matching what an editor shows; they're converted to LSP's 0-based internally.

If the language server dies (crash, or an external `kill`), the session detects the exit
and respawns on the next tool call, rather than handing out a dead connection.

---

## Other language servers

`sourcekit-lsp` is the default, but the launch is just a process descriptor. Any
LSP-speaking server works:

```swift
let clangd  = try LSPClient(launch: LSPServer.command("clangd"))
let pyright = try LSPClient(launch: LSPServer.command("pyright-langserver", ["--stdio"]))
```

`lspLanguageId(forPath:)` already maps common extensions (`.swift`, `.m`, `.c`, `.cpp`,
`.py`, …) to the `languageId` a server expects in `didOpen`.

---

## How it works

The wire format is the one thing people trip over with raw `sourcekit-lsp`: it uses
HTTP-style header framing, not newline-delimited JSON.

```
Content-Length: 123\r\n
\r\n
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{ … }}
```

Pipe raw JSON and the server waits forever. And even framed, it does nothing until it
receives an `initialize` **request** followed by an `initialized` **notification**.

[`probe.py`](probe.py) is a ~100-line, dependency-free Python script that demonstrates
the entire flow (framing → handshake → `didOpen` → `documentSymbol` → shutdown). It was
the reference the Swift implementation was validated against; run `python3 probe.py`
against this repo to see it live.

In Swift, that whole runtime — request/response correlation, inbound dispatch,
`Content-Length` framing, and the `Foundation.Process` stdio transport — comes from
JSONFoundation:

```
JSONFoundation   JSONValue · the JSONRPCMessage envelope
JSONRPCPeer      the transport-agnostic correlator + dispatcher
JSONRPCWire      framing codecs — ContentLengthFraming is LSP's wire format
JSONRPCStdio     ProcessTransport — a zero-dependency Process stdio transport
```

LSPKit is `JSONRPCPeer(transport: ProcessTransport(launch:, framing: ContentLengthFraming()))`
plus the typed LSP methods. See [GOALS.md](GOALS.md) for the design narrative and
roadmap.

---

## Project layout

```
Sources/LSPKit/       the library — LSPClient, LSPServer, LSP* models, query support
Sources/lsp/          the executable
  Commands/           one file per CLI subcommand (where, decl, check, …)
  Support/            connection lifecycle, indexing monitor, output formatting
  LSPMCPServer.swift  the @MCPServer exposing the tools
  LSPSession.swift    the warm, self-respawning sourcekit-lsp the MCP server holds
Tests/LSPKitTests/    unit tests + a live sourcekit-lsp round-trip (skips if absent)
probe.py              the throwaway reference wire flow (Python)
```

## License

BSD 2-Clause. See [LICENSE](LICENSE).
