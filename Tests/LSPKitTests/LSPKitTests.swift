import Foundation
import Testing
@testable import LSPKit

// Unit coverage for the pure pieces (model decoding, helpers). The live
// sourcekit-lsp round-trip is exercised separately in `LiveSourceKitTests`.

@Test func symbolKindNames() {
    #expect(LSPSymbolKind(rawValue: 10) == .enum)
    #expect(LSPSymbolKind.struct.displayName == "struct")
    #expect(LSPSymbolKind(rawValue: 999) == nil)
}

@Test func decodesHierarchicalDocumentSymbols() throws {
    // The exact shape sourcekit-lsp returns for documentSymbol (hierarchical).
    let json = """
    [{
      "name": "JSONRPCID", "kind": 10,
      "range": {"start": {"line": 2, "character": 0}, "end": {"line": 9, "character": 1}},
      "selectionRange": {"start": {"line": 2, "character": 12}, "end": {"line": 2, "character": 21}},
      "children": [
        {"name": "number", "kind": 22,
         "range": {"start": {"line": 3, "character": 4}, "end": {"line": 3, "character": 18}},
         "selectionRange": {"start": {"line": 3, "character": 9}, "end": {"line": 3, "character": 15}}}
      ]
    }]
    """
    let symbols = try JSONDecoder().decode([LSPDocumentSymbol].self, from: Data(json.utf8))
    #expect(symbols.count == 1)
    #expect(symbols[0].name == "JSONRPCID")
    #expect(symbols[0].symbolKind == .enum)
    #expect(symbols[0].children?.count == 1)
    #expect(symbols[0].children?[0].symbolKind == .enumMember)
}

@Test func decodesHoverFromAllThreeContentShapes() throws {
    // 1) MarkupContent object
    let markup = try decodeHover(#"{"contents": {"kind": "markdown", "value": "**Int**"}}"#)
    #expect(markup.value == "**Int**")

    // 2) bare MarkedString
    let string = try decodeHover(#"{"contents": "plain text"}"#)
    #expect(string.value == "plain text")

    // 3) array of MarkedStrings, joined
    let list = try decodeHover(#"{"contents": ["a", {"language": "swift", "value": "b"}]}"#)
    #expect(list.value == "a\n\nb")
}

@Test func decodesInitializeCapabilityNames() throws {
    let json = #"""
    {"capabilities": {"hoverProvider": true, "definitionProvider": true},
     "serverInfo": {"name": "SourceKit-LSP", "version": "1.0"}}
    """#
    let result = try JSONDecoder().decode(LSPInitializeResult.self, from: Data(json.utf8))
    #expect(result.capabilityNames == ["definitionProvider", "hoverProvider"])
    #expect(result.serverName == "SourceKit-LSP")
}

@Test func languageIdFromExtension() {
    #expect(lspLanguageId(forPath: "Foo.swift") == "swift")
    #expect(lspLanguageId(forPath: "foo.py") == "python")
    #expect(lspLanguageId(forPath: "foo.c") == "c")
}

private func decodeHover(_ json: String) throws -> LSPHover {
    try JSONDecoder().decode(LSPHover.self, from: Data(json.utf8))
}
