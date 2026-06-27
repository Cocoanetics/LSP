//
//  `lsp` — a thin CLI over LSPKit's `LSPClient`, the Swift counterpart of the
//  validated `probe.py` flow: spawn `sourcekit-lsp`, run the lifecycle handshake,
//  `didOpen` a file, and interrogate it.
//
//  Usage:
//    lsp where <query> [project-dir]          find symbols by name across the project
//    lsp decl <query> [project-dir]           print a symbol's declaration (signature, +doc)
//    lsp check <file.swift>                   report syntax/semantic errors (LSP diagnostics)
//    lsp symbols <file.swift>                 list the file's document symbols
//    lsp hover <file.swift> <line> <col>      hover at a 0-based line:column
//    lsp definition <file.swift> <line> <col> jump-to-definition target(s)
//    lsp capabilities <file-or-dir>           initialize and print server capabilities
//
//  Lines/columns are 0-based; the column is a UTF-16 offset (LSP convention).
//

import Foundation
import LSPKit

@main
struct LSPCommand {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printUsage()
            exit(EXIT_FAILURE)
        }

        do {
            switch command {
            case "where":
                try await whereSymbol(arguments: Array(arguments.dropFirst()))
            case "decl":
                try await declaration(arguments: Array(arguments.dropFirst()))
            case "check":
                try await check(arguments: Array(arguments.dropFirst()))
            case "symbols":
                try await symbols(arguments: Array(arguments.dropFirst()))
            case "hover":
                try await hover(arguments: Array(arguments.dropFirst()))
            case "definition":
                try await definition(arguments: Array(arguments.dropFirst()))
            case "capabilities":
                try await capabilities(arguments: Array(arguments.dropFirst()))
            case "-h", "--help", "help":
                printUsage()
            default:
                FileHandle.standardError.write(Data("Unknown command: \(command)\n\n".utf8))
                printUsage()
                exit(EXIT_FAILURE)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    // MARK: - Commands

    /// `workspace/symbol`: the name → location front door. Roots the server at the
    /// project enclosing `<target>` (default: the current directory), then searches
    /// the background index — waiting for it to warm up if the first hits are empty.
    static func whereSymbol(arguments: [String]) async throws {
        let options = try SearchOptions(parsing: arguments, verb: "where")

        let client = try LSPClient(launch: LSPServer.sourceKit())
        let indexing = IndexingMonitor()
        await client.setProgressHandler { indexing.handle($0) }
        await client.start()
        _ = try await client.initialize(rootURI: LSPURI.file(options.root))
        try await client.initialized()

        let matches = try await searchWaitingForIndex(
            client, query: options.query, scope: options.scope, exact: options.exact, indexing: indexing)

        if options.json {
            printJSON(matches.map(SymbolResult.init))
        } else if matches.isEmpty {
            print("(no symbols matching \"\(options.query)\")")
        } else {
            for match in matches { print(formatSymbol(match, root: options.root)) }
        }
        await client.shutdownAndExit()
    }

    /// `workspace/symbol` reads the background index, which builds asynchronously
    /// after `initialize`. We block on `workspace/synchronize` until that index is
    /// complete, **then** query — so we never trust a partial index.
    ///
    /// Querying first would be wrong: a partial index — left by an earlier
    /// interrupted run — answers immediately, but with incomplete, often junk
    /// matches (the "returned at 41%" bug). `synchronize` returns at once when the
    /// index is already up to date, so the warm path stays fast.
    static func searchWaitingForIndex(
        _ client: LSPClient, query: String, scope: SymbolScope, exact: Bool, indexing: IndexingMonitor
    ) async throws -> [LSPSymbolInformation] {
        // Block on `sourcekit-lsp`'s own "index is ready" signal rather than guessing
        // with timers: `workspace/synchronize` returns only once background indexing
        // has drained. The progress bar still renders from `$/progress` while this awaits.
        try await client.waitForIndex()
        indexing.finish() // clear any bar the final `$/progress` didn't.

        // The index is complete now, so a single query is authoritative.
        return (try await matchingSymbols(client, query: query, scope: scope, exact: exact)) ?? []
    }

    /// One `workspace/symbol` call, narrowed by `scope` (and `exact`). Always drops
    /// compiler-synthesized symbols (mangled `$s…` names from macro expansions like
    /// Swift Testing's `@Test`); `scope` then decides project vs. dependency hits —
    /// fuzzy `workspace/symbol` matches subsequences across every indexed dependency
    /// (`LSPClient` ⇒ `cancelTaskAndUpstream…`), so the default excludes them. With
    /// `exact`, keep only symbols whose base name (the identifier before any
    /// argument-label `(…)`) equals the query — the way to pin one declaration out of
    /// the fuzzy haystack. Returns `nil` for "no matches" vs. `[]`.
    static func matchingSymbols(
        _ client: LSPClient, query: String, scope: SymbolScope, exact: Bool
    ) async throws -> [LSPSymbolInformation]? {
        let matches = try await client.workspaceSymbol(query).filter { symbol in
            guard !symbol.name.hasPrefix("$"), scope.includes(uri: symbol.location.uri) else {
                return false
            }
            return exact ? baseName(of: symbol.name) == query : true
        }
        return matches.isEmpty ? nil : matches
    }

    /// The identifier portion of a symbol name, dropping any `(argument:labels:)`
    /// suffix — so `MCPTool(name:description:)` and the type `MCPTool` both reduce to
    /// `MCPTool` for exact comparison.
    static func baseName(of name: String) -> String {
        guard let paren = name.firstIndex(of: "(") else { return name }
        return String(name[..<paren])
    }

    /// `decl <query> [project-dir] [--full] [--scope …] [--json]`: the one-shot of
    /// `where` → `hover`. Finds a symbol by name, then prints its declaration at each
    /// match — the signature alone by default, the full hover (signature + doc) with
    /// `--full`, or a structured array with `--json` (which always carries both).
    /// Overloads/same-name symbols each get their own block.
    static func declaration(arguments: [String]) async throws {
        let options = try SearchOptions(parsing: arguments, verb: "decl")

        let client = try LSPClient(launch: LSPServer.sourceKit())
        let indexing = IndexingMonitor()
        await client.setProgressHandler { indexing.handle($0) }
        await client.start()
        _ = try await client.initialize(rootURI: LSPURI.file(options.root))
        try await client.initialized()

        let matches = try await searchWaitingForIndex(
            client, query: options.query, scope: options.scope, exact: options.exact, indexing: indexing)
        if matches.isEmpty {
            if options.json { print("[]") } else { print("(no symbols matching \"\(options.query)\")") }
            await client.shutdownAndExit()
            return
        }

        // `hover` answers against the in-memory document, so each file must be
        // opened first — open each distinct file once.
        var openedFiles: Set<String> = []
        var jsonResults: [DeclarationResult] = []
        for (index, match) in matches.enumerated() {
            guard let path = LSPURI.path(match.location.uri) else { continue }
            if openedFiles.insert(path).inserted { try? await client.didOpen(path: path) }

            let start = match.location.range.start
            let hover = (try? await client.hover(path: path, line: start.line, character: start.character)) ?? nil

            if options.json {
                jsonResults.append(DeclarationResult(
                    name: match.name,
                    kind: match.symbolKind,
                    containerName: match.containerName,
                    location: match.location,
                    signature: hover.map { signature(fromHover: $0.value) },
                    documentation: hover?.value))
                continue
            }

            if index > 0 { print("") }
            print(formatSymbol(match, root: options.root))
            if let hover {
                let body = options.full ? hover.value : signature(fromHover: hover.value)
                for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                    print("  \(line)")
                }
            } else {
                print("  (no declaration info)")
            }
        }
        if options.json { printJSON(jsonResults) }
        await client.shutdownAndExit()
    }

    /// `check <file> [--json]`: lint one file via LSP diagnostics — syntax *and*
    /// semantic errors (undeclared symbols, type mismatches) from sourcekit-lsp's
    /// in-memory type-check, no full build needed. `didOpen` hands the server the
    /// file's text; it pushes `textDocument/publishDiagnostics` once it has
    /// type-checked. We gate on `workspace/synchronize` first so the target is
    /// prepared and the *semantic* diagnostics are accurate, not just syntactic.
    static func check(arguments: [String]) async throws {
        let json = arguments.contains("--json")
        guard let file = arguments.first(where: { !$0.hasPrefix("--") }) else {
            throw usageError("check <file> [--json]")
        }
        let path = absolute(file)
        let root = enclosingProjectRoot(for: path)

        let client = try LSPClient(launch: LSPServer.sourceKit())
        let indexing = IndexingMonitor()
        let collector = DiagnosticsCollector(targetPath: path)
        await client.setProgressHandler { indexing.handle($0) }
        await client.setDiagnosticsHandler { collector.record(uri: $0.uri, diagnostics: $0.diagnostics) }
        await client.start()
        _ = try await client.initialize(rootURI: LSPURI.file(root))
        try await client.initialized()
        try await client.didOpen(path: path)

        // Prepare the target (build graph + index) so semantic diagnostics resolve
        // project symbols correctly; then make sure we've received a publish.
        try await client.waitForIndex()
        indexing.finish()
        await collector.waitForFirstPublish(fallbackMilliseconds: 3_000)

        let diagnostics = collector.diagnostics.sorted {
            ($0.range.start.line, $0.range.start.character) < ($1.range.start.line, $1.range.start.character)
        }
        if json {
            printJSON(diagnostics.map { DiagnosticResult($0, root: root, uri: collector.targetURI) })
        } else if diagnostics.isEmpty {
            print("no issues")
        } else {
            for diagnostic in diagnostics { print(formatDiagnostic(diagnostic, root: root, uri: collector.targetURI)) }
            let errors = diagnostics.filter { $0.severity == 1 }.count
            let warnings = diagnostics.filter { $0.severity == 2 }.count
            print("\(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")")
        }
        await client.shutdownAndExit()
    }

    static func formatDiagnostic(_ diagnostic: LSPDiagnostic, root: String, uri: String) -> String {
        let start = diagnostic.range.start
        return "\(shorten(uri, root: root)):\(start.line + 1):\(start.character + 1): "
            + "\(severityLabel(diagnostic.severity)): \(diagnostic.message)"
    }

    /// LSP `DiagnosticSeverity`: 1 = error, 2 = warning, 3 = information, 4 = hint.
    static func severityLabel(_ severity: Int?) -> String {
        switch severity {
        case 1: return "error"
        case 2: return "warning"
        case 3: return "note"
        case 4: return "hint"
        default: return "error" // unspecified severity is treated as an error by LSP
        }
    }

    /// Pull the first fenced code block — the declaration signature — out of hover
    /// markdown. Falls back to the whole (trimmed) text when there's no fence.
    static func signature(fromHover markdown: String) -> String {
        var inFence = false
        var collected: [Substring] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                if inFence { break } // end of the first block
                inFence = true
                continue
            }
            if inFence { collected.append(line) }
        }
        return collected.isEmpty
            ? markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            : collected.joined(separator: "\n")
    }

    /// Reproduce the POC: handshake, open the file, print its symbol tree.
    static func symbols(arguments: [String]) async throws {
        guard let file = arguments.first else { throw usageError("symbols <file>") }
        let path = absolute(file)
        let client = try await connected(forFile: path)
        try await client.didOpen(path: path)
        let tree = try await client.documentSymbol(path: path)
        if tree.isEmpty {
            print("(no symbols)")
        } else {
            for symbol in tree { printSymbol(symbol, indent: 0) }
        }
        await client.shutdownAndExit()
    }

    static func hover(arguments: [String]) async throws {
        guard arguments.count >= 3,
              let line = Int(arguments[1]), let column = Int(arguments[2]) else {
            throw usageError("hover <file> <line> <col>")
        }
        let path = absolute(arguments[0])
        let client = try await connected(forFile: path)
        try await client.didOpen(path: path)
        if let hover = try await client.hover(path: path, line: line, character: column) {
            print(hover.value)
        } else {
            print("(no hover)")
        }
        await client.shutdownAndExit()
    }

    static func definition(arguments: [String]) async throws {
        guard arguments.count >= 3,
              let line = Int(arguments[1]), let column = Int(arguments[2]) else {
            throw usageError("definition <file> <line> <col>")
        }
        let path = absolute(arguments[0])
        let client = try await connected(forFile: path)
        try await client.didOpen(path: path)
        let locations = try await client.definition(path: path, line: line, character: column)
        if locations.isEmpty {
            print("(no definition)")
        } else {
            let root = enclosingProjectRoot(for: path)
            for location in locations { print(format(location, root: root)) }
        }
        await client.shutdownAndExit()
    }

    static func capabilities(arguments: [String]) async throws {
        guard let target = arguments.first else { throw usageError("capabilities <file-or-dir>") }
        let path = absolute(target)
        let client = try LSPClient(launch: LSPServer.sourceKit())
        await client.start()
        let result = try await client.initialize(rootURI: LSPURI.file(enclosingProjectRoot(for: path)))
        if let name = result.serverName {
            print("server: \(name)\(result.serverVersion.map { " \($0)" } ?? "")")
        }
        print("capabilities (\(result.capabilityNames.count)):")
        for capability in result.capabilityNames { print("  - \(capability)") }
        await client.shutdownAndExit()
    }

    // MARK: - Shared handshake

    /// Spawn `sourcekit-lsp`, `initialize` (rooted at the file's package), and send
    /// `initialized` — leaving the client ready for `didOpen` + queries.
    static func connected(forFile path: String) async throws -> LSPClient {
        let client = try LSPClient(launch: LSPServer.sourceKit())
        await client.start()
        _ = try await client.initialize(rootURI: LSPURI.file(enclosingProjectRoot(for: path)))
        try await client.initialized()
        return client
    }

    // MARK: - Output

    static func printSymbol(_ symbol: LSPDocumentSymbol, indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        let kind = symbol.symbolKind?.displayName ?? "kind \(symbol.kind)"
        let detail = symbol.detail.map { " — \($0)" } ?? ""
        print("\(pad)\(symbol.name) [\(kind)]\(detail)")
        for child in symbol.children ?? [] { printSymbol(child, indent: indent + 1) }
    }

    static func formatSymbol(_ symbol: LSPSymbolInformation, root: String) -> String {
        let kind = symbol.symbolKind?.displayName ?? "kind \(symbol.kind)"
        let container = symbol.containerName.flatMap { $0.isEmpty ? nil : " (in \($0))" } ?? ""
        return "\(format(symbol.location, root: root))  \(symbol.name) [\(kind)]\(container)"
    }

    static func format(_ location: LSPLocation, root: String) -> String {
        let start = location.range.start
        return "\(shorten(location.uri, root: root)):\(start.line + 1):\(start.character + 1)"
    }

    /// A human-friendly short path for a `file://` URI: project files relative to
    /// `root` (`Sources/LSPKit/LSPClient.swift`); dependency files as
    /// `<package>/…` by stripping the SwiftPM `…/checkouts/` prefix
    /// (`swift-nio/Sources/NIO/…`). Anything else is left absolute.
    static func shorten(_ uri: String, root: String) -> String {
        let path = LSPURI.path(uri) ?? uri
        if let checkouts = path.range(of: "/checkouts/") {
            return String(path[checkouts.upperBound...])
        }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Emit any encodable result as pretty JSON, with `file://` slashes unescaped
    /// and keys sorted for stable, diff-friendly output. Goes to stdout so it pipes
    /// cleanly (the progress bar stays on stderr).
    static func printJSON<Value: Encodable>(_ value: Value) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
            print(text)
        } else {
            print("[]")
        }
    }

    static func absolute(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).isAbsolutePath
            ? expanded
            : FileManager.default.currentDirectoryPath + "/" + expanded
    }

    static func usageError(_ form: String) -> Error {
        NSError(domain: "lsp", code: 2, userInfo: [NSLocalizedDescriptionKey: "usage: lsp \(form)"])
    }

    static func printUsage() {
        print("""
        lsp — interrogate a project through sourcekit-lsp (LSPKit / JSONFoundation).

        Usage:
          lsp where <query> [project-dir] [opts]   find symbols by name across the project
          lsp decl <query> [project-dir] [opts]    a symbol's declaration (signature; +doc with --full)
          lsp check <file.swift> [--json]          report syntax/semantic errors in a file (LSP diagnostics)
          lsp symbols <file.swift>                 list the file's document symbols
          lsp hover <file.swift> <line> <col>      hover text at a 0-based line:column
          lsp definition <file.swift> <line> <col> jump-to-definition target(s)
          lsp capabilities <file-or-dir>           print the server's capabilities

        Options for where/decl:
          --exact                            only symbols whose name is exactly <query>
          --scope project|dependencies|all   which sources to search (default: project)
          --json                             emit the full result as JSON
          --full                             (decl) include the doc comment, not just the signature

        Lines and columns are 0-based; columns are UTF-16 offsets (LSP convention).
        """)
    }
}

/// Renders `sourcekit-lsp`'s background-indexing `$/progress` as a progress bar and
/// tracks when indexing settles, so a query can wait for a real signal instead of a
/// guessed timeout.
///
/// `sourcekit-lsp` runs several progress tokens at once (indexing, package
/// reloading, …); this watches only the one whose `.begin` is titled "Indexing".
/// The bar is drawn on **stderr**, and **only when stderr is a TTY** — piped output
/// (and the eventual MCP server / an LLM consumer) stays free of `\r` redraw noise
/// while results flow cleanly on stdout. State is guarded by a lock because the
/// progress handler is a synchronous `@Sendable` callback invoked off the client.
final class IndexingMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var indexingToken: String?
    private var barShown = false
    private let isTTY = isatty(STDERR_FILENO) != 0
    private let barWidth = 24

    /// Feed a `$/progress` notification. Safe to call from the client's handler.
    func handle(_ progress: LSPProgress) {
        lock.lock(); defer { lock.unlock() }
        switch progress.stage {
        case .begin where progress.title?.hasPrefix("Indexing") == true:
            indexingToken = progress.token
            render(progress)
        case .report where progress.token == indexingToken:
            render(progress)
        case .end where progress.token == indexingToken:
            clearLine()
        default:
            break // other tokens (package reload, …) and pre-begin reports: ignore.
        }
    }

    /// Erase the bar if one is still on screen — called once `pollIndex` reports the
    /// index is ready, in case the last `$/progress` `.end` was coalesced or missed.
    func finish() {
        lock.lock(); defer { lock.unlock() }
        clearLine()
    }

    // MARK: - Rendering (called under `lock`)

    private func render(_ progress: LSPProgress) {
        guard isTTY else { return }
        let counted = Self.percent(fromMessage: progress.message)
        let percent = progress.percentage ?? counted ?? 0
        let clamped = max(0, min(100, percent))
        // Show the bar once the file count is known — a determinate "n / m" message —
        // even at 0%; skip only the indeterminate "Determining files" lead-in, which
        // carries no count.
        guard counted != nil || clamped > 0 else { return }
        let filled = barWidth * clamped / 100
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: barWidth - filled)
        let detail = progress.message.map { "  \($0)" } ?? ""
        write("\rIndexing [\(bar)] \(clamped)%\(detail)\u{1B}[K")
        barShown = true
    }

    private func clearLine() {
        guard isTTY, barShown else { return }
        write("\r\u{1B}[K")
        barShown = false
    }

    private func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    /// Parse a `"30 / 48"`-style count into a 0–100 percentage (the server sends
    /// this even when the explicit `percentage` field is absent).
    private static func percent(fromMessage message: String?) -> Int? {
        guard let message else { return nil }
        let parts = message.split(separator: "/")
        guard parts.count == 2,
              let done = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let total = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              total > 0 else { return nil }
        return done * 100 / total
    }
}

/// Which symbols a search should surface — the CLI analogue of Xcode's
/// Find scope (Project / Package Dependencies / both). A symbol's `file://`
/// location decides: dependency sources live under SwiftPM's `…/checkouts/`
/// (inside `.build`), project sources do not.
enum SymbolScope {
    case project       // the project's own sources (default)
    case dependencies  // only package-dependency sources
    case all           // both

    init?(flag: String) {
        switch flag.lowercased() {
        case "project", "proj":              self = .project
        case "deps", "dependencies", "dep":  self = .dependencies
        case "all", "both":                  self = .all
        default:                             return nil
        }
    }

    func includes(uri: String) -> Bool {
        let path = LSPURI.path(uri) ?? ""
        let isDependency = path.contains("/checkouts/")
        switch self {
        case .project:      return !path.contains("/.build/")
        case .dependencies: return isDependency
        case .all:          return true
        }
    }
}

/// Parsed arguments shared by `where` and `decl`: the query, the project root, and
/// the `--scope` / `--json` / `--full` flags. Positionals are `<query>` then an
/// optional `[project-dir]` (default `.`); flags may appear anywhere.
struct SearchOptions {
    var query: String
    var root: String
    var scope: SymbolScope = .project
    var json = false
    var full = false
    var exact = false

    init(parsing arguments: [String], verb: String) throws {
        var positionals: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json": json = true
            case "--full": full = true
            case "--exact": exact = true
            case "--scope":
                index += 1
                guard index < arguments.count, let parsed = SymbolScope(flag: arguments[index]) else {
                    throw LSPCommand.usageError("\(verb) … --scope project|dependencies|all")
                }
                scope = parsed
            default:
                if let value = argument.dropPrefix("--scope=") {
                    guard let parsed = SymbolScope(flag: value) else {
                        throw LSPCommand.usageError("\(verb) … --scope project|dependencies|all")
                    }
                    scope = parsed
                } else if argument.hasPrefix("--") {
                    throw LSPCommand.usageError("\(verb): unknown option \(argument)")
                } else {
                    positionals.append(argument)
                }
            }
            index += 1
        }
        guard let query = positionals.first, !query.isEmpty else {
            throw LSPCommand.usageError("\(verb) <query> [project-dir] [--scope …] [--json]")
        }
        self.query = query
        let target = positionals.count >= 2 ? positionals[1] : "."
        // `standardizingPath` resolves the `.`/`..` that `absolute(".")` leaves in,
        // so the root is a clean prefix for shortening file paths against.
        let resolved = enclosingProjectRoot(for: LSPCommand.absolute(target))
        self.root = (resolved as NSString).standardizingPath
    }
}

/// A `where --json` record. `kind` is the typed ``LSPSymbolKind``, which serializes
/// as its name (`"class"`) rather than the raw LSP integer.
struct SymbolResult: Encodable {
    var name: String
    var kind: LSPSymbolKind?
    var containerName: String?
    var location: LSPLocation

    init(_ symbol: LSPSymbolInformation) {
        self.name = symbol.name
        self.kind = symbol.symbolKind
        self.containerName = symbol.containerName
        self.location = symbol.location
    }
}

/// A `decl --json` record: the symbol (see ``SymbolResult``) plus its resolved
/// declaration text.
struct DeclarationResult: Encodable {
    var name: String
    var kind: LSPSymbolKind?
    var containerName: String?
    var location: LSPLocation
    var signature: String?
    var documentation: String?
}

/// A `check --json` record — one diagnostic, with severity as a name and 1-based
/// line/column for easy reading.
struct DiagnosticResult: Encodable {
    var severity: String
    var path: String
    var line: Int
    var character: Int
    var message: String

    init(_ diagnostic: LSPDiagnostic, root: String, uri: String) {
        self.severity = LSPCommand.severityLabel(diagnostic.severity)
        self.path = LSPCommand.shorten(uri, root: root)
        self.line = diagnostic.range.start.line + 1
        self.character = diagnostic.range.start.character + 1
        self.message = diagnostic.message
    }
}

/// Collects pushed `publishDiagnostics` for one file. sourcekit-lsp uses **push**
/// diagnostics (it has no advertised pull provider), so there's no request whose
/// response is "the diagnostics" — they arrive as notifications after type-checking.
/// This captures the latest set for the target and lets a caller await the first
/// publish (event-driven, with a fallback so a silent server can't hang us). Matches
/// by filesystem path, since the server's URI may differ in encoding from ours.
final class DiagnosticsCollector: @unchecked Sendable {
    let targetURI: String
    private let targetPath: String
    private let lock = NSLock()
    private var latest: [LSPDiagnostic] = []
    private var published = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var resumed = false

    init(targetPath: String) {
        self.targetPath = targetPath
        self.targetURI = LSPURI.file(targetPath)
    }

    var diagnostics: [LSPDiagnostic] {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    /// Feed a `publishDiagnostics` notification. Safe to call from the client handler.
    func record(uri: String, diagnostics: [LSPDiagnostic]) {
        guard LSPURI.path(uri) == targetPath else { return }
        lock.lock()
        latest = diagnostics
        published = true
        let continuation = takeWaiterLocked()
        lock.unlock()
        continuation?.resume()
    }

    /// Resolve once the target's diagnostics have been published — or after the
    /// fallback, so a server that never publishes (e.g. a clean file it stays silent
    /// on) can't block us forever. (The `withCheckedContinuation` body is a synchronous
    /// closure, so the lock is only ever taken from non-async contexts.)
    func waitForFirstPublish(fallbackMilliseconds: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard installWaiter(continuation) else {
                continuation.resume() // already published before we got here
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(fallbackMilliseconds) * 1_000_000)
                self?.fireFallback()
            }
        }
    }

    /// Store the waiter, or report that the publish already happened. Returns `true`
    /// when the caller should wait, `false` when it should resume immediately.
    private func installWaiter(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if published { return false }
        waiter = continuation
        return true
    }

    private func fireFallback() {
        lock.lock()
        let pending = takeWaiterLocked()
        lock.unlock()
        pending?.resume()
    }

    /// Hand out the pending continuation exactly once (whoever calls first — a publish
    /// or the fallback timer — wins).
    private func takeWaiterLocked() -> CheckedContinuation<Void, Never>? {
        guard !resumed, let pending = waiter else { return nil }
        resumed = true
        waiter = nil
        return pending
    }
}

private extension String {
    /// The remainder after `prefix`, or `nil` if `self` doesn't start with it.
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
