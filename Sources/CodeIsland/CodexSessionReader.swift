import Foundation
import SQLite3
import CoreGraphics

/// Reads and parses Codex transcript files for chat history display.
enum CodexSessionReader {
    static func transcriptPath(sessionId: String, cwd: String?, processStart: Date?) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let statePath = "\(home)/.codex/state_5.sqlite"

        if let path: String = withSQLiteDatabase(at: statePath, body: { db in
            guard let statement = prepareStatement(
                db: db,
                sql: """
                    SELECT rollout_path
                    FROM threads
                    WHERE id = ?
                    LIMIT 1;
                    """
            ) else {
                return nil
            }
            defer { sqlite3_finalize(statement) }

            bindText(sessionId, to: statement, index: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return columnString(statement, index: 0)
        }),
           FileManager.default.fileExists(atPath: path) {
            return path
        }

        guard let cwd else { return nil }
        return bestMatchingSessionPath(
            base: "\(home)/.codex/sessions",
            cwd: cwd,
            after: processStart
        )
    }

    static func readMessages(at path: String) -> [SessionChatMessage] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        var messages: [SessionChatMessage] = []
        var seenMessageKeys: Set<String> = []
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]

        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let timestamp = parseTimestamp(json["timestamp"], fractional: dateFormatter, plain: plainFormatter)
            let type = json["type"] as? String ?? ""

            if type == "event_msg",
               let payload = json["payload"] as? [String: Any],
               let payloadType = payload["type"] as? String {
                switch payloadType {
                case "user_message":
                    guard let text = payload["message"] as? String,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }
                    append(
                        role: .user,
                        text: text,
                        timestamp: timestamp,
                        fallbackId: "codex-user-\(index)",
                        seenKeys: &seenMessageKeys,
                        into: &messages
                    )
                case "agent_message":
                    guard let text = payload["message"] as? String,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }
                    append(
                        role: .assistant,
                        text: text,
                        timestamp: timestamp,
                        fallbackId: "codex-assistant-\(index)",
                        seenKeys: &seenMessageKeys,
                        into: &messages
                    )
                default:
                    break
                }
                continue
            }

            if type == "response_item",
               let payload = json["payload"] as? [String: Any],
               let payloadType = payload["type"] as? String,
               payloadType == "function_call" {
                let name = payload["name"] as? String ?? "Tool"
                let arguments = payload["arguments"] as? String
                let summary = functionCallSummary(name: name, arguments: arguments)
                let text = summary.isEmpty ? name : "\(name): \(summary)"
                messages.append(
                    SessionChatMessage(
                        id: payload["call_id"] as? String ?? "codex-tool-\(index)",
                        role: .tool(name: name),
                        text: text,
                        timestamp: timestamp
                    )
                )
            }
        }

        return messages
    }

    private static func append(
        role: SessionChatMessage.Role,
        text: String,
        timestamp: Date,
        fallbackId: String,
        seenKeys: inout Set<String>,
        into messages: inout [SessionChatMessage]
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let roleKey: String
        switch role {
        case .user: roleKey = "user"
        case .assistant: roleKey = "assistant"
        case .tool(let name): roleKey = "tool:\(name)"
        }

        let messageKey = "\(roleKey)|\(timestamp.timeIntervalSince1970)|\(trimmed)"
        guard !seenKeys.contains(messageKey) else { return }
        seenKeys.insert(messageKey)

        messages.append(
            SessionChatMessage(
                id: fallbackId,
                role: role,
                text: trimmed,
                timestamp: timestamp
            )
        )
    }

    private static func functionCallSummary(name: String, arguments: String?) -> String {
        guard let arguments,
              let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }

        switch name {
        case "exec_command":
            return json["cmd"] as? String ?? json["command"] as? String ?? ""
        case "write_stdin":
            if let chars = json["chars"] as? String, !chars.isEmpty {
                return String(chars.prefix(60))
            }
        default:
            break
        }

        if let path = json["path"] as? String, !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        if let cmd = json["cmd"] as? String, !cmd.isEmpty {
            return String(cmd.prefix(60))
        }
        if let message = json["message"] as? String, !message.isEmpty {
            return String(message.prefix(60))
        }
        return ""
    }

    private static func parseTimestamp(
        _ raw: Any?,
        fractional: ISO8601DateFormatter,
        plain: ISO8601DateFormatter
    ) -> Date {
        if let value = raw as? String {
            if let date = fractional.date(from: value) ?? plain.date(from: value) {
                return date
            }
        }
        if let value = raw as? Double {
            return Date(timeIntervalSince1970: value / 1000.0)
        }
        if let value = raw as? Int64 {
            return Date(timeIntervalSince1970: TimeInterval(value) / 1000.0)
        }
        if let value = raw as? Int {
            return Date(timeIntervalSince1970: TimeInterval(value) / 1000.0)
        }
        return Date()
    }

    static func bestMatchingSessionPath(
        base: String,
        cwd: String,
        after: Date?,
        fileManager fm: FileManager = .default
    ) -> String? {
        if let path = findRecentSession(base: base, cwd: cwd, after: after, fileManager: fm) {
            return path
        }

        // After an app relaunch we may only have a restored session snapshot. If the
        // transcript hasn't been touched since before the current process start time, the
        // strict time filter can miss the correct file and the history panel appears empty
        // until the next message rewrites the transcript. Fall back to a cwd-only lookup.
        guard after != nil else { return nil }
        return findRecentSession(base: base, cwd: cwd, after: nil, fileManager: fm)
    }

    private static func findRecentSession(
        base: String,
        cwd: String,
        after: Date?,
        fileManager fm: FileManager
    ) -> String? {
        let calendar = Calendar.current
        let now = Date()

        var dirs: [String] = []
        for daysBack in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: -daysBack, to: now) else { continue }
            let year = String(format: "%04d", calendar.component(.year, from: date))
            let month = String(format: "%02d", calendar.component(.month, from: date))
            let day = String(format: "%02d", calendar.component(.day, from: date))
            let dir = "\(base)/\(year)/\(month)/\(day)"
            if fm.fileExists(atPath: dir) {
                dirs.append(dir)
            }
        }

        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }.sorted(by: >)

            for file in jsonlFiles.prefix(20) {
                let fullPath = "\(dir)/\(file)"
                if let after,
                   let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let modified = attrs[.modificationDate] as? Date,
                   modified < after.addingTimeInterval(-10) {
                    continue
                }
                if sessionMatchesCwd(path: fullPath, cwd: cwd) {
                    return fullPath
                }
            }
        }

        return nil
    }

    private static func sessionMatchesCwd(path: String, cwd: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 4096)
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.components(separatedBy: "\n").first,
              let lineData = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let sessionCwd = payload["cwd"] as? String else {
            return false
        }

        return sessionCwd == cwd
    }

    private static func withSQLiteDatabase<T>(at path: String, body: (OpaquePointer) -> T?) -> T? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close_v2(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 1000)
        defer { sqlite3_close_v2(db) }
        return body(db)
    }

    private static func prepareStatement(db: OpaquePointer, sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        return statement
    }

    private static func bindText(_ text: String, to statement: OpaquePointer, index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = text.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
    }

    private static func columnString(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: UnsafeRawPointer(value).assumingMemoryBound(to: CChar.self))
    }
}
