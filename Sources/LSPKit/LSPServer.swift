import Foundation
import JSONRPCWire

/// How to launch a language server and a couple of path/URI conveniences for
/// driving it. The launch itself is JSONFoundation's transport-agnostic
/// ``ProcessLaunch`` — the same descriptor SwiftACP uses to spawn an ACP agent —
/// so swapping `sourcekit-lsp` for `clangd`/`pyright` is just a different command.
public enum LSPServer {
    /// `sourcekit-lsp`, launched via `xcrun` so it resolves against the active
    /// Xcode toolchain. Its logs (stderr) are discarded to keep stdout pure
    /// JSON-RPC — the same discipline `probe.py` follows.
    public static func sourceKit(inheritStderr: Bool = false) -> ProcessLaunch {
        ProcessLaunch(
            executable: "xcrun",
            arguments: ["sourcekit-lsp"],
            inheritStderr: inheritStderr)
    }

    /// An arbitrary server command (e.g. `clangd`, `pyright-langserver --stdio`).
    public static func command(
        _ executable: String, _ arguments: [String] = [], inheritStderr: Bool = false
    ) -> ProcessLaunch {
        ProcessLaunch(executable: executable, arguments: arguments, inheritStderr: inheritStderr)
    }
}

public enum LSPURI {
    /// A `file://` URI for a filesystem path, percent-encoding as needed. The path
    /// is resolved to absolute first (LSP requires absolute `file://` URIs).
    public static func file(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).absoluteString
    }

    /// The filesystem path behind a `file://` URI, or `nil` if it isn't one.
    public static func path(_ uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path
    }
}

/// Maps a file extension to the LSP `languageId` a server expects in `didOpen`.
/// Defaults to `swift` — the POC's focus — for unknown extensions.
public func lspLanguageId(forPath path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "swift": return "swift"
    case "m": return "objective-c"
    case "mm": return "objective-cpp"
    case "h", "hpp", "hh": return "cpp"
    case "c": return "c"
    case "cpp", "cc", "cxx": return "cpp"
    case "py": return "python"
    default: return "swift"
    }
}

/// Walks up from `path` to the nearest directory containing `Package.swift`
/// (a Swift package root), falling back to the file's own directory. Used as the
/// `rootUri` for `initialize` so `sourcekit-lsp` indexes the right project.
public func enclosingProjectRoot(for path: String) -> String {
    let absolute = (path as NSString).expandingTildeInPath
    var directory = (absolute as NSString).isDirectory
        ? absolute
        : (absolute as NSString).deletingLastPathComponent
    let fileManager = FileManager.default
    while directory != "/" && !directory.isEmpty {
        if fileManager.fileExists(atPath: (directory as NSString).appendingPathComponent("Package.swift")) {
            return directory
        }
        directory = (directory as NSString).deletingLastPathComponent
    }
    return (absolute as NSString).deletingLastPathComponent
}

private extension NSString {
    var isDirectory: Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: self as String, isDirectory: &isDir)
        return isDir.boolValue
    }
}
