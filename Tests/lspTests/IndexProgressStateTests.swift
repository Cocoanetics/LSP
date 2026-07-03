import Testing
@testable import lsp
@testable import LSPKit

// The token state machine both progress consumers (CLI bar, MCP bridging) sit on.

@Suite struct IndexProgressStateTests {
    @Test func followsTheIndexingTokenThroughItsLifecycle() {
        let state = IndexProgressState()

        // Reports before any begin are dropped.
        #expect(state.update(LSPProgress(token: "idx", stage: .report, percentage: 10)) == nil)

        let begin = state.update(LSPProgress(token: "idx", stage: .begin, title: "Indexing", message: "0 / 48"))
        #expect(begin?.stage == .begin)
        #expect(begin?.percent == 0)

        let report = state.update(LSPProgress(token: "idx", stage: .report, message: "24 / 48"))
        #expect(report?.stage == .report)
        #expect(report?.percent == 50) // parsed from the message, no explicit percentage

        // Other tokens (package reload, …) don't leak in.
        #expect(state.update(LSPProgress(token: "reload", stage: .report, percentage: 90)) == nil)
        #expect(state.update(LSPProgress(token: "reload", stage: .begin, title: "Reloading")) == nil)

        let end = state.update(LSPProgress(token: "idx", stage: .end))
        #expect(end?.stage == .end)
        #expect(end?.percent == 100)

        // After the end, the token is forgotten.
        #expect(state.update(LSPProgress(token: "idx", stage: .report, percentage: 10)) == nil)
    }

    @Test func explicitPercentageWinsAndIsClamped() {
        let state = IndexProgressState()
        _ = state.update(LSPProgress(token: "idx", stage: .begin, title: "Indexing"))
        #expect(state.update(LSPProgress(token: "idx", stage: .report, message: "1 / 4", percentage: 80))?.percent == 80)
        #expect(state.update(LSPProgress(token: "idx", stage: .report, percentage: 250))?.percent == 100)
    }

    @Test func percentFromMessageParsesCountsOnly() {
        #expect(IndexProgressState.percent(fromMessage: "30 / 48") == 62)
        #expect(IndexProgressState.percent(fromMessage: "30/48") == 62)
        #expect(IndexProgressState.percent(fromMessage: "Determining files") == nil)
        #expect(IndexProgressState.percent(fromMessage: "3 / 0") == nil)
        #expect(IndexProgressState.percent(fromMessage: nil) == nil)
    }
}
