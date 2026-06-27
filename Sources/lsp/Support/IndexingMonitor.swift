import Foundation
import LSPKit

/// Renders `sourcekit-lsp`'s background-indexing `$/progress` as a progress bar.
///
/// `sourcekit-lsp` runs several progress tokens at once (indexing, package
/// reloading, …); this watches only the one whose `.begin` is titled "Indexing".
/// The bar is drawn on **stderr**, and **only when stderr is a TTY** — piped output
/// stays free of `\r` redraw noise while results flow cleanly on stdout. State is
/// guarded by a lock because the progress handler is a synchronous `@Sendable`
/// callback invoked off the client.
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

    /// Erase the bar if one is still on screen — called once `waitForIndex` reports the
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
