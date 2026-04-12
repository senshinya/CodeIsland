import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStateQuestionFlowTests: XCTestCase {
    func testAskUserQuestionMultiQuestionReturnsAllAnswers() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-1",
            questions: [
                question(header: "mode", text: "How should I work?", options: ["execute", "plan"]),
                question(header: "style", text: "How should I reply?", options: ["brief", "balanced"]),
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        XCTAssertEqual(appState.questionQueue.count, 1)

        appState.answerQuestionMulti([
            (question: "How should I work?", answer: "plan"),
            (question: "How should I reply?", answer: "balanced"),
        ])

        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["mode"] as? String, "plan")
        XCTAssertEqual(answers["style"] as? String, "balanced")
    }

    func testAskUserQuestionSingleQuestionWorks() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-2",
            questions: [
                question(header: "language", text: "Reply in which language?", options: ["Chinese", "English"]),
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.answerQuestionMulti([
            (question: "Reply in which language?", answer: "Chinese"),
        ])

        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["language"] as? String, "Chinese")
    }

    func testSkipAskUserQuestionReturnsDeny() async throws {
        let appState = AppState()
        appState.sessions["s-skip"] = SessionSnapshot()
        appState.sessions["s-skip"]?.status = .waitingQuestion
        appState.sessions["s-skip"]?.currentTool = "AskUserQuestion"
        appState.sessions["s-skip"]?.toolDescription = "Prompt"
        appState.activeSessionId = "s-skip"
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-skip",
            questions: [
                question(header: "mode", text: "How should I work?", options: ["execute", "plan"]),
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.skipQuestion()

        let responseData = await responseTask.value
        let behavior = try extractPermissionBehavior(from: responseData)
        XCTAssertEqual(behavior, "deny")
        XCTAssertEqual(appState.questionQueue.count, 0)
        XCTAssertEqual(appState.sessions["s-skip"]?.status, .idle)
        XCTAssertNil(appState.sessions["s-skip"]?.currentTool)
        XCTAssertNil(appState.sessions["s-skip"]?.toolDescription)
    }

    func testDisconnectDuringAskUserQuestionReturnsDeny() async throws {
        let appState = AppState()
        let sessionId = "s-disconnect"
        let event = try makeAskUserQuestionEvent(
            sessionId: sessionId,
            questions: [
                question(header: "mode", text: "How should I work?", options: ["execute", "plan"]),
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.handlePeerDisconnect(sessionId: sessionId)

        let responseData = await responseTask.value
        let behavior = try extractPermissionBehavior(from: responseData)
        XCTAssertEqual(behavior, "deny")
        XCTAssertEqual(appState.questionQueue.count, 0)
    }

    func testDuplicateHeadersGetDedupedKeys() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-dup",
            questions: [
                question(header: "preference", text: "First question", options: ["A", "B"]),
                question(header: "preference", text: "Second question", options: ["C", "D"]),
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.answerQuestionMulti([
            (question: "First question", answer: "A"),
            (question: "Second question", answer: "D"),
        ])

        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["preference"] as? String, "A")
        XCTAssertEqual(answers["preference_2"] as? String, "D")
    }

    func testMissingHeaderUsesIndexedFallbackKeys() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-nohdr",
            questions: [
                question(header: nil, text: "No header", options: ["A", "B"]),
                question(header: "", text: "Empty header", options: ["C", "D"]),
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.answerQuestionMulti([
            (question: "No header", answer: "B"),
            (question: "Empty header", answer: "C"),
        ])

        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["answer_1"] as? String, "B")
        XCTAssertEqual(answers["answer_2"] as? String, "C")
    }

    func testDirectAnswerQuestionIgnoredForAskUserQuestion() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-block",
            questions: [
                question(header: "q1", text: "Question?", options: ["A", "B"]),
            ]
        )

        _ = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.answerQuestion("A")
        XCTAssertEqual(appState.questionQueue.count, 1)
    }

    private func makeAskUserQuestionEvent(sessionId: String, questions: [[String: Any]]) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": questions
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            throw NSError(domain: "AppStateQuestionFlowTests", code: 1)
        }
        return event
    }

    private func question(header: String?, text: String, options: [String]) -> [String: Any] {
        var result: [String: Any] = [
            "question": text,
            "options": options.map { ["label": $0, "description": ""] }
        ]
        if let header {
            result["header"] = header
        }
        return result
    }

    private func extractAnswers(from responseData: Data) throws -> [String: Any] {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        let updatedInput = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        return try XCTUnwrap(updatedInput["answers"] as? [String: Any])
    }

    private func extractPermissionBehavior(from responseData: Data) throws -> String {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        return try XCTUnwrap(decision["behavior"] as? String)
    }
}
