import Foundation

// Small, server-agnostic helpers shared by the `lsp` CLI and the `lsp-mcp` server:
// narrowing fuzzy `workspace/symbol` results, exact-name matching, and pulling a
// declaration signature out of hover markdown.

/// Which symbols a search should surface — the analogue of Xcode's Find scope
/// (Project / Package Dependencies / both). A symbol's `file://` location decides:
/// dependency sources live under SwiftPM's `…/checkouts/` (inside `.build`),
/// project sources do not.
public enum LSPSymbolScope: String, Sendable, CaseIterable {
    case project
    case dependencies
    case all

    /// Parse a user-facing flag value (`project`/`deps`/`all`, with a few aliases).
    public init?(flag: String) {
        switch flag.lowercased() {
        case "project", "proj":             self = .project
        case "deps", "dependencies", "dep": self = .dependencies
        case "all", "both":                 self = .all
        default:                            return nil
        }
    }

    /// Whether a symbol at `uri` falls in this scope.
    public func includes(uri: String) -> Bool {
        let path = LSPURI.path(uri) ?? ""
        switch self {
        case .project:      return !path.contains("/.build/")
        case .dependencies: return path.contains("/checkouts/")
        case .all:          return true
        }
    }
}

/// The identifier portion of a symbol name, dropping any `(argument:labels:)`
/// suffix — so `MCPTool(name:description:)` and the type `MCPTool` both reduce to
/// `MCPTool` for exact comparison.
public func lspBaseName(of name: String) -> String {
    guard let paren = name.firstIndex(of: "(") else { return name }
    return String(name[..<paren])
}

/// Filter fuzzy `workspace/symbol` results: drop compiler-synthesized symbols
/// (mangled `$s…` names from macro expansions), apply `scope`, and — when `exact` —
/// keep only those whose base name equals `query`.
public func lspFilterSymbols(
    _ symbols: [LSPSymbolInformation], query: String, scope: LSPSymbolScope, exact: Bool
) -> [LSPSymbolInformation] {
    symbols.filter { symbol in
        guard !symbol.name.hasPrefix("$"), scope.includes(uri: symbol.location.uri) else {
            return false
        }
        return exact ? lspBaseName(of: symbol.name) == query : true
    }
}

/// Pull the first fenced code block — the declaration signature — out of hover
/// markdown. Falls back to the whole (trimmed) text when there's no fence.
public func lspSignature(fromHoverMarkdown markdown: String) -> String {
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
