import XCTest
@testable import CodeIslandCore

/// Otty sets TERM_PROGRAM=otty and __CFBundleIdentifier=io.appmakes.otty, both of
/// which the bridge captures generically. These tests pin the identity resolution
/// the activator relies on to route an Otty session to its control-CLI handler.
final class OttyEnvCaptureTests: XCTestCase {

    private func makeEvent(_ payload: [String: Any]) -> HookEvent {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return HookEvent(from: data)!
    }

    func testOttyIdentifiedByBundleId() {
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-otty-bundle",
            "_term_app": "otty",
            "_term_bundle": "io.appmakes.otty",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-otty-bundle"]?.termBundleId, "io.appmakes.otty")
        XCTAssertEqual(sessions["sess-otty-bundle"]?.terminalName, "Otty")
    }

    func testOttyPaneIdCapturedAtSessionStart() {
        // The bridge resolves the focused pane id at SessionStart and forwards it as
        // `_otty_pane_id`; the activator uses it for a precise `pane focus` jump.
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-otty-pane",
            "_term_bundle": "io.appmakes.otty",
            "_otty_pane_id": "p_19ef43979c3_6",
            "cwd": "/Users/shinya/proj",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-otty-pane"]?.ottyPaneId, "p_19ef43979c3_6")
    }

    func testOttyPaneIdCapturedOnNonSessionStartEvent() {
        // Mid-session events should also carry the pane id through if present.
        let event = makeEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "sess-otty-pane-2",
            "_otty_pane_id": "p_abc_1",
        ])

        var sessions: [String: SessionSnapshot] = ["sess-otty-pane-2": SessionSnapshot()]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-otty-pane-2"]?.ottyPaneId, "p_abc_1")
    }

    func testOttyIdentifiedByTermProgramFallback() {
        // When __CFBundleIdentifier is absent, TERM_PROGRAM=otty still labels correctly.
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-otty-term",
            "_term_app": "otty",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-otty-term"]?.terminalName, "Otty")
    }
}
