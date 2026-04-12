import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

final class SessionChatDisplayReconcilerTests: XCTestCase {
    func testMessageBarIsAvailableForClaudeWithoutTmux() {
        var session = SessionSnapshot()
        session.source = "claude"
        session.tmuxPane = nil

        XCTAssertFalse(SessionChatView.SessionMessageBarSupport.canShow(for: session))
    }

    func testMessageBarIsAvailableForClaudeWithTmux() {
        var session = SessionSnapshot()
        session.source = "claude"
        session.tmuxPane = "%1"

        XCTAssertTrue(SessionChatView.SessionMessageBarSupport.canShow(for: session))
    }

    func testMessageBarIsAvailableForClaudeInGhosttyWithTTY() {
        var session = SessionSnapshot()
        session.source = "claude"
        session.termBundleId = "com.mitchellh.ghostty"
        session.ttyPath = "/dev/ttys001"

        XCTAssertTrue(SessionChatView.SessionMessageBarSupport.canShow(for: session))
    }

    func testMessageBarPrefersTmuxOverGhosttyWhenBothAreAvailable() {
        var session = SessionSnapshot()
        session.source = "claude"
        session.tmuxPane = "%1"
        session.termBundleId = "com.mitchellh.ghostty"
        session.ttyPath = "/dev/ttys001"

        guard case let .tmux(pane, _) = MessageSender.supportedTransport(for: session) else {
            return XCTFail("Expected tmux transport to take priority")
        }
        XCTAssertEqual(pane, "%1")
    }

    func testMessageBarStaysHiddenForClaudeInUnsupportedTerminal() {
        var session = SessionSnapshot()
        session.source = "claude"
        session.termBundleId = "com.googlecode.iterm2"
        session.itermSessionId = "w0t0p0:1234-5678"

        XCTAssertFalse(SessionChatView.SessionMessageBarSupport.canShow(for: session))
    }

    func testMessageBarStaysHiddenForNonClaudeSessions() {
        var session = SessionSnapshot()
        session.source = "codex"
        session.tmuxPane = "%1"

        XCTAssertFalse(SessionChatView.SessionMessageBarSupport.canShow(for: session))
    }

    func testMatchedPendingUserMessageReusesPendingDisplayID() {
        let pending = SessionChatMessage(
            id: "pending-user-1",
            role: .user,
            text: "ship it",
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let parsed = SessionChatMessage(
            id: "transcript-user-1",
            role: .user,
            text: "ship it",
            timestamp: Date(timeIntervalSince1970: 102)
        )

        let reconciliation = SessionChatDisplayReconciler.reconcilePendingMessages(
            pending: [pending],
            parsed: [parsed],
            existingResolvedDisplayIDs: [:]
        )
        let displayIDs = SessionChatDisplayReconciler.updatedResolvedDisplayIDs(
            existing: [:],
            parsed: [parsed],
            matchedDisplayIDs: reconciliation.matchedDisplayIDs
        )
        let displayed = SessionChatDisplayReconciler.displayMessages(
            messages: [parsed],
            pending: reconciliation.unresolvedPending,
            resolvedDisplayIDs: displayIDs
        )

        XCTAssertTrue(reconciliation.unresolvedPending.isEmpty)
        XCTAssertEqual(displayed.map(\.id), ["pending-user-1"])
        XCTAssertEqual(displayed.map(\.message.id), ["transcript-user-1"])
    }

    func testAssistantAppendKeepsPendingUserRowStableWhileAddingAssistantRow() {
        let pending = SessionChatMessage(
            id: "pending-user-1",
            role: .user,
            text: "ship it",
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let assistant = SessionChatMessage(
            id: "assistant-1",
            role: .assistant,
            text: "working on it",
            timestamp: Date(timeIntervalSince1970: 105)
        )
        let oldDisplayed = SessionChatDisplayReconciler.displayMessages(
            messages: [],
            pending: [pending],
            resolvedDisplayIDs: [:]
        )
        let parsedUser = SessionChatMessage(
            id: "transcript-user-1",
            role: .user,
            text: "ship it",
            timestamp: Date(timeIntervalSince1970: 102)
        )
        let reconciliation = SessionChatDisplayReconciler.reconcilePendingMessages(
            pending: [pending],
            parsed: [parsedUser, assistant],
            existingResolvedDisplayIDs: [:]
        )
        let displayIDs = SessionChatDisplayReconciler.updatedResolvedDisplayIDs(
            existing: [:],
            parsed: [parsedUser, assistant],
            matchedDisplayIDs: reconciliation.matchedDisplayIDs
        )
        let newDisplayed = SessionChatDisplayReconciler.displayMessages(
            messages: [parsedUser, assistant],
            pending: reconciliation.unresolvedPending,
            resolvedDisplayIDs: displayIDs
        )

        XCTAssertEqual(oldDisplayed.map(\.id), ["pending-user-1"])
        XCTAssertEqual(newDisplayed.map(\.id), ["pending-user-1", "assistant-1"])
    }

    func testResolvedDisplayIDsArePrunedWhenParsedMessageDisappears() {
        let updated = SessionChatDisplayReconciler.updatedResolvedDisplayIDs(
            existing: [
                "transcript-user-1": "pending-user-1",
                "transcript-user-2": "pending-user-2"
            ],
            parsed: [
                SessionChatMessage(
                    id: "transcript-user-2",
                    role: .user,
                    text: "keep",
                    timestamp: Date(timeIntervalSince1970: 100)
                )
            ],
            matchedDisplayIDs: [:]
        )

        XCTAssertEqual(updated, ["transcript-user-2": "pending-user-2"])
    }
}
