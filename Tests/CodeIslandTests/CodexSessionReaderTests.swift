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

    func testBestMatchingSessionPathFallsBackWhenStrictProcessStartFilterMissesRestoredTranscript() throws {
        let baseURL = try makeSessionsBase()
        let transcriptURL = try makeCodexTranscript(
            baseURL: baseURL,
            dayPath: recentDayPath(daysBack: 0),
            fileName: "rollout-2026-04-10T11-25-35-thread-a.jsonl",
            cwd: "/tmp/demo",
            modifiedAt: Date(timeIntervalSince1970: 1_744_285_900)
        )

        let processStart = Date(timeIntervalSince1970: 1_744_286_400)
        let resolved = CodexSessionReader.bestMatchingSessionPath(
            base: baseURL.path,
            cwd: "/tmp/demo",
            after: processStart,
            fileManager: .default
        )

        XCTAssertEqual(resolved, transcriptURL.path)
    }

    func testBestMatchingSessionPathPrefersStrictMatchBeforeFallback() throws {
        let baseURL = try makeSessionsBase()
        let olderURL = try makeCodexTranscript(
            baseURL: baseURL,
            dayPath: recentDayPath(daysBack: 1),
            fileName: "rollout-2026-04-09T11-25-35-thread-a.jsonl",
            cwd: "/tmp/demo",
            modifiedAt: Date(timeIntervalSince1970: 1_744_199_500)
        )
        let newerURL = try makeCodexTranscript(
            baseURL: baseURL,
            dayPath: recentDayPath(daysBack: 0),
            fileName: "rollout-2026-04-10T11-25-35-thread-b.jsonl",
            cwd: "/tmp/demo",
            modifiedAt: Date(timeIntervalSince1970: 1_744_286_450)
        )

        let processStart = Date(timeIntervalSince1970: 1_744_286_400)
        let resolved = CodexSessionReader.bestMatchingSessionPath(
            base: baseURL.path,
            cwd: "/tmp/demo",
            after: processStart,
            fileManager: .default
        )

        XCTAssertNotEqual(olderURL.path, newerURL.path)
        XCTAssertEqual(resolved, newerURL.path)
    }

    private func makeTranscript(_ content: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    private func makeSessionsBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeCodexTranscript(
        baseURL: URL,
        dayPath: String,
        fileName: String,
        cwd: String,
        modifiedAt: Date
    ) throws -> URL {
        let directoryURL = baseURL.appendingPathComponent(dayPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

        let transcriptURL = directoryURL.appendingPathComponent(fileName)
        let line = #"{"timestamp":"2026-04-10T11:25:35.635Z","type":"event_msg","payload":{"cwd":"\#(cwd)"}}"#
        try line.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: transcriptURL.path)
        return transcriptURL
    }

    private func recentDayPath(daysBack: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        let year = String(format: "%04d", calendar.component(.year, from: date))
        let month = String(format: "%02d", calendar.component(.month, from: date))
        let day = String(format: "%02d", calendar.component(.day, from: date))
        return "\(year)/\(month)/\(day)"
    }
}
