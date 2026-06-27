/// The LSP `SymbolKind` enumeration (spec 3.17, §`SymbolKind`). On the wire these
/// are bare integers (a `class` is `5`, a `function` is `12`); this maps them to
/// names for display.
public enum LSPSymbolKind: Int, Sendable, CaseIterable {
    case file = 1
    case module = 2
    case namespace = 3
    case package = 4
    case `class` = 5
    case method = 6
    case property = 7
    case field = 8
    case constructor = 9
    case `enum` = 10
    case interface = 11
    case function = 12
    case variable = 13
    case constant = 14
    case string = 15
    case number = 16
    case boolean = 17
    case array = 18
    case object = 19
    case key = 20
    case null = 21
    case enumMember = 22
    case `struct` = 23
    case event = 24
    case `operator` = 25
    case typeParameter = 26

    /// Look up a kind by its ``displayName`` (case-insensitive), e.g. `"class"`,
    /// `"enumMember"`. `nil` for an unknown name — useful for parsing a `--kind`
    /// filter from the command line.
    public init?(name: String) {
        let needle = name.lowercased()
        guard let match = Self.allCases.first(where: { $0.displayName.lowercased() == needle }) else {
            return nil
        }
        self = match
    }

    /// A lower-camelCase label for the kind (`enumMember`, `typeParameter`, …).
    public var displayName: String {
        switch self {
        case .file: return "file"
        case .module: return "module"
        case .namespace: return "namespace"
        case .package: return "package"
        case .class: return "class"
        case .method: return "method"
        case .property: return "property"
        case .field: return "field"
        case .constructor: return "constructor"
        case .enum: return "enum"
        case .interface: return "interface"
        case .function: return "function"
        case .variable: return "variable"
        case .constant: return "constant"
        case .string: return "string"
        case .number: return "number"
        case .boolean: return "boolean"
        case .array: return "array"
        case .object: return "object"
        case .key: return "key"
        case .null: return "null"
        case .enumMember: return "enumMember"
        case .struct: return "struct"
        case .event: return "event"
        case .operator: return "operator"
        case .typeParameter: return "typeParameter"
        }
    }
}
