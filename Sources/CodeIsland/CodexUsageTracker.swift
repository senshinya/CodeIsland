import Foundation
import os.log

@MainActor
final class CodexUsageTracker: ObservableObject {
    static let shared = CodexUsageTracker()
    private static let log = Logger(subsystem: "com.codeisland", category: "CodexUsageTracker")

    struct UsageWindow {
        var label: String
        var utilization: Double
        var resetsAt: Date
    }

    struct UsageData {
        var primary: UsageWindow?
        var secondary: UsageWindow?
        var planType: String = ""
        var fetchedAt: Date = .distantPast
    }

    @Published var data = UsageData()
    @Published var isAvailable = false

    private let authPath = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/auth.json")
    private var fetchTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private let cacheDuration: TimeInterval = 180

    private init() {}

    func startPolling() {
        Self.log.info("startPolling codex usage")
        fetch()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: cacheDuration, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetch() }
        }
    }

    func stopPolling() {
        Self.log.info("stopPolling")
        refreshTimer?.invalidate()
        refreshTimer = nil
        fetchTask?.cancel()
    }

    func fetch() {
        if Date().timeIntervalSince(data.fetchedAt) < 30 { return }

        fetchTask?.cancel()
        fetchTask = Task {
            do {
                let usage = try await Self.fetchUsage(authPath: authPath)
                if !Task.isCancelled {
                    data = usage
                    isAvailable = usage.primary != nil || usage.secondary != nil
                }
            } catch {
                Self.log.error("Usage fetch failed: \(error.localizedDescription, privacy: .public)")
                if !Task.isCancelled {
                    isAvailable = false
                }
            }
        }
    }

    private static func fetchUsage(authPath: URL) async throws -> UsageData {
        var auth = try readAuthFile(at: authPath)
        guard auth.authMode == "chatgpt",
              let refreshToken = auth.tokens.refreshToken else {
            throw URLError(.userAuthenticationRequired)
        }

        var accessToken = auth.tokens.accessToken
        var accountId = auth.tokens.accountId ?? extractAccountId(from: accessToken)

        if isExpired(accessToken) {
            let refreshed = try await refreshAccessToken(refreshToken: refreshToken)
            auth.tokens.accessToken = refreshed.accessToken
            if let refreshToken = refreshed.refreshToken { auth.tokens.refreshToken = refreshToken }
            if let idToken = refreshed.idToken { auth.tokens.idToken = idToken }
            auth.lastRefresh = ISO8601DateFormatter().string(from: Date())
            try saveAuthFile(auth, to: authPath)
            accessToken = refreshed.accessToken
            if accountId == nil {
                accountId = extractAccountId(from: accessToken)
            }
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.timeoutInterval = 15

        var (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            let refreshed = try await refreshAccessToken(refreshToken: refreshToken)
            auth.tokens.accessToken = refreshed.accessToken
            if let refreshToken = refreshed.refreshToken { auth.tokens.refreshToken = refreshToken }
            if let idToken = refreshed.idToken { auth.tokens.idToken = idToken }
            auth.lastRefresh = ISO8601DateFormatter().string(from: Date())
            try saveAuthFile(auth, to: authPath)

            request.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
            if accountId == nil {
                accountId = extractAccountId(from: refreshed.accessToken)
                if let accountId, !accountId.isEmpty {
                    request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
                }
            }
            let retried = try await URLSession.shared.data(for: request)
            data = retried.0
            response = retried.1
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        let planType = json["plan_type"] as? String ?? ""
        let rateLimit = json["rate_limit"] as? [String: Any] ?? [:]
        let primary = parseWindow(data: rateLimit["primary_window"] as? [String: Any], fallbackLabel: "5h")
        let secondary = parseWindow(data: rateLimit["secondary_window"] as? [String: Any], fallbackLabel: "7d")
        return UsageData(primary: primary, secondary: secondary, planType: planType, fetchedAt: Date())
    }

    private static func parseWindow(data: [String: Any]?, fallbackLabel: String) -> UsageWindow? {
        guard let data else { return nil }
        let used = data["used_percent"] as? Double ?? Double(data["used_percent"] as? Int ?? 0)
        let limitWindow = data["limit_window_seconds"] as? Int ?? 0
        let resetAt = data["reset_at"] as? TimeInterval ?? TimeInterval(data["reset_at"] as? Int ?? 0)
        let label = windowLabel(seconds: limitWindow, fallback: fallbackLabel)
        let resetDate = resetAt > 0 ? Date(timeIntervalSince1970: resetAt) : .distantPast
        return UsageWindow(label: label, utilization: used, resetsAt: resetDate)
    }

    private static func windowLabel(seconds: Int, fallback: String) -> String {
        guard seconds > 0 else { return fallback }
        if seconds % 86_400 == 0 {
            let days = seconds / 86_400
            return days == 7 ? "7d" : "\(days)d"
        }
        if seconds % 3_600 == 0 {
            return "\(seconds / 3_600)h"
        }
        return "\(seconds / 60)m"
    }

    private static func isExpired(_ token: String) -> Bool {
        guard let exp = decodeJWT(token)["exp"] as? TimeInterval else { return false }
        return Date().timeIntervalSince1970 >= exp - 60
    }

    private static func extractAccountId(from token: String) -> String? {
        let payload = decodeJWT(token)
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        return auth?["chatgpt_account_id"] as? String
    }

    private static func refreshAccessToken(refreshToken: String) async throws -> RefreshResponse {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(percentEncode(refreshToken))",
            "client_id=app_EMoamEEZ73f0CkXaXp7hrann",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.userAuthenticationRequired)
        }
        let decoder = JSONDecoder()
        return try decoder.decode(RefreshResponse.self, from: data)
    }

    private static func percentEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? string
    }

    private static func decodeJWT(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var payload = String(parts[1])
        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private static func readAuthFile(at url: URL) throws -> CodexAuthFile {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CodexAuthFile.self, from: data)
    }

    private static func saveAuthFile(_ auth: CodexAuthFile, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(auth)
        try data.write(to: url, options: .atomic)
    }
}

private struct CodexAuthFile: Codable {
    var authMode: String
    var openAIAPIKey: String?
    var tokens: CodexAuthTokens
    var lastRefresh: String?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case openAIAPIKey = "OPENAI_API_KEY"
        case tokens
        case lastRefresh = "last_refresh"
    }
}

private struct CodexAuthTokens: Codable {
    var idToken: String?
    var accessToken: String
    var refreshToken: String?
    var accountId: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountId = "account_id"
    }
}

private struct RefreshResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
    }
}
