//
//  `lsp` — the CLI front-end (greenfield stub).
//
//  Goal: `lsp symbols Foo.swift`, `lsp hover Foo.swift:10:5`, etc. — a thin
//  layer over LSPKit's LSPClient. See ../../GOALS.md.
//

import LSPKit

print("""
lsp — greenfield. Nothing wired up yet.

Next steps live in GOALS.md. For the validated LSP wire flow (Content-Length
framing + initialize handshake + documentSymbol against a real project), run:

    python3 probe.py

\(LSPKit.about)
""")
