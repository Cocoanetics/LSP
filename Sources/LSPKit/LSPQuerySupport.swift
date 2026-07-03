import Foundation

// Small, server-agnostic helpers shared by the `lsp` CLI and the `lsp mcp` server:
// narrowing fuzzy `workspace/symbol` results, exact-name matching, and pulling a
// declaration signature (or its documentation) out of hover markdown.

/// Which symbols a search should surface — the analogue of Xcode's Find scope
/// (Project / Package Dependencies / both). A symbol's `file://` location decides:
/// dependency sources live under SwiftPM's `…/checkouts/` (inside `.build`),
/// project sources do not.
public enum LSPSymbolScope: String, Sendable, CaseIterable {
    case project
    case dependencies
    case all

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

/// The counterpart of ``lspSignature(fromHoverMarkdown:)``: everything *after* the
/// first fenced code block — the doc-comment prose — or `nil` when the hover is
/// signature-only. (sourcekit-lsp renders hovers as the fenced signature followed
/// by the documentation; any prose before the first fence is not preserved.)
public func lspDocumentation(fromHoverMarkdown markdown: String) -> String? {
    var inFirstFence = false
    var passedFirstFence = false
    var collected: [Substring] = []
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
        if passedFirstFence {
            collected.append(line)
        } else if line.hasPrefix("```") {
            if inFirstFence { passedFirstFence = true } else { inFirstFence = true }
        }
    }
    let text = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}
