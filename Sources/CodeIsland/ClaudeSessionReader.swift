import Foundation
import CodeIslandCore

/// Parsed message from a Claude Code JSONL session file
struct SessionChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
        case tool(name: String)
    }

    let id: String
    let role: Role
    let text: String
    let timestamp: Date

    var isUser: Bool {
        if case .user = role { return true }
        return false
    }

    var isAssistant: Bool {
        if case .assistant = role { return true }
        return false
    }
}

/// Reads and parses Claude Code JSONL session files
enum ClaudeSessionReader {
    /// Find the JSONL file path for a session given its ID and cwd
    static func jsonlPath(sessionId: String, cwd: String?) -> String? {
        guard let cwd else { return nil }
        let projectDir = cwd.claudeProjectDirEncoded()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/.claude/projects/\(projectDir)/\(sessionId).jsonl"
        if FileManager.default.fileExists(atPath: path) { return path }
        return nil
    }

    /// Parse all displayable messages from a JSONL file
    static func readMessages(at path: String) -> [SessionChatMessage] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var messages: [SessionChatMessage] = []
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            let type = json["type"] as? String ?? ""
            let isMeta = json["isMeta"] as? Bool ?? false
            let isSidechain = json["isSidechain"] as? Bool ?? false
            let uuid = json["uuid"] as? String ?? UUID().uuidString
            let timestampStr = json["timestamp"] as? String ?? ""
            let timestamp = dateFormatter.date(from: timestampStr) ?? Date()

            // Skip meta messages, sidechains, and non-message types
            if isMeta || isSidechain { continue }

            switch type {
            case "user":
                guard let message = json["message"] as? [String: Any],
                      let role = message["role"] as? String, role == "user" else { continue }
                let content = message["content"]

                // Skip tool_result messages (they contain tool outputs, not user text)
                if let contentArray = content as? [[String: Any]],
                   contentArray.first?["type"] as? String == "tool_result" { continue }
                if let contentStr = content as? String {
                    // Skip command messages and system injections
                    if contentStr.contains("<command-name>") || contentStr.contains("<local-command") { continue }
                    if contentStr.contains("<task-notification>") || contentStr.contains("<task_notification>") { continue }
                    // Skip system-reminder only messages
                    if contentStr.hasPrefix("<system-reminder>") && !contentStr.contains("</system-reminder>\n") { continue }

                    let cleaned = stripXMLTags(contentStr)
                    if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    messages.append(SessionChatMessage(id: uuid, role: .user, text: cleaned, timestamp: timestamp))
                } else if let contentArray = content as? [[String: Any]] {
                    // Multi-part content: extract text blocks
                    var texts: [String] = []
                    for block in contentArray {
                        if let blockType = block["type"] as? String, blockType == "text",
                           let blockText = block["text"] as? String {
                            let cleaned = stripXMLTags(blockText)
                            if !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                texts.append(cleaned)
                            }
                        }
                    }
                    if !texts.isEmpty {
                        messages.append(SessionChatMessage(id: uuid, role: .user, text: texts.joined(separator: "\n"), timestamp: timestamp))
                    }
                }

            case "assistant":
                guard let message = json["message"] as? [String: Any],
                      let role = message["role"] as? String, role == "assistant",
                      let content = message["content"] as? [[String: Any]] else { continue }

                // Extract text blocks (skip thinking and tool_use)
                var texts: [String] = []
                var toolCalls: [(name: String, desc: String?)] = []

                for block in content {
                    let blockType = block["type"] as? String ?? ""
                    switch blockType {
                    case "text":
                        if let t = block["text"] as? String,
                           !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            texts.append(t)
                        }
                    case "tool_use":
                        let name = block["name"] as? String ?? "Unknown"
                        let input = block["input"] as? [String: Any]
                        let desc = toolDescription(name: name, input: input)
                        toolCalls.append((name: name, desc: desc))
                    default:
                        break
                    }
                }

                // Add text message if present
                if !texts.isEmpty {
                    messages.append(SessionChatMessage(id: uuid, role: .assistant, text: texts.joined(separator: "\n"), timestamp: timestamp))
                }

                // Add tool calls as separate entries
                for (i, tool) in toolCalls.enumerated() {
                    let toolText = tool.desc != nil ? "\(tool.name): \(tool.desc!)" : tool.name
                    messages.append(SessionChatMessage(
                        id: "\(uuid)-tool-\(i)",
                        role: .tool(name: tool.name),
                        text: toolText,
                        timestamp: timestamp
                    ))
                }

            default:
                continue
            }
        }

        return messages
    }

    /// Strip XML/HTML-like tags from text
    private static func stripXMLTags(_ text: String) -> String {
        // Remove common Claude Code XML wrappers
        var result = text
        let patterns = [
            "<system-reminder>[\\s\\S]*?</system-reminder>",
            "<local-command-caveat>[\\s\\S]*?</local-command-caveat>",
            "<command-name>[\\s\\S]*?</command-name>",
            "<command-message>[\\s\\S]*?</command-message>",
            "<command-args>[\\s\\S]*?</command-args>",
            "<local-command-stdout>[\\s\\S]*?</local-command-stdout>",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Generate a short description for a tool call
    private static func toolDescription(name: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        switch name {
        case "Bash":
            if let desc = input["description"] as? String, !desc.isEmpty { return desc }
            if let cmd = input["command"] as? String {
                let line = cmd.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? cmd
                return String(line.prefix(60))
            }
        case "Read":
            if let fp = input["file_path"] as? String { return (fp as NSString).lastPathComponent }
        case "Edit":
            if let fp = input["file_path"] as? String { return (fp as NSString).lastPathComponent }
        case "Write":
            if let fp = input["file_path"] as? String { return (fp as NSString).lastPathComponent }
        case "Grep":
            if let p = input["pattern"] as? String { return p }
        case "Glob":
            if let p = input["pattern"] as? String { return p }
        case "Agent":
            if let d = input["description"] as? String { return d }
        default:
            if let fp = input["file_path"] as? String { return (fp as NSString).lastPathComponent }
        }
        return nil
    }
}
