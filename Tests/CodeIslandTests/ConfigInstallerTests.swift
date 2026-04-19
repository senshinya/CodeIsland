import XCTest
@testable import CodeIsland

final class ConfigInstallerTests: XCTestCase {
    override func tearDown() {
        ConfigInstaller.setClaudeVersionOverride(nil)
        super.tearDown()
    }

    func testAllCLIsOnlyExposeClaudeAndCodex() {
        XCTAssertEqual(ConfigInstaller.allCLIs.map(\.source), ["claude", "codex"])
    }

    func testCodexHooksIncludeSessionEnd() throws {
        let codex = try XCTUnwrap(ConfigInstaller.allCLIs.first(where: { $0.source == "codex" }))
        XCTAssertEqual(codex.events.map(\.0), [
            "SessionStart",
            "SessionEnd",
            "UserPromptSubmit",
            "PreToolUse",
            "PostToolUse",
            "Stop",
        ])
    }

    func testRemoveManagedHookEntriesAlsoPrunesLegacyVibeIslandHooks() throws {
        let hooks: [String: Any] = [
            "SessionEnd": [
                [
                    "hooks": [
                        [
                            "command": "/Users/test/.vibe-island/bin/vibe-island-bridge --source claude",
                            "type": "command",
                        ],
                    ],
                ],
                [
                    "matcher": "",
                    "hooks": [
                        [
                            "command": "~/.claude/hooks/codeisland-hook.sh",
                            "timeout": 5,
                            "type": "command",
                        ],
                    ],
                ],
                [
                    "matcher": "",
                    "hooks": [
                        [
                            "command": "~/.codeisland/codeisland-hook.sh",
                            "timeout": 5,
                            "type": "command",
                        ],
                    ],
                ],
                [
                    "matcher": "",
                    "hooks": [
                        [
                            "async": true,
                            "command": "~/.claude/hooks/bark-notify.sh",
                            "timeout": 10,
                            "type": "command",
                        ],
                    ],
                ],
            ],
        ]

        let cleaned = ConfigInstaller.removeManagedHookEntries(from: hooks)
        let sessionEnd = try XCTUnwrap(cleaned["SessionEnd"] as? [[String: Any]])

        XCTAssertEqual(sessionEnd.count, 1)
        let remainingHooks = try XCTUnwrap(sessionEnd.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(remainingHooks.count, 1)
        XCTAssertEqual(remainingHooks.first?["command"] as? String, "~/.claude/hooks/bark-notify.sh")
    }

    func testCompatibleEventsDropUnsupportedClaudeHooksOnOlderVersions() throws {
        let claude = try XCTUnwrap(ConfigInstaller.allCLIs.first(where: { $0.source == "claude" }))
        ConfigInstaller.setClaudeVersionOverride("2.1.88")

        XCTAssertEqual(
            ConfigInstaller.compatibleEvents(for: claude).map(\.0),
            [
                "UserPromptSubmit",
                "PreToolUse",
                "PostToolUse",
                "PermissionRequest",
                "Stop",
                "SubagentStart",
                "SubagentStop",
                "SessionStart",
                "SessionEnd",
                "Notification",
                "PreCompact",
            ]
        )
    }

    func testClaudeInstalledCheckUsesCompatibleEventsOnly() throws {
        let pathSuffix = "claude-test-\(UUID().uuidString)"
        let cli = CLIConfig(
            name: "Claude Test",
            source: "claude",
            configPath: ".codeisland-tests/\(pathSuffix)/settings.json",
            configKey: "hooks",
            format: .claude,
            events: [
                ("UserPromptSubmit", 5, true),
                ("PermissionDenied", 5, true),
                ("SessionEnd", 5, true),
            ],
            versionedEvents: [
                "PermissionDenied": "2.1.89",
            ]
        )
        ConfigInstaller.setClaudeVersionOverride("2.1.88")

        let fm = FileManager.default
        try fm.createDirectory(atPath: cli.dirPath, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: cli.dirPath) }

        let hooks: [String: Any] = [
            "UserPromptSubmit": [[
                "matcher": "",
                "hooks": [[
                    "type": "command",
                    "command": "~/.codeisland/codeisland-hook.sh",
                    "timeout": 5,
                ]],
            ]],
            "SessionEnd": [[
                "matcher": "",
                "hooks": [[
                    "type": "command",
                    "command": "~/.codeisland/codeisland-hook.sh",
                    "timeout": 5,
                ]],
            ]],
        ]
        let root: [String: Any] = ["hooks": hooks]
        let data = try XCTUnwrap(try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]))
        XCTAssertTrue(fm.createFile(atPath: cli.fullPath, contents: data))

        XCTAssertTrue(ConfigInstaller.isHooksInstalled(for: cli, fm: fm))
    }

    func testIsHooksInstalledFlagsStaleIncompatibleEntries() throws {
        // Our hook was previously written under PermissionDenied, but the
        // running Claude Code is older than that hook's min version. The check
        // must treat the file as needing repair so installClaudeHooks can
        // strip the stale entry.
        let pathSuffix = "claude-stale-\(UUID().uuidString)"
        let cli = CLIConfig(
            name: "Claude Stale",
            source: "claude",
            configPath: ".codeisland-tests/\(pathSuffix)/settings.json",
            configKey: "hooks",
            format: .claude,
            events: [
                ("UserPromptSubmit", 5, true),
                ("PermissionDenied", 5, true),
                ("SessionEnd", 5, true),
            ],
            versionedEvents: [
                "PermissionDenied": "2.1.89",
            ]
        )
        ConfigInstaller.setClaudeVersionOverride("2.1.88")

        let fm = FileManager.default
        try fm.createDirectory(atPath: cli.dirPath, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: cli.dirPath) }

        let codeislandEntry: [String: Any] = [
            "matcher": "",
            "hooks": [[
                "type": "command",
                "command": "~/.codeisland/codeisland-hook.sh",
                "timeout": 5,
            ]],
        ]
        let hooks: [String: Any] = [
            "UserPromptSubmit": [codeislandEntry],
            "SessionEnd": [codeislandEntry],
            "PermissionDenied": [codeislandEntry],
        ]
        let root: [String: Any] = ["hooks": hooks]
        let data = try XCTUnwrap(try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]))
        XCTAssertTrue(fm.createFile(atPath: cli.fullPath, contents: data))

        XCTAssertFalse(ConfigInstaller.isHooksInstalled(for: cli, fm: fm))
    }

    func testHasStaleIncompatibleEventsIgnoresForeignHooks() {
        // A third-party hook under an unsupported event is not our concern and
        // must not trigger a reinstall.
        let hooks: [String: Any] = [
            "PermissionDenied": [[
                "matcher": "",
                "hooks": [[
                    "type": "command",
                    "command": "~/.claude/hooks/someone-elses-hook.sh",
                    "timeout": 5,
                ]],
            ]],
        ]
        XCTAssertFalse(
            ConfigInstaller.hasStaleIncompatibleEvents(
                hooks,
                compatibleEvents: [("UserPromptSubmit", 5, true)]
            )
        )
    }

    func testWriteJSONPreservingUntouchedSkipsWriteOnSemanticEquality() throws {
        // Pre-existing file with distinctive formatting that our re-serializer
        // would normally clobber (escaped slashes, no trailing newline, space
        // before colon). If the parsed content matches what we'd write, we
        // must not touch the file at all.
        let tmpDir = NSTemporaryDirectory() + "codeisland-write-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmpDir) }

        let path = tmpDir + "/settings.json"
        let original = #"{"command" : "python3 \"$HOME\/hook.py\"","env" : {"KEY" : "v"}}"#
        XCTAssertTrue(fm.createFile(atPath: path, contents: Data(original.utf8)))

        let dict: [String: Any] = [
            "command": "python3 \"$HOME/hook.py\"",
            "env": ["KEY": "v"],
        ]
        XCTAssertTrue(ConfigInstaller.writeJSONPreservingUntouched(dict, at: path, fm: fm))

        let roundtrip = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(roundtrip, original, "Existing file must be left byte-for-byte untouched")
    }

    func testWriteJSONPreservingUntouchedUnescapesSlashesAndKeepsTrailingNewline() throws {
        let tmpDir = NSTemporaryDirectory() + "codeisland-write-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmpDir) }

        let path = tmpDir + "/settings.json"
        let dict: [String: Any] = [
            "command": "python3 \"$HOME/hook.py\"",
        ]
        XCTAssertTrue(ConfigInstaller.writeJSONPreservingUntouched(dict, at: path, fm: fm))

        let written = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(written.contains(#"\/"#), "Slashes must not be escaped")
        XCTAssertTrue(written.hasSuffix("\n"), "File must end with a newline")
    }
}
