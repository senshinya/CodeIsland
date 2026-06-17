import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStateToolUseCacheTests: XCTestCase {

    // MARK: - Cache lifecycle

    func testPreToolUseCachesRecord() throws {
        let appState = AppState()
        let event = try makeHookEvent(
            name: "PreToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_1",
            toolInput: ["command": "ls"]
        )

        appState.handleEvent(event)

        let cached = try XCTUnwrap(appState.pendingToolUses["toolu_1"])
        XCTAssertEqual(cached.sessionId, "s1")
        XCTAssertEqual(cached.toolName, "Bash")
    }

    func testPostToolUseClearsCache() throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))
        XCTAssertNotNil(appState.pendingToolUses["toolu_1"])

        appState.handleEvent(try makeHookEvent(name: "PostToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))

        XCTAssertNil(appState.pendingToolUses["toolu_1"])
    }

    func testPostToolUseFailureAlsoClearsCache() throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))

        appState.handleEvent(try makeHookEvent(name: "PostToolUseFailure", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))

        XCTAssertNil(appState.pendingToolUses["toolu_1"])
    }

    func testPruneRemovesExpiredRecords() throws {
        let appState = AppState()
        appState.pendingToolUses["ancient"] = PreToolUseRecord(
            sessionId: "s1",
            toolName: "Bash",
            toolDescription: nil,
            toolInput: nil,
            receivedAt: Date(timeIntervalSinceNow: -(AppState.pendingToolUseTTL + 60))
        )
        appState.pendingToolUses["fresh"] = PreToolUseRecord(
            sessionId: "s1",
            toolName: "Bash",
            toolDescription: nil,
            toolInput: nil,
            receivedAt: Date()
        )

        appState.prunePendingToolUses()

        XCTAssertNil(appState.pendingToolUses["ancient"])
        XCTAssertNotNil(appState.pendingToolUses["fresh"])
    }

    // MARK: - Duplicate PermissionRequest replay

    func testDuplicatePermissionRequestReplacesContinuationAndDeniesOld() async throws {
        let appState = AppState()
        let first = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "dup_1")
        let second = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "dup_1")

        let firstTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(first, continuation: cont)
            }
        }
        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 1)

        let secondTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(second, continuation: cont)
            }
        }

        // The old continuation should be denied immediately; queue length stays 1.
        let firstResponse = await firstTask.value
        XCTAssertEqual(try behavior(firstResponse), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 1)

        // Second (replacement) continuation still waits for user decision.
        appState.approvePermission()
        let secondResponse = await secondTask.value
        XCTAssertEqual(try behavior(secondResponse), "allow")
    }

    /// Repro for #169: parallel tool calls that share a tool_use_id but operate
    /// on different inputs (e.g. "Read 4 files" at once) must not deny one
    /// another. Merging by id alone denied all but the last, which users saw as
    /// "denied by PermissionRequest hook" on tools they never rejected.
    func testParallelRequestsSharingIdButDifferentInputAreNotMerged() async throws {
        let appState = AppState()
        let readA = try makeHookEvent(
            name: "PermissionRequest", sessionId: "s1", toolName: "Read",
            toolUseId: "shared_id", toolInput: ["file_path": "/a.txt"]
        )
        let readB = try makeHookEvent(
            name: "PermissionRequest", sessionId: "s1", toolName: "Read",
            toolUseId: "shared_id", toolInput: ["file_path": "/b.txt"]
        )

        let taskA = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(readA, continuation: cont)
            }
        }
        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 1)

        let taskB = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(readB, continuation: cont)
            }
        }
        await Task.yield()

        XCTAssertEqual(appState.permissionQueue.count, 2,
            "Parallel requests with different inputs must not deny each other (#169)")

        // Both stay until the user decides each one.
        appState.approvePermission()
        let responseA = await taskA.value
        XCTAssertEqual(try behavior(responseA), "allow")
        appState.approvePermission()
        let responseB = await taskB.value
        XCTAssertEqual(try behavior(responseB), "allow")
    }

    // MARK: - Stale queue drain via PostToolUse

    func testPostToolUseDrainsQueuedPermissionForSameId() async throws {
        let appState = AppState()
        let pending = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "toolu_drain")

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(pending, continuation: cont)
            }
        }
        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 1)

        // Agent moved on — emits PostToolUse for the same tool_use_id.
        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_drain"
        ))

        let response = await responseTask.value
        XCTAssertEqual(try behavior(response), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testPostToolUseDoesNotAffectUnrelatedQueueEntries() async throws {
        let appState = AppState()
        let kept = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "keep_me")
        let drained = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "drop_me")

        let keptTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(kept, continuation: cont)
            }
        }
        let drainedTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(drained, continuation: cont)
            }
        }
        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 2)

        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "drop_me"
        ))

        let drainedResponse = await drainedTask.value
        XCTAssertEqual(try behavior(drainedResponse), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.permissionQueue.first?.toolUseId, "keep_me")

        appState.approvePermission()
        let keptResponse = await keptTask.value
        XCTAssertEqual(try behavior(keptResponse), "allow")
    }

    // MARK: - Backfill from cache

    func testEnrichBackfillsMissingToolNameFromCache() throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(
            name: "PreToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_enrich",
            toolInput: ["command": "ls"]
        ))

        // PermissionRequest payload omits tool_name (simulates a thin third-party re-emit).
        let thin = try makeRawHookEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_use_id": "toolu_enrich"
        ])

        Task {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(thin, continuation: cont)
            }
        }

        // Give the main actor a tick to execute the synchronous path.
        let session = appState.sessions["s1"]
        XCTAssertEqual(session?.currentTool, "Bash")
    }

    // MARK: - issue #216: orphan permissions (no tool_use_id) auto-dismiss on terminal approval

    /// Repro for #216: a PermissionRequest carrying NO tool_use_id can never be
    /// correlated by resolveToolUseIfCompleted, so approving in the terminal left
    /// the card up until the user closed it manually. After the fix, a follow-up
    /// same-session activity event resolves the orphan as approved-in-terminal.
    func testOrphanPermissionResolvedByFollowUpActivity() async throws {
        let appState = AppState()
        let orphan = try makeHookEvent(
            name: "PermissionRequest",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: nil,
            toolInput: ["command": "echo hi"]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(orphan, continuation: cont)
            }
        }
        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertNil(appState.permissionQueue.first?.toolUseId)

        // Agent moved on (user approved in terminal) — a follow-up PostToolUse
        // arrives for the same session with no correlatable tool_use_id.
        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: nil
        ))

        let response = await responseTask.value
        XCTAssertEqual(try behavior(response), "allow")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    /// The orphan resolver only touches requests with an empty/nil tool_use_id.
    /// A queued request that DOES carry a tool_use_id is never resolved by the
    /// orphan path itself — it runs first and leaves the correlated request for
    /// the existing surgical-drain / blanket-drain paths to handle.
    func testOrphanResolverLeavesCorrelatedRequestUntouched() async throws {
        let appState = AppState()
        let correlated = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "toolu_keep")

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(correlated, continuation: cont)
            }
        }
        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 1)

        // The orphan resolver in isolation must not drain a tool_use_id-bearing
        // request even when an activity event for the same session arrives.
        appState.resolveOrphanPermissionsOnActivity(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: nil
        ))

        XCTAssertEqual(appState.permissionQueue.count, 1,
            "Orphan resolver must not touch a request carrying a tool_use_id (#147)")
        XCTAssertEqual(appState.permissionQueue.first?.toolUseId, "toolu_keep")

        appState.approvePermission()
        let response = await responseTask.value
        XCTAssertEqual(try behavior(response), "allow")
    }

    // MARK: - issue #224: "always allow" rule specifier for MCP vs non-MCP tools

    /// #224: "Always allow" for an MCP tool (`mcp__server__tool`) must emit a
    /// bare-tool-name rule with NO `ruleContent` specifier. Claude Code's MCP
    /// permission rules don't take a specifier; sending `ruleContent: "*"`
    /// assembles `mcp__server__tool(*)`, which never matches a real MCP call, so
    /// the rule silently fails to persist and the same approval re-prompts.
    func testAlwaysAllowMCPToolOmitsRuleSpecifier() async throws {
        let appState = AppState()
        let event = try makePermissionEvent(
            sessionId: "s-mcp-always",
            toolName: "mcp__sh_wiki__fetch_page",
            toolUseId: "toolu_mcp"
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(event, continuation: continuation)
            }
        }
        await Task.yield()
        appState.approvePermission(always: true)

        let rule = try firstAlwaysAllowRule(from: await responseTask.value)
        XCTAssertEqual(rule["toolName"] as? String, "mcp__sh_wiki__fetch_page")
        XCTAssertNil(rule["ruleContent"], "MCP tool rules must not carry a specifier (#224)")
    }

    /// Non-MCP tools keep the wildcard specifier so "always allow" still applies
    /// to every future call of that tool. The #224 fix must not change them.
    func testAlwaysAllowNonMCPToolKeepsWildcardSpecifier() async throws {
        let appState = AppState()
        let event = try makePermissionEvent(
            sessionId: "s-bash-always",
            toolName: "Bash",
            toolUseId: "toolu_bash"
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(event, continuation: continuation)
            }
        }
        await Task.yield()
        appState.approvePermission(always: true)

        let rule = try firstAlwaysAllowRule(from: await responseTask.value)
        XCTAssertEqual(rule["toolName"] as? String, "Bash")
        XCTAssertEqual(rule["ruleContent"] as? String, "*")
    }

    // MARK: - Helpers

    private func firstAlwaysAllowRule(from responseData: Data) throws -> [String: Any] {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookSpecific = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecific["decision"] as? [String: Any])
        let updated = try XCTUnwrap(decision["updatedPermissions"] as? [[String: Any]])
        let first = try XCTUnwrap(updated.first)
        let rules = try XCTUnwrap(first["rules"] as? [[String: Any]])
        return try XCTUnwrap(rules.first)
    }

    private func makeHookEvent(
        name: String,
        sessionId: String,
        toolName: String?,
        toolUseId: String?,
        toolInput: [String: Any]? = nil
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": name,
            "session_id": sessionId
        ]
        if let toolName { payload["tool_name"] = toolName }
        if let toolUseId { payload["tool_use_id"] = toolUseId }
        if let toolInput { payload["tool_input"] = toolInput }
        return try makeRawHookEvent(payload)
    }

    private func makePermissionEvent(sessionId: String, toolName: String, toolUseId: String) throws -> HookEvent {
        try makeHookEvent(
            name: "PermissionRequest",
            sessionId: sessionId,
            toolName: toolName,
            toolUseId: toolUseId,
            toolInput: ["command": "echo hi"]
        )
    }

    private func makeRawHookEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("HookEvent should decode payload: \(payload)")
            throw NSError(domain: "AppStateToolUseCacheTests", code: 1)
        }
        return event
    }

    private func behavior(_ data: Data) throws -> String {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hookSpecific = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecific["decision"] as? [String: Any])
        return try XCTUnwrap(decision["behavior"] as? String)
    }
}
