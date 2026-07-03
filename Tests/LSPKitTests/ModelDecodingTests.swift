import Foundation
import JSONFoundation
import Testing
@testable import LSPKit

// The custom decoders that tolerate the wire's alternative shapes — progress
// tokens that are strings *or* numbers, WorkspaceSymbol locations without a
// range, LocationLink answers, and SymbolKind's int-in/name-out Codable.

@Suite struct ModelDecodingTests {
    // MARK: - $/progress

    @Test func progressDecodesStringAndNumberTokens() throws {
        let stringToken = try decodeProgress(
            #"{"token": "idx", "value": {"kind": "begin", "title": "Indexing"}}"#)
        #expect(stringToken.token == "idx")
        #expect(stringToken.stage == .begin)
        #expect(stringToken.title == "Indexing")

        let numberToken = try decodeProgress(
            #"{"token": 7, "value": {"kind": "report", "message": "3/42", "percentage": 7}}"#)
        #expect(numberToken.token == "7")
        #expect(numberToken.stage == .report)
        #expect(numberToken.message == "3/42")
        #expect(numberToken.percentage == 7)
    }

    @Test func progressRejectsUnknownKind() {
        #expect(throws: DecodingError.self) {
            _ = try decodeProgress(#"{"token": "idx", "value": {"kind": "pause"}}"#)
        }
    }

    // MARK: - workspace/symbol tolerant location

    @Test func symbolInformationToleratesRangelessLocation() throws {
        let json = #"{"name": "Widget", "kind": 23, "location": {"uri": "file:///a.swift"}}"#
        let symbol = try JSONDecoder().decode(LSPSymbolInformation.self, from: Data(json.utf8))
        #expect(symbol.location.uri == "file:///a.swift")
        #expect(symbol.location.range.start == LSPPosition(line: 0, character: 0))
        #expect(symbol.symbolKind == .struct)
    }

    // MARK: - definition/references normalization

    @Test func locationsNormalizeAllFourAnswerShapes() throws {
        let range = #"{"start": {"line": 1, "character": 2}, "end": {"line": 1, "character": 8}}"#
        let single = try parse(#"{"uri": "file:///a.swift", "range": \#(range)}"#)
        #expect(LSPClient.locations(from: single).map(\.uri) == ["file:///a.swift"])

        let array = try parse(#"[{"uri": "file:///a.swift", "range": \#(range)}]"#)
        #expect(LSPClient.locations(from: array).count == 1)

        // LocationLink: the selection range wins over the full target range.
        let links = try parse("""
        [{"targetUri": "file:///b.swift",
          "targetRange": {"start": {"line": 0, "character": 0}, "end": {"line": 9, "character": 1}},
          "targetSelectionRange": \(range)}]
        """)
        let normalized = LSPClient.locations(from: links)
        #expect(normalized.map(\.uri) == ["file:///b.swift"])
        #expect(normalized.first?.range.start == LSPPosition(line: 1, character: 2))

        #expect(LSPClient.locations(from: .null).isEmpty)
    }

    // MARK: - SymbolKind Codable

    @Test func symbolKindDecodesFromIntegerOrName() throws {
        #expect(try decodeKind("5") == .class)
        #expect(try decodeKind(#""class""#) == .class)
        #expect(try decodeKind(#""enumMember""#) == .enumMember)
        #expect(throws: DecodingError.self) { _ = try decodeKind("99") }
        #expect(throws: DecodingError.self) { _ = try decodeKind(#""gadget""#) }
    }

    @Test func symbolKindEncodesAsName() throws {
        let data = try JSONEncoder().encode(LSPSymbolKind.typeParameter)
        #expect(String(decoding: data, as: UTF8.self) == #""typeParameter""#)
    }

    // MARK: - Helpers

    private func decodeProgress(_ json: String) throws -> LSPProgress {
        try JSONDecoder().decode(LSPProgress.self, from: Data(json.utf8))
    }

    private func decodeKind(_ json: String) throws -> LSPSymbolKind {
        try JSONDecoder().decode(LSPSymbolKind.self, from: Data(json.utf8))
    }

    private func parse(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }
}
