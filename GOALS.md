# LSP — Goals & Advice for the Next Agent

A greenfield exploration: talk to a Language Server (starting with
`sourcekit-lsp`) from Swift using **JSONFoundation**'s JSON-RPC types, then grow
it into a library that exposes *any* LSP as both a **CLI** and an **MCP server**
— the same shape as [SwiftACP](file:///Users/oliver/Developer/SwiftACP) does for
the Agent Client Protocol.

---

## Status (2026-06-27): milestones 1–3 done — the unification already shipped

The advice below to **write the `Content-Length` transport yourself** and
**copy SwiftACP's `JSONRPCConnection` peer** is now **obsolete**. That open idea
— "extract a shared `JSONRPCPeer` package on top of JSONFoundation" — *landed* in
JSONFoundation 2.1: it now owns the whole runtime (`JSONRPCPeer`,
`ContentLengthFraming`/`LineFraming` in `JSONRPCWire`, and the `ProcessTransport`
stdio transport in `JSONRPCStdio`). SwiftACP already consumes it; so does LSPKit.

What's implemented (see `Sources/LSPKit`, all on the shared runtime — zero
hand-rolled transport/peer):

- `LSPClient` — `initialize`/`initialized`/`didOpen`/`didClose`/`documentSymbol`/
  `hover`/`definition`/`references`/`shutdown`+`exit`, over
  `JSONRPCPeer(transport: ProcessTransport(launch:, framing: ContentLengthFraming()))`.
- The `LSP*` value types (positions, ranges, symbols+`SymbolKind`, hover, locations).
- The `lsp` CLI (`symbols`/`hover`/`definition`/`capabilities`), reproducing
  `probe.py` end-to-end.
- A live `sourcekit-lsp` round-trip test (`LiveSourceKitTests`, skips if absent).

**Still open (milestone 4):** the MCP server — a `@MCPServer` (SwiftMCP) whose
`@MCPTool`s call `LSPClient`, the way SwiftACP's `acpxd` exposes ACP sessions.

The historical advice below is kept for context.

---

## TL;DR — why `xcrun sourcekit-lsp` "starts but never responds"

LSP does **not** use newline-delimited JSON-RPC (which is what ACP and
MCP-over-stdio use). It uses **HTTP-style `Content-Length` header framing**:

```
Content-Length: 123\r\n
\r\n
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{ … }}
```

If you type or pipe raw JSON, the server sits there waiting for a valid framed
message — forever. And even with framing, it does nothing until it receives an
`initialize` **request**, which you must follow with an `initialized`
**notification** before any normal request.

**This is already proven.** Run `python3 probe.py` in this folder — it spawns
`sourcekit-lsp`, does the handshake, opens a file, and prints its symbols:

```
initialize -> OK
  server advertises: callHierarchyProvider, codeActionProvider, definitionProvider, …
documentSymbol -> symbols in JSONRPCID.swift:
  - JSONRPCID (kind 10) + 4 children
```

`probe.py` is throwaway (Python) but it is the **reference for the exact wire
behavior** the Swift POC must reproduce. Read it first.

---

## The vision

```
                 ┌─────────────┐
   any LSP  ◄───►│  LSP client │◄───► CLI  (lspx-style: `lsp symbols Foo.swift`)
 (sourcekit-     │  (Swift)    │◄───► MCP server (tools: findSymbols, hover,
  lsp, clangd,   └─────────────┘        definition, references, diagnostics …)
  pyright, …)
```

- **CLI**: a human runs `lsp …` to interrogate a project.
- **MCP server**: an AI assistant gets LSP queries as MCP tools — "what's the
  type of the symbol at line N", "find references to `foo`", "list symbols in
  this file". This is the high-value end state: precise, compiler-grade code
  intelligence exposed to an agent.

The language server is launched as a **child process** (stdin/stdout), exactly
like SwiftACP's `SubprocessTransport` launches an ACP agent — only the framing
differs.

---

## The protocol you must implement (LSP 3.17 base + lifecycle)

1. **Framing** (both directions): `Content-Length: <bytes>\r\n\r\n<utf8-json>`.
   No other headers are required (`Content-Type` is optional and defaulted).
2. **Lifecycle handshake**:
   - → `initialize` request: `{ processId, rootUri | workspaceFolders, capabilities }`
   - ← server response: its `capabilities`
   - → `initialized` notification (empty params)
3. **Interrogation** (the POC payload):
   - → `textDocument/didOpen` notification with the file's `uri`, `languageId`
     (`"swift"`), `version`, and full `text` — the server answers queries against
     this in-memory copy.
   - → `textDocument/documentSymbol`, `textDocument/hover`,
     `textDocument/definition`, `textDocument/references`, … requests.
4. **Shutdown**: → `shutdown` request, then → `exit` notification.

Positions are `{ line, character }`, **0-based**, and `character` is a **UTF-16**
code-unit offset (not a Swift `String.Index`/grapheme/byte offset — get this
wrong and hovers land in the wrong place).

---

## Reuse JSONFoundation for the envelope

[JSONFoundation](file:///Users/oliver/Developer/JSONFoundation) **2.0.0** is the
right base and already does the JSON-RPC half:

- `JSONRPCMessage` (`.request` / `.notification` / `.response` / `.errorResponse`)
  with `decodeMessages(from:)`, `encoded()` / `encodedString()`, and accessors
  (`method`, `params`, `id`, `isRequest`, `replyOutcome`, …).
- **`params` and `result` are `JSONValue`** (as of 2.0) — exactly what LSP needs,
  because LSP payloads are arbitrarily shaped JSON (arrays, nulls, nested
  objects). The older object-only model would have been a poor fit.

What JSONFoundation does **not** give you, and you must write:

- the **Content-Length transport framing** (it's transport-specific — JSONFoundation
  is deliberately "wire model only, bring your own transport");
- the **peer** (request/response correlation + inbound dispatch).

Depend on it: `.package(url: "https://github.com/Cocoanetics/JSONFoundation.git", from: "2.0.0")`.

---

## Architecture — mirror SwiftACP

SwiftACP is the template. Study these files
(`/Users/oliver/Developer/SwiftACP/Sources/SwiftACP/`):

- `Transport/MessageTransport.swift` — a tiny transport protocol (`write` / inbound
  `AsyncThrowingStream` / `close`).
- `Transport/SubprocessTransport.swift` — spawns a child process, pipes stdin/stdout,
  has `waitForExit()` / `kill()`. **Copy this and swap the framing.**
- `JSONRPC/JSONRPCConnection.swift` — the JSON-RPC **peer** (actor): a pending
  `[id: continuation]` registry, `sendRequest`/`sendNotification`, and a `receive`
  loop that classifies inbound messages and dispatches requests/notifications.

The LSP pieces, smallest-new-surface first:

1. **`LSPFramedTransport`** — the only genuinely new code. Reads the wire as
   `Content-Length`-framed messages instead of newline-delimited lines, over a
   subprocess. Everything else is generic JSON-RPC.
2. **JSON-RPC peer** — *nearly identical* to SwiftACP's `JSONRPCConnection`.
   ⚠️ **Note for the bigger picture:** this is now the **third** project (SwiftMCP,
   SwiftACP, and LSP) that wants the same generic JSON-RPC correlator+dispatcher.
   There is an open idea to extract a shared `JSONRPCPeer` package on top of
   JSONFoundation. For the POC, **copy SwiftACP's `JSONRPCConnection`** to move
   fast; flag the duplication so it can be unified later.
3. **`LSPClient`** — typed lifecycle + methods (`initialize`, `initialized`,
   `didOpen`, `documentSymbol`, `hover`, …) returning decoded results.
4. **CLI + MCP** — thin layers over `LSPClient`. The MCP server is a `@MCPServer`
   (SwiftMCP) whose `@MCPTool`s call `LSPClient` queries. SwiftACP's `acpxd`
   (an MCP server holding live ACP sessions) is the pattern to copy.

A minimal `Package.swift` + stubs are already in this folder so you can
`swift build` on day one; restructure as you see fit.

---

## Suggested milestones

1. **Connect** — in Swift: spawn `sourcekit-lsp`, send a framed `initialize`,
   print the capabilities. (Reproduce `probe.py` step 1. This retires the
   "no response" problem for good.)
2. **Interrogate** — complete the handshake, `didOpen` a file from a real Swift
   package, `documentSymbol`, print the symbols. **This is the POC done.**
3. **Generalize** — extract the framed transport + peer; add `hover` and
   `definition`; make the launched server/command configurable (so clangd/pyright
   work too, not just sourcekit-lsp).
4. **Expose** — an `lsp` CLI and an MCP server surfacing the queries as tools.

---

## Gotchas & concrete advice

- **stderr is not the protocol.** `sourcekit-lsp` logs to stderr; keep stdout
  pure JSON-RPC. Capture/inherit stderr separately (the probe sends it to
  `/dev/null`).
- **`rootUri` must be a real `file://` URI** to a Swift package for useful
  answers, and you must `didOpen` a file (with its text) before querying it —
  the server answers against the in-memory document, not disk.
- **Skip server-initiated traffic when awaiting a reply.** The server sends
  `window/logMessage`, `$/progress`, publishDiagnostics, etc. unsolicited; match
  responses by `id` (see `await_response` in the probe). The peer's correlator
  handles this naturally.
- **Indexing is asynchronous.** `documentSymbol`/`hover` on an open document work
  immediately, but cross-file queries (`references`, workspace symbols) may need
  the background index to be ready — don't be surprised by empty early results.
- **It's a long-lived process.** Reuse SwiftACP's subprocess lifecycle
  (`waitForExit`/`kill`, graceful `shutdown`→`exit`), don't reinvent it.
- **`SymbolKind`/`CompletionItemKind` are integers** in the wire payload (e.g.
  enum = 10, the value seen above). Define enums for them, or look them up in the
  LSP spec.

---

## References

- **probe.py** (this folder) — the validated, working wire flow. Start here.
- **LSP 3.17 spec** —
  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
  (see *Base Protocol* for framing, *Lifecycle Messages* for the handshake,
  *Language Features* for documentSymbol/hover/definition).
- **SwiftACP** — `/Users/oliver/Developer/SwiftACP` — the structural template
  (subprocess transport, JSON-RPC peer, CLI `acpx`, MCP daemon `acpxd`).
- **JSONFoundation** — `/Users/oliver/Developer/JSONFoundation` — the JSON-RPC
  envelope (`JSONRPCMessage`, accessors, `encodedString()`).
- **SwiftMCP** — `/Users/oliver/Developer/SwiftMCP` — for the MCP-server layer
  (`@MCPServer` / `@MCPTool`).
