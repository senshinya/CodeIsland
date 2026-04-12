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
}
