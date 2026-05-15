import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStateQuestionFlowTests: XCTestCase {
    func testAskUserQuestionMultiQuestionReturnsQuestionsAndAnswers() async throws {
        let appState = AppState()
        let questions = [
            question(header: "mode", text: "How should I work?", options: ["execute", "plan"]),
            question(header: "style", text: "How should I reply?", options: ["brief", "balanced"]),
        ]
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-1",
            questions: questions
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
        let updatedInput = try extractUpdatedInput(from: responseData)
        let returnedQuestions = try XCTUnwrap(updatedInput["questions"] as? [[String: Any]])
        XCTAssertEqual(returnedQuestions.count, questions.count)
        XCTAssertEqual(returnedQuestions[0]["question"] as? String, questions[0]["question"] as? String)
        XCTAssertEqual(returnedQuestions[1]["question"] as? String, questions[1]["question"] as? String)

        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["How should I work?"] as? String, "plan")
        XCTAssertEqual(answers["How should I reply?"] as? String, "balanced")
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
        XCTAssertEqual(answers["Reply in which language?"] as? String, "Chinese")
    }

    func testDismissAskUserQuestionReturnsEmptyResponse() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-dismiss",
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
        appState.dismissQuestion()

        let responseData = await responseTask.value
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        XCTAssertNil(json["hookSpecificOutput"])
        XCTAssertTrue(json.isEmpty)
        XCTAssertEqual(appState.questionQueue.count, 0)
        XCTAssertEqual(appState.sessions["s-dismiss"]?.status, .processing)
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

    func testDuplicateQuestionTextsGetDedupedKeys() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-dup",
            questions: [
                question(header: "first", text: "Same question", options: ["A", "B"]),
                question(header: "second", text: "Same question", options: ["C", "D"]),
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.answerQuestionMulti([
            (question: "Same question", answer: "A"),
            (question: "Same question", answer: "D"),
        ])

        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["Same question"] as? String, "A")
        XCTAssertEqual(answers["Same question_2"] as? String, "D")
    }

    func testMissingQuestionTextUsesIndexedFallbackKeys() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-noq",
            questions: [
                question(header: "first", text: "", options: ["A", "B"]),
                question(header: "second", text: "   ", options: ["C", "D"]),
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.answerQuestionMulti([
            (question: "", answer: "B"),
            (question: "   ", answer: "C"),
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

    /// Regression: answering an AskUserQuestion while another session's
    /// completion is queued (interactive surface was locked) must not strand
    /// the panel on a contentless `.questionCard`. Previously showNextPending →
    /// showNextCompletionOrCollapse → showCompletion bounced off the still-locked
    /// `.questionCard` surface, re-queued the completion, and left surface on
    /// `.questionCard` with an empty questionQueue — a state `.onHover` refuses
    /// to collapse, so the panel was permanently stuck.
    func testAnsweringQuestionWithQueuedCompletionDoesNotStrandQuestionCard() async throws {
        let autoExpandKey = SettingsKey.autoExpandOnCompletion
        let previous = UserDefaults.standard.object(forKey: autoExpandKey)
        UserDefaults.standard.set(true, forKey: autoExpandKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: autoExpandKey)
            } else {
                UserDefaults.standard.removeObject(forKey: autoExpandKey)
            }
        }

        let appState = AppState()

        // A second session that finishes while the question card is up.
        var sessionB = SessionSnapshot()
        sessionB.source = "claude"
        sessionB.lastAssistantMessage = "done"
        appState.sessions["s-B"] = sessionB

        // Session A asks a question -> surface locks to .questionCard(s-A).
        let questionEvent = try makeAskUserQuestionEvent(
            sessionId: "s-A",
            questions: [question(header: "q", text: "Pick one?", options: ["A", "B"])]
        )
        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(questionEvent, continuation: continuation)
            }
        }
        await Task.yield()
        guard case .questionCard = appState.surface else {
            return XCTFail("Expected .questionCard after AskUserQuestion, got \(appState.surface)")
        }

        // Session B completes while the question card is locked -> queued.
        appState.handleEvent(try makeStopEvent(sessionId: "s-B"))

        // User answers A. Must NOT leave the panel stranded on .questionCard.
        appState.answerQuestionMulti([(question: "Pick one?", answer: "A")])
        _ = await responseTask.value

        XCTAssertEqual(appState.questionQueue.count, 0)
        if case .questionCard = appState.surface {
            XCTFail("Panel stranded on contentless .questionCard after answering with a queued completion")
        }
        // The queued completion for s-B should now surface.
        if case .completionCard(let sid) = appState.surface {
            XCTAssertEqual(sid, "s-B")
        } else {
            XCTFail("Expected queued completion for s-B to surface, got \(appState.surface)")
        }
    }

    private func makeStopEvent(sessionId: String) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": "Stop",
            "session_id": sessionId,
            "_source": "claude",
            "last_assistant_message": "done",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            throw NSError(domain: "AppStateQuestionFlowTests", code: 2)
        }
        return event
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

    private func extractUpdatedInput(from responseData: Data) throws -> [String: Any] {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        return try XCTUnwrap(decision["updatedInput"] as? [String: Any])
    }

    private func extractAnswers(from responseData: Data) throws -> [String: Any] {
        let updatedInput = try extractUpdatedInput(from: responseData)
        return try XCTUnwrap(updatedInput["answers"] as? [String: Any])
    }

    private func extractPermissionBehavior(from responseData: Data) throws -> String {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        return try XCTUnwrap(decision["behavior"] as? String)
    }
}
