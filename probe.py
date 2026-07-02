#!/usr/bin/env python3
"""Probe: drive `sourcekit-lsp` with Content-Length-framed JSON-RPC.

This validates the two things that trip people up with raw `xcrun sourcekit-lsp`:

  1. LSP uses HTTP-style `Content-Length:` header framing, NOT newline-delimited
     JSON (which is what ACP/MCP-over-stdio use). Pipe raw JSON and the server
     waits forever — that's why you "never get a response back".
  2. The server does nothing until it receives an `initialize` request, and you
     must follow it with the `initialized` notification before normal requests.

It then proves the POC goal — connect to a project and interrogate it — by
opening a source file and asking for its document symbols.

The Swift implementation should mirror this exactly, using JSONFoundation's
`JSONRPCMessage` for the envelope over a Content-Length transport (see GOALS.md).

Run:  python3 probe.py
"""
import subprocess
import json
import os

# Probe this very repo, so it runs out of the box on a fresh clone.
PROJECT = os.path.dirname(os.path.abspath(__file__))
FILE = os.path.join(PROJECT, "Sources/LSPKit/LSPClient.swift")


def frame(msg: dict) -> bytes:
    """Serialize one JSON-RPC message with the LSP base-protocol header framing."""
    body = json.dumps(msg).encode()
    return b"Content-Length: %d\r\n\r\n%s" % (len(body), body)


def read_message(stream):
    """Read one framed message: parse the header block, then exactly N body bytes."""
    length = None
    while True:
        line = stream.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break  # end of headers
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":")[1].strip())
    body = b""
    while len(body) < length:
        chunk = stream.read(length - len(body))
        if not chunk:
            return None
        body += chunk
    return json.loads(body)


def await_response(stream, want_id):
    """Skip server-initiated notifications/log messages until the reply to want_id."""
    while True:
        msg = read_message(stream)
        if msg is None:
            return None
        if msg.get("id") == want_id and ("result" in msg or "error" in msg):
            return msg


proc = subprocess.Popen(
    ["xcrun", "sourcekit-lsp"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,  # sourcekit-lsp logs to stderr; keep stdout pure JSON-RPC
)


def send(msg):
    proc.stdin.write(frame(msg))
    proc.stdin.flush()


# 1) initialize — without this the server stays silent.
send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "processId": os.getpid(),
    "rootUri": "file://" + PROJECT,
    "capabilities": {},
}})
init = await_response(proc.stdout, 1)
print("initialize ->", "OK" if init and "result" in init else "FAILED")
if init and "result" in init:
    caps = sorted(init["result"].get("capabilities", {}).keys())
    print("  server advertises:", ", ".join(caps[:10]))

# 2) initialized notification — completes the handshake.
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

# 3) open the document (server needs the text in memory to answer queries).
with open(FILE) as handle:
    text = handle.read()
send({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
    "textDocument": {"uri": "file://" + FILE, "languageId": "swift", "version": 1, "text": text},
}})

# 4) interrogate — document symbols.
send({"jsonrpc": "2.0", "id": 2, "method": "textDocument/documentSymbol", "params": {
    "textDocument": {"uri": "file://" + FILE},
}})
resp = await_response(proc.stdout, 2)
print("documentSymbol -> symbols in %s:" % os.path.basename(FILE))
for sym in (resp or {}).get("result", []) or []:
    children = sym.get("children", [])
    print("  - %s (kind %s)%s" % (
        sym.get("name"), sym.get("kind"),
        " + %d children" % len(children) if children else "",
    ))

# 5) orderly shutdown.
send({"jsonrpc": "2.0", "id": 3, "method": "shutdown"})
await_response(proc.stdout, 3)
send({"jsonrpc": "2.0", "method": "exit"})
proc.terminate()
