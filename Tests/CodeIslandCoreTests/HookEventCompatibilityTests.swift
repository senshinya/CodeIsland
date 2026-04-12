import XCTest
@testable import CodeIslandCore

final class HookEventCompatibilityTests: XCTestCase {
    func testHookEventAcceptsCamelCaseAndNestedPayloadFields() throws {
        let payload: [String: Any] = [
            "hookEventName": "PreToolUse",
            "sessionId": "session-1",
            "agentId": "agent-1",
            "payload": [
                "toolName": "Bash",
                "toolInput": [
                    "description": "Run targeted tests"
                ],
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try XCTUnwrap(HookEvent(from: data))

        XCTAssertEqual(event.eventName, "PreToolUse")
        XCTAssertEqual(event.sessionId, "session-1")
        XCTAssertEqual(event.agentId, "agent-1")
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.toolInput?["description"] as? String, "Run targeted tests")
        XCTAssertEqual(event.toolDescription, "Run targeted tests")
    }

    func testReduceEventReadsAssistantTextFromNestedPayload() throws {
        let payload: [String: Any] = [
            "hook_event_name": "AfterAgentResponse",
            "session_id": "session-1",
            "payload": [
                "message": "Nested assistant reply"
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try XCTUnwrap(HookEvent(from: data))
        var sessions: [String: SessionSnapshot] = ["session-1": SessionSnapshot()]

        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertEqual(sessions["session-1"]?.lastAssistantMessage, "Nested assistant reply")
        XCTAssertEqual(sessions["session-1"]?.recentMessages.last?.text, "Nested assistant reply")
        XCTAssertEqual(sessions["session-1"]?.status, .processing)
    }

    func testReduceEventReadsNotificationTextFromNestedData() throws {
        let payload: [String: Any] = [
            "eventName": "Notification",
            "sessionId": "session-1",
            "data": [
                "detail": "Waiting for external confirmation"
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try XCTUnwrap(HookEvent(from: data))
        var sessions: [String: SessionSnapshot] = ["session-1": SessionSnapshot()]

        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertEqual(sessions["session-1"]?.toolDescription, "Waiting for external confirmation")
    }
}
