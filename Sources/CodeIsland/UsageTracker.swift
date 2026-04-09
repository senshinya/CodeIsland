import Foundation
import os.log

/// Fetches and caches Claude Code usage data (5-hour and 7-day windows) from the Anthropic OAuth API.
@MainActor
final class UsageTracker: ObservableObject {
    static let shared = UsageTracker()
    private static let log = Logger(subsystem: "com.codeisland", category: "UsageTracker")

    struct UsageWindow {
        var utilization: Double = 0    // percentage 0–100
        var resetsAt: Date = .distantPast
    }

    struct UsageData {
        var fiveHour = UsageWindow()
        var sevenDay = UsageWindow()
        var fetchedAt: Date = .distantPast
    }

    @Published var data = UsageData()
    @Published var isAvailable = false

    private var fetchTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private let cacheDuration: TimeInterval = 180  // 3 minutes

    private init() {}

    func startPolling() {
        fetch()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: cacheDuration, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetch() }
        }
    }

    func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        fetchTask?.cancel()
    }

    func fetch() {
        // Skip if recently fetched
        if Date().timeIntervalSince(data.fetchedAt) < 30 { return }

        fetchTask?.cancel()
        fetchTask = Task {
            guard let token = Self.readOAuthToken() else {
                Self.log.debug("No OAuth token found")
                isAvailable = false
                return
            }
            do {
                let usage = try await Self.fetchUsage(token: token)
                if !Task.isCancelled {
                    self.data = usage
                    self.isAvailable = true
                }
            } catch {
                Self.log.error("Usage fetch failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - API

    private static func fetchUsage(token: String) async throws -> UsageData {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var usage = UsageData(fetchedAt: Date())

        if let fiveHour = json["five_hour"] as? [String: Any] {
            usage.fiveHour.utilization = fiveHour["utilization"] as? Double ?? 0
            if let resetsStr = fiveHour["resets_at"] as? String {
                usage.fiveHour.resetsAt = dateFormatter.date(from: resetsStr) ?? .distantPast
            }
        }

        if let sevenDay = json["seven_day"] as? [String: Any] {
            usage.sevenDay.utilization = sevenDay["utilization"] as? Double ?? 0
            if let resetsStr = sevenDay["resets_at"] as? String {
                usage.sevenDay.resetsAt = dateFormatter.date(from: resetsStr) ?? .distantPast
            }
        }

        return usage
    }

    // MARK: - Token

    private static func readOAuthToken() -> String? {
        // Try macOS Keychain first
        if let token = readFromKeychain() { return token }
        // Fallback: ~/.claude/.credentials.json
        return readFromCredentialsFile()
    }

    private static func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return extractAccessToken(from: str)
    }

    private static func readFromCredentialsFile() -> String? {
        let path = NSHomeDirectory() + "/.claude/.credentials.json"
        guard let data = FileManager.default.contents(atPath: path),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return extractAccessToken(from: str)
    }

    private static func extractAccessToken(from jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return token
    }

    // MARK: - Formatting Helpers

    static func formatTimeRemaining(_ target: Date) -> String {
        let remaining = target.timeIntervalSince(Date())
        if remaining <= 0 { return "0m" }

        let totalMinutes = Int(remaining / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "\(days)d\(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }
}
