import XCTest
@testable import CodeIslandCore

/// #213 — Superset spoofs TERM_PROGRAM to "kitty" and strips __CFBundleIdentifier,
/// so its own SUPERSET_* env vars are the only reliable identity signal. These
/// must be captured into the session and override the spoofed terminal name.
final class SupersetEnvCaptureTests: XCTestCase {

    private func makeEvent(_ payload: [String: Any]) -> HookEvent {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return HookEvent(from: data)!
    }

    func testSessionStartCapturesSupersetWorkspaceAndPane() {
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-superset",
            "_superset_workspace_id": "ws-abc",
            "_superset_pane_id": "pane-1",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-superset"]?.supersetWorkspaceId, "ws-abc")
        XCTAssertEqual(sessions["sess-superset"]?.supersetPaneId, "pane-1")
    }

    func testNonSessionStartEventStillCapturesSupersetFields() {
        let event = makeEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "sess-superset-2",
            "_superset_workspace_id": "ws-xyz",
        ])

        var sessions: [String: SessionSnapshot] = ["sess-superset-2": SessionSnapshot()]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-superset-2"]?.supersetWorkspaceId, "ws-xyz")
    }

    func testSupersetCapturedFromEnvSubObject() {
        // Direct-plugin payload shape: SUPERSET_* arrives inside the `_env` sub-object.
        // SUPERSET_TERMINAL_ID is an accepted alias for the pane id.
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-superset-env",
            "_env": [
                "SUPERSET_WORKSPACE_ID": "ws-env",
                "SUPERSET_TERMINAL_ID": "term-7",
            ],
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-superset-env"]?.supersetWorkspaceId, "ws-env")
        XCTAssertEqual(sessions["sess-superset-env"]?.supersetPaneId, "term-7")
    }

    func testEmptySupersetStringsAreNotStored() {
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-superset-empty",
            "_superset_workspace_id": "",
            "_superset_pane_id": "",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertNil(sessions["sess-superset-empty"]?.supersetWorkspaceId)
        XCTAssertNil(sessions["sess-superset-empty"]?.supersetPaneId)
    }

    func testSupersetTerminalNameOverridesSpoofedKittyTermProgram() {
        // ROOT BUG (#213): Superset spoofs TERM_PROGRAM=kitty and strips __CFBundleIdentifier.
        // Without the SUPERSET_* override the tag would read "Kitty"; with it, the session must
        // label as "Superset" so the user (and the activator's display) sees the right terminal.
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-superset-name",
            "_term_app": "kitty",
            "_superset_workspace_id": "ws-name",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-superset-name"]?.termApp, "kitty")
        XCTAssertEqual(sessions["sess-superset-name"]?.terminalName, "Superset")
    }
}
