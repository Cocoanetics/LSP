import Foundation
import LSPKit

/// Renders `sourcekit-lsp`'s background-indexing `$/progress` as a progress bar.
///
/// The "which token is the indexing run" tracking and the percent math live in
/// `IndexProgressState` (shared with the MCP server's progress bridging); this
/// adds only the drawing. The bar is drawn on **stderr**, and **only when stderr
/// is a TTY** — piped output stays free of `\r` redraw noise while results flow
/// cleanly on stdout. State is guarded by a lock because the progress handler is
/// a synchronous `@Sendable` callback invoked off the client.
final class IndexingMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let state = IndexProgressState()
    private var barShown = false
    private let isTTY = isatty(STDERR_FILENO) != 0
    private let barWidth = 24

    /// Feed a `$/progress` notification. Safe to call from the client's handler.
    func handle(_ progress: LSPProgress) {
        guard let update = state.update(progress) else { return }
        lock.lock(); defer { lock.unlock() }
        switch update.stage {
        case .begin, .report:
            render(percent: update.percent, message: update.message)
        case .end:
            clearLine()
        }
    }

    /// Erase the bar if one is still on screen — called once `waitForIndex` reports the
    /// index is ready, in case the last `$/progress` `.end` was coalesced or missed.
    func finish() {
        lock.lock(); defer { lock.unlock() }
        clearLine()
    }

    // MARK: - Rendering (called under `lock`)

    private func render(percent: Int, message: String?) {
        guard isTTY else { return }
        // Show the bar once the file count is known — a determinate "n / m" message —
        // even at 0%; skip only the indeterminate "Determining files" lead-in, which
        // carries no count.
        let counted = IndexProgressState.percent(fromMessage: message)
        guard counted != nil || percent > 0 else { return }
        let filled = barWidth * percent / 100
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: barWidth - filled)
        let detail = message.map { "  \($0)" } ?? ""
        write("\rIndexing [\(bar)] \(percent)%\(detail)\u{1B}[K")
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
}
