import Foundation
import JSONFoundation
import JSONRPCPeer
import JSONRPCStdio
import JSONRPCWire

/// A typed LSP client over a launched language server.
///
/// ## What's reused vs. what's here
///
/// The entire JSON-RPC machinery is JSONFoundation's unified runtime — the same
/// stack SwiftACP and SwiftMCP use:
///
/// - **Transport**: ``JSONRPCStdio/ProcessTransport`` spawns the server and pumps
///   its stdio, framing each message as `Content-Length: <n>\r\n\r\n<json>` via
///   ``JSONRPCWire/ContentLengthFraming``. LSP's *only* wire difference from ACP
///   (newline framing) is that one value.
/// - **Peer**: ``JSONRPCPeer/JSONRPCPeer`` correlates requests with responses by
///   `id`, dispatches server-initiated requests, and routes notifications —
///   skipping the unsolicited `window/logMessage`/`$/progress` traffic that would
///   otherwise be mistaken for a reply (the gotcha `probe.py` works around by
///   hand).
///
/// So this type is just LSP *semantics*: the lifecycle handshake and the typed
/// interrogation methods. It mirrors SwiftACP's `ACPAgentConnection`.
///
/// ```swift
/// let client = try LSPClient(launch: LSPServer.sourceKit())
/// try await client.start()
/// _ = try await client.initialize(rootURI: LSPURI.file(projectDir))
/// try await client.initialized()
/// try await client.didOpen(path: file)
/// let symbols = try await client.documentSymbol(path: file)
/// await client.shutdownAndExit()
/// ```
public actor LSPClient {
    private let rpc: JSONRPCPeer
    private let transport: ProcessTransport<ContentLengthFraming>
    private var logHandler: (@Sendable (LSPLogMessage) -> Void)?
    private var diagnosticsHandler: (@Sendable (LSPPublishDiagnostics) -> Void)?
    private var progressHandler: (@Sendable (LSPProgress) -> Void)?

    /// Spawn `launch` and build the peer over a `Content-Length`-framed stdio
    /// transport. Throws if the server process can't be launched.
    public init(launch: ProcessLaunch) throws {
        let transport = try ProcessTransport(launch: launch, framing: ContentLengthFraming())
        self.transport = transport
        self.rpc = JSONRPCPeer(transport: transport)
    }

    /// The server's process id (for diagnostics / killing).
    public var processIdentifier: Int32 { transport.processIdentifier }

    /// Observe the server's `window/logMessage` notifications (its diagnostics about
    /// itself, distinct from source diagnostics). Pass `nil` to stop.
    public func setLogHandler(_ handler: (@Sendable (LSPLogMessage) -> Void)?) {
        logHandler = handler
    }

    /// Observe `textDocument/publishDiagnostics` — the source warnings/errors the
    /// server pushes for open documents. Pass `nil` to stop.
    public func setDiagnosticsHandler(_ handler: (@Sendable (LSPPublishDiagnostics) -> Void)?) {
        diagnosticsHandler = handler
    }

    /// Observe `$/progress` work-done progress — `sourcekit-lsp` streams these for
    /// background indexing (begin → report* → end), with a percentage when it knows
    /// one. Drive a progress bar from this. Pass `nil` to stop.
    public func setProgressHandler(_ handler: (@Sendable (LSPProgress) -> Void)?) {
        progressHandler = handler
    }

    /// Begin reading inbound messages. Call once, before `initialize`.
    ///
    /// We install no request handler: the peer then auto-acknowledges every
    /// server-initiated request (`workspace/configuration`,
    /// `client/registerCapability`, `window/workDoneProgress/create`, …) with a
    /// null success — enough to keep `sourcekit-lsp` happy for read-only queries.
    public func start() async {
        await rpc.setHandlers(
            request: nil,
            notification: { [weak self] method, params in
                await self?.handleNotification(method: method, params: params)
            })
        await rpc.start()
    }

    // MARK: - Lifecycle

    /// `initialize` request → the server's capabilities. `rootURI` should be a real
    /// `file://` URI to the project so the server indexes it (see
    /// ``enclosingProjectRoot(for:)``).
    @discardableResult
    public func initialize(
        rootURI: String?,
        clientName: String = "lspkit",
        clientVersion: String = "0.1.0"
    ) async throws -> LSPInitializeResult {
        let params: JSONValue = [
            "processId": .integer(Int(ProcessInfo.processInfo.processIdentifier)),
            "rootUri": rootURI.map { JSONValue.string($0) } ?? .null,
            "clientInfo": ["name": .string(clientName), "version": .string(clientVersion)],
            "capabilities": [
                "textDocument": [
                    "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "definition": ["linkSupport": true],
                    "publishDiagnostics": ["relatedInformation": true]
                ],
                // Opt in to server-initiated work-done progress so `sourcekit-lsp`
                // creates an indexing token and streams `$/progress` we can render.
                "window": ["workDoneProgress": true]
            ]
        ]
        return try await request("initialize", params).decoded(LSPInitializeResult.self)
    }

    /// `initialized` notification — completes the handshake. Required before any
    /// normal request.
    public func initialized() async throws {
        try await notify("initialized", [:])
    }

    /// `workspace/synchronize` with `index: true` — `sourcekit-lsp`'s request to wait
    /// until its build graph is current *and* background indexing has finished before
    /// returning. A deterministic "the index is ready" signal: no polling, no timers
    /// — you `await` it and it returns when indexing has drained (immediately if the
    /// index is already up to date). Supersedes the older `workspace/_pollIndex`; not
    /// LSP spec, but it's the hook `sourcekit-lsp`'s own tests use.
    public func waitForIndex() async throws {
        _ = try await request("workspace/synchronize", ["index": .bool(true)])
    }

    /// `shutdown` request then `exit` notification — the orderly teardown — and
    /// close the transport (terminating the process).
    public func shutdownAndExit() async {
        _ = try? await request("shutdown", nil)
        try? await notify("exit", nil)
        transport.close()
    }

    /// Suspend until the server process exits.
    @discardableResult
    public func waitForExit() async -> ProcessExit {
        await transport.waitForExit()
    }

    // MARK: - Documents

    /// `textDocument/didOpen` — hand the server the file's text so it can answer
    /// queries against the in-memory copy (the server does *not* read disk for
    /// open documents). `text` defaults to the file's current contents on disk.
    public func didOpen(
        path: String, languageId: String? = nil, version: Int = 1, text: String? = nil
    ) async throws {
        let source = try text ?? String(contentsOfFile: path, encoding: .utf8)
        let params: JSONValue = [
            "textDocument": [
                "uri": .string(LSPURI.file(path)),
                "languageId": .string(languageId ?? lspLanguageId(forPath: path)),
                "version": .integer(version),
                "text": .string(source)
            ]
        ]
        try await notify("textDocument/didOpen", params)
    }

    /// `textDocument/didClose`.
    public func didClose(path: String) async throws {
        let params: JSONValue = ["textDocument": ["uri": .string(LSPURI.file(path))]]
        try await notify("textDocument/didClose", params)
    }

    // MARK: - Interrogation

    /// `textDocument/documentSymbol` — the file's hierarchical symbol tree.
    public func documentSymbol(path: String) async throws -> [LSPDocumentSymbol] {
        let params: JSONValue = ["textDocument": ["uri": .string(LSPURI.file(path))]]
        let result = try await request("textDocument/documentSymbol", params)
        if case .null = result { return [] }
        return try result.decoded([LSPDocumentSymbol].self)
    }

    /// `workspace/symbol` — a project-wide, index-backed fuzzy search by name,
    /// returning every matching symbol as `{ name, kind, location }`. Unlike the
    /// `textDocument/*` queries it needs no `didOpen` and no position: it reads the
    /// background index, so it's the natural *name → location* entry point.
    ///
    /// The index builds asynchronously after `initialize`, so an early call on a
    /// cold project can return fewer results (or none) before indexing settles —
    /// retry, or drive it through a readiness wait at the call site.
    public func workspaceSymbol(_ query: String) async throws -> [LSPSymbolInformation] {
        let params: JSONValue = ["query": .string(query)]
        let result = try await request("workspace/symbol", params)
        if case .null = result { return [] }
        return try result.decoded([LSPSymbolInformation].self)
    }

    /// `textDocument/hover` at a 0-based `(line, character)` (UTF-16 column).
    public func hover(path: String, line: Int, character: Int) async throws -> LSPHover? {
        let result = try await request(
            "textDocument/hover", positionParams(path: path, line: line, character: character))
        if case .null = result { return nil }
        return try result.decoded(LSPHover.self)
    }

    /// `textDocument/definition` — where the symbol at the position is defined.
    /// Servers may answer with `Location`, `Location[]`, or `LocationLink[]`; all
    /// three are normalized to ``LSPLocation``.
    public func definition(path: String, line: Int, character: Int) async throws -> [LSPLocation] {
        let result = try await request(
            "textDocument/definition", positionParams(path: path, line: line, character: character))
        return Self.locations(from: result)
    }

    /// `textDocument/references` — uses of the symbol at the position. Cross-file
    /// results depend on the background index being ready, so early calls may
    /// return fewer than expected.
    public func references(
        path: String, line: Int, character: Int, includeDeclaration: Bool = true
    ) async throws -> [LSPLocation] {
        var params = positionParams(path: path, line: line, character: character)
        if case .object(var object) = params {
            object["context"] = ["includeDeclaration": .bool(includeDeclaration)]
            params = .object(object)
        }
        let result = try await request("textDocument/references", params)
        return Self.locations(from: result)
    }

    // MARK: - Plumbing

    private func positionParams(path: String, line: Int, character: Int) -> JSONValue {
        [
            "textDocument": ["uri": .string(LSPURI.file(path))],
            "position": ["line": .integer(line), "character": .integer(character)]
        ]
    }

    private func request(_ method: String, _ params: JSONValue?) async throws -> JSONValue {
        try await rpc.sendRequest(method: method, params: params)
    }

    private func notify(_ method: String, _ params: JSONValue?) async throws {
        try await rpc.sendNotification(method: method, params: params)
    }

    /// Normalize a `definition`/`references` result (`Location` | `Location[]` |
    /// `LocationLink[]` | `null`) into a flat `[LSPLocation]`.
    private static func locations(from result: JSONValue) -> [LSPLocation] {
        if case .null = result { return [] }
        if let single = try? result.decoded(LSPLocation.self) { return [single] }
        if let many = try? result.decoded([LSPLocation].self) { return many }
        if let links = try? result.decoded([LSPLocationLink].self) { return links.map(\.asLocation) }
        return []
    }

    private func handleNotification(method: String, params: JSONValue?) async {
        switch method {
        case "window/logMessage":
            if let params, let message = try? params.decoded(LSPLogMessage.self) {
                logHandler?(message)
            }
        case "textDocument/publishDiagnostics":
            if let params, let diagnostics = try? params.decoded(LSPPublishDiagnostics.self) {
                diagnosticsHandler?(diagnostics)
            }
        case "$/progress":
            if let params, let progress = try? params.decoded(LSPProgress.self) {
                progressHandler?(progress)
            }
        default:
            break // telemetry, etc. — ignored.
        }
    }
}

/// `window/logMessage` payload — the server talking about itself.
public struct LSPLogMessage: Codable, Sendable {
    /// 1 = error, 2 = warning, 3 = info, 4 = log.
    public var type: Int
    public var message: String
}

/// `textDocument/publishDiagnostics` payload — source warnings/errors for one URI.
public struct LSPPublishDiagnostics: Codable, Sendable {
    public var uri: String
    public var diagnostics: [LSPDiagnostic]
}

/// One diagnostic (warning/error) at a range in a document.
public struct LSPDiagnostic: Codable, Sendable {
    public var range: LSPRange
    /// 1 = error, 2 = warning, 3 = information, 4 = hint.
    public var severity: Int?
    public var message: String
}
