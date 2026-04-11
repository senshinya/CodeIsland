import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStateCompletionTests: XCTestCase {
    func testDismissSessionRetainsVisibleCompletionSnapshot() {
        let appState = AppState()
        let sessionId = "s-complete"

        var session = SessionSnapshot()
        session.source = "claude"
        session.lastAssistantMessage = "All done"
        appState.sessions[sessionId] = session
        appState.surface = .completionCard(sessionId: sessionId)
        appState.activeSessionId = sessionId

        appState.dismissSession(sessionId)

        XCTAssertEqual(appState.justCompletedSessionId, sessionId)
        XCTAssertEqual(appState.retainedCompletionSessionId, sessionId)
        XCTAssertEqual(appState.retainedCompletionSession?.lastAssistantMessage, "All done")
        XCTAssertNil(appState.sessions[sessionId])
    }

    func testCompletionMessageSubmitCollapsesImmediatelyWithoutQueuedItems() {
        let appState = AppState()
        let sessionId = "s-complete"

        appState.sessions[sessionId] = SessionSnapshot()
        appState.surface = .completionCard(sessionId: sessionId)
        appState.isMessageInputFocused = true

        appState.completeCompletionMessageSubmission()

        XCTAssertFalse(appState.isMessageInputFocused)
        if case .collapsed = appState.surface {
        } else {
            XCTFail("Expected completion card to collapse immediately after sending")
        }
    }
}
