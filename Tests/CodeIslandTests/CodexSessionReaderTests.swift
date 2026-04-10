import XCTest
@testable import CodeIsland

final class CodexSessionReaderTests: XCTestCase {
    func testReadMessagesParsesCodexTimeline() throws {
        let transcript = [
            #"{"timestamp":"2026-04-10T11:25:35.635Z","type":"event_msg","payload":{"type":"user_message","message":"align this panel"}}"#,
            #"{"timestamp":"2026-04-10T11:25:36.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"swift build\"}","call_id":"call-1"}}"#,
            #"{"timestamp":"2026-04-10T11:25:37.000Z","type":"event_msg","payload":{"type":"agent_message","message":"I will update the styles."}}"#
        ].joined(separator: "\n")

        let path = try makeTranscript(transcript)
        let messages = CodexSessionReader.readMessages(at: path)

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].text, "align this panel")
        XCTAssertEqual(messages[1].role, .tool(name: "exec_command"))
        XCTAssertEqual(messages[1].text, "exec_command: swift build")
        XCTAssertEqual(messages[2].role, .assistant)
        XCTAssertEqual(messages[2].text, "I will update the styles.")
    }

    func testReadMessagesSkipsEmptyAndMalformedCodexEntries() throws {
        let transcript = [
            "not-json",
            #"{"timestamp":"2026-04-10T11:25:35.635Z","type":"event_msg","payload":{"type":"user_message","message":""}}"#,
            #"{"timestamp":"2026-04-10T11:25:37.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"not-json","call_id":"call-1"}}"#
        ].joined(separator: "\n")

        let path = try makeTranscript(transcript)
        let messages = CodexSessionReader.readMessages(at: path)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .tool(name: "exec_command"))
        XCTAssertEqual(messages[0].text, "exec_command")
    }

    private func makeTranscript(_ content: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }
}
