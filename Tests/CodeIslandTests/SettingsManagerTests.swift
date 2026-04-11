import XCTest
@testable import CodeIsland

@MainActor
final class SettingsManagerTests: XCTestCase {
    func testExpandedUsageDisplayMigratesLegacyClaudeFlag() {
        let fixture = makeDefaults(name: #function)
        let defaults = fixture.defaults
        defaults.set(true, forKey: SettingsKey.showUsageInfo)
        defaults.set(false, forKey: SettingsKey.showCodexUsageInfo)

        let manager = SettingsManager(defaults: defaults, persistentDomainName: fixture.suiteName)

        XCTAssertEqual(manager.expandedUsageDisplay, .claude)
        XCTAssertEqual(defaults.string(forKey: SettingsKey.expandedUsageDisplay), ExpandedUsageDisplayMode.claude.rawValue)
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.showUsageInfo))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.showCodexUsageInfo))
    }

    func testExpandedUsageDisplayMigratesLegacyCodexFlag() {
        let fixture = makeDefaults(name: #function)
        let defaults = fixture.defaults
        defaults.set(false, forKey: SettingsKey.showUsageInfo)
        defaults.set(true, forKey: SettingsKey.showCodexUsageInfo)

        let manager = SettingsManager(defaults: defaults, persistentDomainName: fixture.suiteName)

        XCTAssertEqual(manager.expandedUsageDisplay, .codex)
        XCTAssertEqual(defaults.string(forKey: SettingsKey.expandedUsageDisplay), ExpandedUsageDisplayMode.codex.rawValue)
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.showUsageInfo))
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.showCodexUsageInfo))
    }

    func testExpandedUsageDisplayDefaultsToNoneWithoutLegacyFlags() {
        let fixture = makeDefaults(name: #function)
        let defaults = fixture.defaults

        let manager = SettingsManager(defaults: defaults, persistentDomainName: fixture.suiteName)

        XCTAssertEqual(manager.expandedUsageDisplay, .none)
        XCTAssertEqual(defaults.string(forKey: SettingsKey.expandedUsageDisplay), ExpandedUsageDisplayMode.none.rawValue)
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.showUsageInfo))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.showCodexUsageInfo))
    }

    func testExpandedUsageDisplaySetterSyncsLegacyFlags() {
        let fixture = makeDefaults(name: #function)
        let defaults = fixture.defaults
        let manager = SettingsManager(defaults: defaults, persistentDomainName: fixture.suiteName)

        manager.expandedUsageDisplay = .codex
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.showUsageInfo))
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.showCodexUsageInfo))

        manager.expandedUsageDisplay = .claude
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.showUsageInfo))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.showCodexUsageInfo))

        manager.expandedUsageDisplay = .none
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.showUsageInfo))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.showCodexUsageInfo))
    }

    private func makeDefaults(name: String) -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "SettingsManagerTests.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
