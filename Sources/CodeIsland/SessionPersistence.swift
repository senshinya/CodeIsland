import Foundation
import CodeIslandCore

struct PersistedSession: Codable {
    let sessionId: String
    let cwd: String?
    let source: String
    let model: String?
    let sessionTitle: String?
    let sessionTitleSource: SessionTitleSource?
    let providerSessionId: String?
    let transcriptPath: String?
    let lastUserPrompt: String?
    let lastAssistantMessage: String?
    let termApp: String?
    let itermSessionId: String?
    let ttyPath: String?
    let kittyWindowId: String?
    let tmuxPane: String?
    let tmuxClientTty: String?
    let tmuxEnv: String?
    let termBundleId: String?
    let cliPid: Int32?
    let cliStartTime: Date?
    let startTime: Date
    let lastActivity: Date
}

enum SessionPersistence {
    private static let dirPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.codeisland"
    private static let filePath = dirPath + "/sessions.json"

    static func save(_ sessions: [String: SessionSnapshot]) {
        let persisted = sessions.map { (id, s) in
            PersistedSession(
                sessionId: id,
                cwd: s.cwd,
                source: s.source,
                model: s.model,
                sessionTitle: s.sessionTitle,
                sessionTitleSource: s.sessionTitleSource,
                providerSessionId: s.providerSessionId,
                transcriptPath: resolvedTranscriptPath(sessionId: id, session: s),
                lastUserPrompt: s.lastUserPrompt,
                lastAssistantMessage: s.lastAssistantMessage,
                termApp: s.termApp,
                itermSessionId: s.itermSessionId,
                ttyPath: s.ttyPath,
                kittyWindowId: s.kittyWindowId,
                tmuxPane: s.tmuxPane,
                tmuxClientTty: s.tmuxClientTty,
                tmuxEnv: s.tmuxEnv,
                termBundleId: s.termBundleId,
                cliPid: s.cliPid,
                cliStartTime: s.cliStartTime,
                startTime: s.startTime,
                lastActivity: s.lastActivity
            )
        }
        do {
            try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(persisted)
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch {}
    }

    static func load() -> [PersistedSession] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PersistedSession].self, from: data)) ?? []
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: filePath)
    }

    private static func resolvedTranscriptPath(sessionId: String, session: SessionSnapshot) -> String? {
        if let path = session.transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            return path
        }

        guard session.source == "codex" else { return nil }
        let effectiveSessionId: String
        if let providerSessionId = session.providerSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !providerSessionId.isEmpty {
            effectiveSessionId = providerSessionId
        } else {
            effectiveSessionId = sessionId
        }

        return CodexSessionReader.transcriptPath(
            sessionId: effectiveSessionId,
            cwd: session.cwd,
            processStart: session.cliStartTime
        )
    }
}
