import XCTest
@testable import CodeIsland

final class AppStateCodexTranscriptTests: XCTestCase {
    func testCodexLatestTerminalTurnTimestampPrefersNewestTerminalEvent() throws {
        let transcript = [
            #"{"timestamp":"2026-04-09T03:17:16.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#,
            #"{"timestamp":"2026-04-09T03:17:18.000Z","type":"event_msg","payload":{"type":"agent_message","message":"still working"}}"#,
            #"{"timestamp":"2026-04-09T03:17:20.500Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-2"}}"#
        ].joined(separator: "\n")

        let timestamp = try XCTUnwrap(AppState.codexLatestTerminalTurnTimestamp(in: transcript))

        XCTAssertEqual(timestamp, try timestampFrom("2026-04-09T03:17:20.500Z"))
    }

    func testCodexLatestTerminalTurnTimestampTreatsAbortedAndFailedTurnsAsTerminal() throws {
        let transcript = [
            #"{"timestamp":"2026-04-09T03:17:16.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#,
            #"{"timestamp":"2026-04-09T03:17:21Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#,
            #"{"timestamp":"2026-04-09T03:17:19.000Z","type":"event_msg","payload":{"type":"turn_failed","reason":"tool_error"}}"#
        ].joined(separator: "\n")

        let timestamp = try XCTUnwrap(AppState.codexLatestTerminalTurnTimestamp(in: transcript))

        XCTAssertEqual(timestamp, try timestampFrom("2026-04-09T03:17:21Z"))
    }

    func testCodexLatestTerminalTurnTimestampIgnoresMalformedAndNonTerminalEvents() {
        let transcript = [
            "not-json",
            #"{"timestamp":"2026-04-09T03:17:16.000Z","type":"event_msg","payload":{"type":"agent_message","message":"done"}}"#,
            #"{"timestamp":"2026-04-09T03:17:17.000Z","type":"response_item","payload":{"type":"message"}}"#
        ].joined(separator: "\n")

        XCTAssertNil(AppState.codexLatestTerminalTurnTimestamp(in: transcript))
    }

    private func timestampFrom(_ raw: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let timestamp = fractional.date(from: raw) {
            return timestamp
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(plain.date(from: raw))
    }
}
