import XCTest
import AppKit
@testable import CodeIsland
@testable import CodeIslandCore

final class SessionChatDisplayReconcilerTests: XCTestCase {
    func testChatInputHeightRangeFitsExactlyThreeLines() {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let range = ChatInputMetrics.heightRange(for: font)

        XCTAssertEqual(range.max, measuredChatInputContentHeight(for: "1\n2\n3", font: font))
    }

    func testChatInputHeightRangeStillOverflowsAtFourLines() {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let range = ChatInputMetrics.heightRange(for: font)

        XCTAssertGreaterThan(measuredChatInputContentHeight(for: "1\n2\n3\n4", font: font), range.max)
    }

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

    func testSupportedTransportSkipsTTYResolutionForKakuWhenCwdIsEnough() {
        var session = SessionSnapshot()
        session.source = "claude"
        session.termBundleId = "fun.tw93.kaku"
        session.cwd = "/Users/shinya/Downloads/CodeIsland"

        var ttyResolverCallCount = 0
        guard case let .kaku(paneId, tty, cwd) = MessageSender.supportedTransport(
            for: session,
            ttyResolver: {
                ttyResolverCallCount += 1
                return "/dev/ttys999"
            }
        ) else {
            return XCTFail("Expected Kaku transport")
        }

        XCTAssertNil(paneId)
        XCTAssertNil(tty)
        XCTAssertEqual(cwd, session.cwd)
        XCTAssertEqual(ttyResolverCallCount, 0)
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
        session.termBundleId = "dev.warp.Warp-Stable"
        session.ttyPath = "/dev/ttys001"

        XCTAssertFalse(SessionChatView.SessionMessageBarSupport.canShow(for: session))
    }

    func testMessageBarIsAvailableForClaudeInITerm2WithSessionId() {
        var session = SessionSnapshot()
        session.source = "claude"
        session.termBundleId = "com.googlecode.iterm2"
        session.itermSessionId = "w0t0p0:1234-5678"

        XCTAssertTrue(SessionChatView.SessionMessageBarSupport.canShow(for: session))
    }

    func testMessageBarStaysHiddenForITerm2WithoutSessionId() {
        var session = SessionSnapshot()
        session.source = "claude"
        session.termBundleId = "com.googlecode.iterm2"
        // No itermSessionId — targeting would be ambiguous, so we refuse rather than guess.

        XCTAssertFalse(SessionChatView.SessionMessageBarSupport.canShow(for: session))
    }

    func testMessageBarIsAvailableForClaudeInTerminalAppWithTTY() {
        var session = SessionSnapshot()
        session.source = "claude"
        session.termBundleId = "com.apple.Terminal"
        session.ttyPath = "/dev/ttys001"

        XCTAssertTrue(SessionChatView.SessionMessageBarSupport.canShow(for: session))
    }

    func testSupportedTransportResolvesTTYForTerminalAppWhenNeeded() {
        var session = SessionSnapshot()
        session.source = "claude"
        session.termBundleId = "com.apple.Terminal"

        var ttyResolverCallCount = 0
        guard case let .terminalApp(tty) = MessageSender.supportedTransport(
            for: session,
            ttyResolver: {
                ttyResolverCallCount += 1
                return "ttys007"
            }
        ) else {
            return XCTFail("Expected Terminal.app transport")
        }

        XCTAssertEqual(tty, "/dev/ttys007")
        XCTAssertEqual(ttyResolverCallCount, 1)
    }

    func testMessageBarIsAvailableForClaudeInKittyWithWindowId() {
        var session = SessionSnapshot()
        session.source = "claude"
        session.termBundleId = "net.kovidgoyal.kitty"
        session.kittyWindowId = "42"

        XCTAssertTrue(SessionChatView.SessionMessageBarSupport.canShow(for: session))
    }

    func testMessageBarIsAvailableForCodexWithTmux() {
        var session = SessionSnapshot()
        session.source = "codex"
        session.tmuxPane = "%1"

        XCTAssertTrue(SessionChatView.SessionMessageBarSupport.canShow(for: session))
    }

    func testMessageBarIsAvailableForCodexInGhosttyWithTTY() {
        var session = SessionSnapshot()
        session.source = "codex"
        session.termBundleId = "com.mitchellh.ghostty"
        session.ttyPath = "/dev/ttys001"

        XCTAssertTrue(SessionChatView.SessionMessageBarSupport.canShow(for: session))
    }

    func testMessageBarStaysHiddenForCodexInUnsupportedTerminal() {
        var session = SessionSnapshot()
        session.source = "codex"
        session.termBundleId = "dev.warp.Warp-Stable"
        session.ttyPath = "/dev/ttys001"

        XCTAssertFalse(SessionChatView.SessionMessageBarSupport.canShow(for: session))
    }

    func testRawTerminalSendBatchesKeepClaudeSingleShot() {
        XCTAssertEqual(
            MessageSender.rawTerminalSendBatches(text: "hello", source: "claude"),
            ["hello\r"]
        )
    }

    func testRawTerminalSendBatchesSplitCodexSubmit() {
        XCTAssertEqual(
            MessageSender.rawTerminalSendBatches(text: "hello", source: "codex"),
            ["hello", "\r"]
        )
    }

    func testMessageBarStaysHiddenForUnsupportedSessions() {
        var session = SessionSnapshot()
        session.source = "other"
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

    private func measuredChatInputContentHeight(for text: String, font: NSFont) -> CGFloat {
        let textView = NSTextView(frame: .zero)
        textView.font = font
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.frame.size.width = 300

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            XCTFail("Expected text system to be configured")
            return 0
        }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let insets = textView.textContainerInset.height * 2
        return ceil(usedRect.height + insets)
    }
}
