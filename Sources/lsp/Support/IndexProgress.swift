import Foundation
import LSPKit

/// Translates `sourcekit-lsp`'s background-indexing `$/progress` stream into a
/// `(stage, percent, message)` to report, tracking the "Indexing" token across
/// its `begin` → `report`* → `end` sequence.
///
/// Two consumers share it: the `lsp` CLI's `IndexingMonitor` renders the signal as
/// a stderr bar; the MCP server bridges it to a caller's progress token. One state
/// object follows one indexing run — the MCP server makes a fresh one per request.
final class IndexProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var indexingToken: String?

    /// Map one `$/progress` event to the stage and progress to report, or `nil` to
    /// skip it (non-indexing tokens, or reports that precede the `begin`).
    func update(_ progress: LSPProgress) -> (stage: LSPProgress.Stage, percent: Int, message: String?)? {
        lock.lock(); defer { lock.unlock() }
        switch progress.stage {
        case .begin where progress.title?.hasPrefix("Indexing") == true:
            indexingToken = progress.token
            return (.begin, percent(of: progress), progress.message)
        case .report where progress.token == indexingToken:
            return (.report, percent(of: progress), progress.message)
        case .end where progress.token == indexingToken:
            indexingToken = nil
            return (.end, 100, progress.message)
        default:
            return nil // other tokens (package reload, …) and pre-begin reports.
        }
    }

    private func percent(of progress: LSPProgress) -> Int {
        let value = progress.percentage ?? Self.percent(fromMessage: progress.message) ?? 0
        return max(0, min(100, value))
    }

    /// Parse a `"30 / 48"`-style message into a 0–100 percentage — `sourcekit-lsp`
    /// sends this even when the explicit `percentage` field is absent.
    static func percent(fromMessage message: String?) -> Int? {
        guard let message else { return nil }
        let parts = message.split(separator: "/")
        guard parts.count == 2,
              let done = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let total = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              total > 0 else { return nil }
        return done * 100 / total
    }
}
