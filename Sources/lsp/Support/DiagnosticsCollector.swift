import Foundation
import LSPKit

/// Collects pushed `publishDiagnostics` for one file. sourcekit-lsp uses **push**
/// diagnostics (no advertised pull provider), so there's no request whose response is
/// "the diagnostics" — they arrive as notifications after type-checking. This captures
/// the latest set for the target and lets a caller await the first publish
/// (event-driven, with a fallback so a silent server can't hang us). Matches by
/// filesystem path, since the server's URI may differ in encoding from ours.
final class DiagnosticsCollector: @unchecked Sendable {
    let targetURI: String
    private let targetPath: String
    private let lock = NSLock()
    private var latest: [LSPDiagnostic] = []
    private var published = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var resumed = false

    init(targetPath: String) {
        self.targetPath = targetPath
        self.targetURI = LSPURI.file(targetPath)
    }

    var diagnostics: [LSPDiagnostic] {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    /// Feed a `publishDiagnostics` notification. Safe to call from the client handler.
    func record(uri: String, diagnostics: [LSPDiagnostic]) {
        guard LSPURI.path(uri) == targetPath else { return }
        lock.lock()
        latest = diagnostics
        published = true
        let continuation = takeWaiterLocked()
        lock.unlock()
        continuation?.resume()
    }

    /// Resolve once the target's diagnostics have been published — or after the
    /// fallback, so a server that never publishes (e.g. a clean file it stays silent
    /// on) can't block us forever. (The `withCheckedContinuation` body is a synchronous
    /// closure, so the lock is only ever taken from non-async contexts.)
    func waitForFirstPublish(fallbackMilliseconds: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard installWaiter(continuation) else {
                continuation.resume() // already published before we got here
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(fallbackMilliseconds) * 1_000_000)
                self?.fireFallback()
            }
        }
    }

    /// Store the waiter, or report that the publish already happened. Returns `true`
    /// when the caller should wait, `false` when it should resume immediately.
    private func installWaiter(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if published { return false }
        waiter = continuation
        return true
    }

    private func fireFallback() {
        lock.lock()
        let pending = takeWaiterLocked()
        lock.unlock()
        pending?.resume()
    }

    /// Hand out the pending continuation exactly once (whoever calls first — a publish
    /// or the fallback timer — wins).
    private func takeWaiterLocked() -> CheckedContinuation<Void, Never>? {
        guard !resumed, let pending = waiter else { return nil }
        resumed = true
        waiter = nil
        return pending
    }
}
