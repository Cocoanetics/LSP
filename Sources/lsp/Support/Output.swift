import Foundation
import LSPKit

// Human-text rendering and the `--json` record shapes shared by the commands.

/// Print a `documentSymbol` tree, indented by depth.
func printSymbol(_ symbol: LSPDocumentSymbol, indent: Int) {
    let pad = String(repeating: "  ", count: indent)
    let kind = symbol.symbolKind?.displayName ?? "kind \(symbol.kind)"
    let detail = symbol.detail.map { " — \($0)" } ?? ""
    print("\(pad)\(symbol.name) [\(kind)]\(detail)")
    for child in symbol.children ?? [] { printSymbol(child, indent: indent + 1) }
}

/// `path:line:col  name [kind] (in Container)` for a workspace-symbol hit.
func formatSymbol(_ symbol: LSPSymbolInformation, root: String) -> String {
    let kind = symbol.symbolKind?.displayName ?? "kind \(symbol.kind)"
    let container = symbol.containerName.flatMap { $0.isEmpty ? nil : " (in \($0))" } ?? ""
    return "\(formatLocation(symbol.location, root: root))  \(symbol.name) [\(kind)]\(container)"
}

/// `path:line:col` for a location, with a shortened, 1-based display.
func formatLocation(_ location: LSPLocation, root: String) -> String {
    let start = location.range.start
    return "\(shorten(location.uri, root: root)):\(start.line + 1):\(start.character + 1)"
}

func formatDiagnostic(_ diagnostic: LSPDiagnostic, root: String, uri: String) -> String {
    let start = diagnostic.range.start
    return "\(shorten(uri, root: root)):\(start.line + 1):\(start.character + 1): "
        + "\(severityName(diagnostic.severity)): \(diagnostic.message)"
}

/// LSP `DiagnosticSeverity`: 1 = error, 2 = warning, 3 = information, 4 = hint.
/// (An unspecified severity is treated as an error by the spec.)
func severityName(_ severity: Int?) -> String {
    switch severity {
    case 2: return "warning"
    case 3: return "information"
    case 4: return "hint"
    default: return "error"
    }
}

/// Count errors and warnings in one pass — the tally both `lsp check` and the
/// `check_file` MCP tool report.
func diagnosticTally(_ diagnostics: [LSPDiagnostic]) -> (errors: Int, warnings: Int) {
    diagnostics.reduce(into: (errors: 0, warnings: 0)) { tally, diagnostic in
        switch severityName(diagnostic.severity) {
        case "error":   tally.errors += 1
        case "warning": tally.warnings += 1
        default:        break
        }
    }
}

/// A human-friendly short path for a `file://` URI: project files relative to `root`
/// (`Sources/LSPKit/LSPClient.swift`); dependency files as `<package>/…` by stripping
/// the SwiftPM `…/checkouts/` prefix (`swift-nio/Sources/NIO/…`). Else left absolute.
func shorten(_ uri: String, root: String) -> String {
    let path = LSPURI.path(uri) ?? uri
    if let checkouts = path.range(of: "/checkouts/") {
        return String(path[checkouts.upperBound...])
    }
    let prefix = root.hasSuffix("/") ? root : root + "/"
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
}

/// Emit any encodable result as pretty JSON — slashes unescaped, keys sorted for
/// stable output. Goes to stdout so it pipes cleanly (the progress bar stays on stderr).
func printJSON<Value: Encodable>(_ value: Value) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    } catch {
        // Should be unreachable for our plain value types — but if it happens,
        // say so on stderr instead of silently emitting a wrong result.
        FileHandle.standardError.write(Data("json encoding failed: \(error)\n".utf8))
        print("[]")
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

/// A `decl --json` record: the symbol plus its resolved declaration text.
struct DeclarationResult: Encodable {
    var name: String
    var kind: LSPSymbolKind?
    var containerName: String?
    var location: LSPLocation
    var signature: String?
    var documentation: String?
}

/// A `check --json` record — one diagnostic, severity as a name, 1-based position.
struct DiagnosticResult: Encodable {
    var severity: String
    var path: String
    var line: Int
    var character: Int
    var message: String

    init(_ diagnostic: LSPDiagnostic, root: String, uri: String) {
        self.severity = severityName(diagnostic.severity)
        self.path = shorten(uri, root: root)
        self.line = diagnostic.range.start.line + 1
        self.character = diagnostic.range.start.character + 1
        self.message = diagnostic.message
    }
}
