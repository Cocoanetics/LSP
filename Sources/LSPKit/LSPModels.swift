import Foundation

// The slice of the LSP 3.17 type system LSPKit speaks: positions/ranges, the
// lifecycle `initialize` result, and the payloads of the interrogation methods
// (`documentSymbol`, `hover`, `definition`, `references`). They are plain
// `Codable` value types; the wire (de)serialization is JSONFoundation's
// `JSONValue` round-trip (see `LSPClient`).
//
// Naming note: every type is `LSP`-prefixed so `LSPRange`/`LSPLocation` don't
// collide with `Swift.Range` and friends at call sites.

/// A 0-based `{ line, character }` position. `character` is a **UTF-16** code-unit
/// offset into the line, *not* a byte or grapheme offset — the one subtlety that
/// makes hovers land on the right token.
public struct LSPPosition: Codable, Sendable, Hashable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

/// A half-open `[start, end)` range of positions.
public struct LSPRange: Codable, Sendable, Hashable {
    public var start: LSPPosition
    public var end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}

/// A location inside a document: a `file://` URI and a range within it.
public struct LSPLocation: Codable, Sendable, Hashable {
    public var uri: String
    public var range: LSPRange

    public init(uri: String, range: LSPRange) {
        self.uri = uri
        self.range = range
    }
}

/// A `textDocument/definition` link (`LocationLink`). Servers may answer
/// `definition`/`references` with either plain ``LSPLocation`` values or these
/// richer links; ``LSPClient`` normalizes both to ``LSPLocation``.
struct LSPLocationLink: Codable, Sendable {
    var targetUri: String
    var targetRange: LSPRange
    var targetSelectionRange: LSPRange?

    var asLocation: LSPLocation {
        LSPLocation(uri: targetUri, range: targetSelectionRange ?? targetRange)
    }
}

/// One node of `textDocument/documentSymbol`'s hierarchical result. `kind` is the
/// raw LSP integer; ``symbolKind`` decodes it to ``LSPSymbolKind``.
public struct LSPDocumentSymbol: Codable, Sendable {
    public var name: String
    public var detail: String?
    public var kind: Int
    /// The whole declaration, body and doc comment included — what an editor folds.
    public var range: LSPRange
    /// Just the symbol's name token, always contained in ``range`` — the position
    /// to feed `hover`/`definition` so they land on the symbol itself.
    public var selectionRange: LSPRange
    public var children: [LSPDocumentSymbol]?

    /// The typed symbol kind (`.class`, `.function`, …), or `nil` for an
    /// unrecognized integer.
    public var symbolKind: LSPSymbolKind? { LSPSymbolKind(rawValue: kind) }

    public init(
        name: String, detail: String? = nil, kind: Int,
        range: LSPRange, selectionRange: LSPRange, children: [LSPDocumentSymbol]? = nil
    ) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.range = range
        self.selectionRange = selectionRange
        self.children = children
    }
}

/// One match from `workspace/symbol` — the project-wide, index-backed symbol
/// search that turns a *name* into *locations* (the query an agent actually has,
/// versus the `line:character` coordinate `hover`/`definition` demand).
///
/// The wire type is LSP `SymbolInformation` (`{ name, kind, location,
/// containerName? }`). The newer `WorkspaceSymbol` shape — whose `location` may
/// carry only a `uri`, with the range resolved lazily — also decodes here: a
/// missing range folds to a zero range. `sourcekit-lsp` returns full locations.
public struct LSPSymbolInformation: Sendable {
    public var name: String
    /// The raw LSP integer kind; ``symbolKind`` decodes it to ``LSPSymbolKind``.
    public var kind: Int
    public var location: LSPLocation
    /// The enclosing symbol the server reports (a type, extension, or file), when any.
    public var containerName: String?

    /// The typed symbol kind (`.class`, `.function`, …), or `nil` for an
    /// unrecognized integer.
    public var symbolKind: LSPSymbolKind? { LSPSymbolKind(rawValue: kind) }

    public init(name: String, kind: Int, location: LSPLocation, containerName: String? = nil) {
        self.name = name
        self.kind = kind
        self.location = location
        self.containerName = containerName
    }
}

extension LSPSymbolInformation: Codable {
    private enum CodingKeys: String, CodingKey { case name, kind, location, containerName }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.kind = try container.decode(Int.self, forKey: .kind)
        self.containerName = try container.decodeIfPresent(String.self, forKey: .containerName)
        // Tolerate the `WorkspaceSymbol` form where `location` is `{ uri }` only.
        let location = try container.decode(TolerantLocation.self, forKey: .location)
        self.location = location.resolved
    }

    /// A `Location` whose `range` may be absent (the lazy `WorkspaceSymbol` shape).
    private struct TolerantLocation: Decodable {
        var uri: String
        var range: LSPRange?

        var resolved: LSPLocation {
            let zero = LSPPosition(line: 0, character: 0)
            return LSPLocation(uri: uri, range: range ?? LSPRange(start: zero, end: zero))
        }
    }
}

/// `textDocument/hover` result, flattened to its display text. The wire `contents`
/// has three legal shapes (a `MarkupContent` object, a marked-string, or an array
/// of marked-strings); the custom decoder folds all three into ``value``.
public struct LSPHover: Sendable {
    /// The hover text (Markdown for `sourcekit-lsp`), already extracted from
    /// whichever `contents` shape the server used.
    public var value: String
    /// The range the hover applies to, when the server reports one.
    public var range: LSPRange?

    public init(value: String, range: LSPRange? = nil) {
        self.value = value
        self.range = range
    }
}

extension LSPHover: Decodable {
    private enum CodingKeys: String, CodingKey { case contents, range }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.range = try container.decodeIfPresent(LSPRange.self, forKey: .range)
        self.value = try Self.flatten(container.decode(MarkedContents.self, forKey: .contents))
    }

    /// `MarkupContent` (`{ kind, value }`), `MarkedString` (a bare string or
    /// `{ language, value }`), or an array of the latter.
    private enum MarkedContents: Decodable {
        case markup(String)
        case string(String)
        case list([MarkedContents])

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let text = try? single.decode(String.self) {
                self = .string(text)
            } else if let list = try? single.decode([MarkedContents].self) {
                self = .list(list)
            } else {
                // Both MarkupContent and the object form of MarkedString carry a
                // `value`; either way the text we want lives there.
                let object = try decoder.container(keyedBy: ObjectKey.self)
                self = .markup(try object.decode(String.self, forKey: .value))
            }
        }

        private enum ObjectKey: String, CodingKey { case value }
    }

    private static func flatten(_ contents: MarkedContents) -> String {
        switch contents {
        case .markup(let text), .string(let text):
            return text
        case .list(let items):
            return items.map(flatten).joined(separator: "\n\n")
        }
    }
}

/// A `$/progress` notification carrying LSP work-done progress. `sourcekit-lsp`
/// streams these for background indexing: one `.begin` (with a `title` like
/// "Indexing"), zero or more `.report` updates (`message` and/or `percentage`),
/// then one `.end`. The `token` ties a sequence together; `value.kind`
/// discriminates the stage.
public struct LSPProgress: Sendable {
    public enum Stage: String, Sendable { case begin, report, end }

    /// The progress token, stringified (the wire allows a string *or* a number).
    public var token: String
    public var stage: Stage
    /// The operation name — present on `.begin` (e.g. "Indexing").
    public var title: String?
    /// A human-readable detail (e.g. "3/42"), when the server sends one.
    public var message: String?
    /// Completion 0–100, when the server reports a determinate amount.
    public var percentage: Int?

    public init(
        token: String, stage: Stage, title: String? = nil,
        message: String? = nil, percentage: Int? = nil
    ) {
        self.token = token
        self.stage = stage
        self.title = title
        self.message = message
        self.percentage = percentage
    }
}

extension LSPProgress: Decodable {
    private enum CodingKeys: String, CodingKey { case token, value }
    private enum ValueKeys: String, CodingKey { case kind, title, message, percentage }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `token`: `ProgressToken` is `string | integer` on the wire.
        if let text = try? container.decode(String.self, forKey: .token) {
            self.token = text
        } else {
            self.token = String(try container.decode(Int.self, forKey: .token))
        }

        let value = try container.nestedContainer(keyedBy: ValueKeys.self, forKey: .value)
        guard let stage = Stage(rawValue: try value.decode(String.self, forKey: .kind)) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: value, debugDescription: "unknown progress kind")
        }
        self.stage = stage
        self.title = try value.decodeIfPresent(String.self, forKey: .title)
        self.message = try value.decodeIfPresent(String.self, forKey: .message)
        self.percentage = try value.decodeIfPresent(Int.self, forKey: .percentage)
    }
}

/// `initialize` result: what the server can do, and who it is.
public struct LSPInitializeResult: Sendable {
    /// The names of the capabilities the server advertised (e.g.
    /// `documentSymbolProvider`, `hoverProvider`), sorted — enough to confirm the
    /// handshake and report what the server can do.
    public var capabilityNames: [String]
    /// The server's self-reported name and version, when provided.
    public var serverName: String?
    public var serverVersion: String?

    public init(capabilityNames: [String], serverName: String? = nil, serverVersion: String? = nil) {
        self.capabilityNames = capabilityNames
        self.serverName = serverName
        self.serverVersion = serverVersion
    }
}

extension LSPInitializeResult: Decodable {
    private enum CodingKeys: String, CodingKey { case capabilities, serverInfo }
    private enum ServerInfoKeys: String, CodingKey { case name, version }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `capabilities` is an open-ended object — we only need its key names, so
        // decode it as a dictionary of ignored values and keep the sorted keys.
        let capabilities = try container.decodeIfPresent(
            [String: IgnoredValue].self, forKey: .capabilities) ?? [:]
        self.capabilityNames = capabilities.keys.sorted()

        if let info = try? container.nestedContainer(keyedBy: ServerInfoKeys.self, forKey: .serverInfo) {
            self.serverName = try info.decodeIfPresent(String.self, forKey: .name)
            self.serverVersion = try info.decodeIfPresent(String.self, forKey: .version)
        }
    }

    /// Decodes and discards any JSON value — lets us read an object's keys without
    /// modeling its (large, server-specific) value shapes.
    private struct IgnoredValue: Decodable {
        init(from decoder: Decoder) throws { _ = try decoder.singleValueContainer() }
    }
}
