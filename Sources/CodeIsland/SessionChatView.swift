import SwiftUI
import CodeIslandCore

/// Chat history view for a Claude Code session — shows messages from the JSONL transcript
/// and allows sending new messages via the session's terminal.
struct SessionChatView: View {
    let sessionId: String
    let session: SessionSnapshot
    var appState: AppState
    @State private var messages: [SessionChatMessage] = []
    @State private var messageInput = ""
    @State private var isLoading = true
    @State private var autoRefreshTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    @AppStorage(SettingsKey.maxPanelHeight) private var maxPanelHeight = SettingsDefaults.maxPanelHeight

    private var fontSize: CGFloat { CGFloat(contentFontSize) }
    private let accentOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            // Separator
            ChatLine()
                .stroke(.white.opacity(0.12), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                .frame(height: 0.5)
                .padding(.horizontal, 10)

            // Messages
            if isLoading {
                HStack {
                    Spacer()
                    Text(L10n.shared["chat_loading"])
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(accentOrange.opacity(0.6))
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if messages.isEmpty {
                HStack {
                    Spacer()
                    Text(L10n.shared["chat_empty"])
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                }
                .padding(.vertical, 20)
            } else {
                messageList
            }

            // Input bar (only for claude sessions with TTY)
            if session.isClaude, canSendMessage {
                inputBar
            }
        }
        .padding(.vertical, 6)
        .onAppear { loadMessages() }
        .onDisappear { autoRefreshTask?.cancel() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(NotchAnimation.open) {
                    appState.surface = .sessionList
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(session.sessionLabel ?? session.projectDisplayName)
                        .font(.system(size: fontSize + 1, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 4) {
                if let icon = cliIcon(source: session.source, size: 12) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 12, height: 12)
                }
                if let model = session.shortModelName {
                    Text(model)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(messages) { msg in
                        messageRow(msg)
                    }
                    // Invisible anchor at bottom
                    Color.clear.frame(height: 1).id("chat_bottom")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: chatMaxHeight)
            .onAppear {
                proxy.scrollTo("chat_bottom", anchor: .bottom)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("chat_bottom", anchor: .bottom)
                }
            }
        }
    }

    private var chatMaxHeight: CGFloat {
        let h = maxPanelHeight > 0 ? CGFloat(maxPanelHeight) : 400
        return h - 80
    }

    @ViewBuilder
    private func messageRow(_ msg: SessionChatMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(msg.text)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(nil)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white.opacity(0.12))
                    )
            }
            .padding(.vertical, 2)

        case .assistant:
            HStack(alignment: .top, spacing: 6) {
                ClaudeMiniIcon(size: 14)
                    .padding(.top, 3)
                Text(renderMarkdown(chatStripDirectives(msg.text)))
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(nil)
                    .textSelection(.enabled)
                Spacer(minLength: 20)
            }
            .padding(.vertical, 2)

        case .tool(let name):
            HStack(spacing: 4) {
                Image(systemName: toolIcon(name))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(accentOrange.opacity(0.7))
                Text(msg.text)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.04))
            )
            .padding(.leading, 20)
        }
    }

    // MARK: - Input Bar

    private var canSendMessage: Bool {
        session.ttyPath != nil || session.tmuxPane != nil || (session.cliPid ?? 0) > 0
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(L10n.shared["chat_placeholder"], text: $messageInput)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(.white)
                .focused($isFocused)
                .onSubmit { sendMessage() }

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(messageInput.isEmpty ? .white.opacity(0.2) : accentOrange)
            }
            .buttonStyle(.plain)
            .disabled(messageInput.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.05))
        .overlay(
            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(height: 0.5),
            alignment: .top
        )
    }

    // MARK: - Actions

    private func loadMessages() {
        isLoading = true
        let effectiveId = session.providerSessionId ?? sessionId
        let cwd = session.cwd
        Task.detached {
            guard let path = ClaudeSessionReader.jsonlPath(sessionId: effectiveId, cwd: cwd) else {
                await MainActor.run { isLoading = false }
                return
            }
            let parsed = ClaudeSessionReader.readMessages(at: path)
            await MainActor.run {
                messages = parsed
                isLoading = false
            }
            await startAutoRefresh(path: path)
        }
    }

    @MainActor
    private func startAutoRefresh(path: String) {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                let parsed = await Task.detached {
                    ClaudeSessionReader.readMessages(at: path)
                }.value
                if parsed.count != messages.count {
                    messages = parsed
                }
            }
        }
    }

    private func sendMessage() {
        let text = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageInput = ""
        Task.detached {
            await MessageSender.send(text, to: session)
        }
    }

    // MARK: - Helpers

    private func renderMarkdown(_ text: String) -> AttributedString {
        ChatMessageTextFormatter.inlineMarkdown(text)
    }

    private func toolIcon(_ name: String) -> String {
        switch name {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "Write": return "pencil"
        case "Grep": return "magnifyingglass"
        case "Glob": return "folder"
        case "Agent": return "person.2"
        case "WebSearch", "WebFetch": return "globe"
        default: return "wrench"
        }
    }
}

// MARK: - Message Sender

enum MessageSender {
    static func send(_ text: String, to session: SessionSnapshot) async {
        if let pane = session.tmuxPane, !pane.isEmpty {
            await sendViaTmux(text, pane: pane, tmuxEnv: session.tmuxEnv)
            return
        }

        // Resolve real TTY: hook may report "/dev/tty" (generic), look up via PID
        let tty = resolveRealTTY(session: session)
        if let tty, !tty.isEmpty {
            sendViaTTY(text, tty: tty)
        }
    }

    private static func resolveRealTTY(session: SessionSnapshot) -> String? {
        // If ttyPath is a real device (not /dev/tty), use it directly
        if let tty = session.ttyPath, !tty.isEmpty, tty != "/dev/tty" {
            return tty
        }
        // Look up real TTY from CLI process PID
        guard let pid = session.cliPid, pid > 0 else { return session.ttyPath }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "tty="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return session.ttyPath }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if output.isEmpty { return session.ttyPath }
        // ps returns e.g. "ttys000" — prepend /dev/
        let devPath = output.hasPrefix("/dev/") ? output : "/dev/\(output)"
        return devPath
    }

    private static func sendViaTmux(_ text: String, pane: String, tmuxEnv: String?) async {
        guard let tmux = findTmuxBinary() else { return }
        if let tmuxStr = tmuxEnv, let socketPath = tmuxStr.split(separator: ",").first {
            let args = ["-S", String(socketPath), "send-keys", "-t", pane, "-l", text]
            _ = try? await shellRun(tmux, args: args)
            _ = try? await shellRun(tmux, args: ["-S", String(socketPath), "send-keys", "-t", pane, "Enter"])
            return
        }
        _ = try? await shellRun(tmux, args: ["send-keys", "-t", pane, "-l", text])
        _ = try? await shellRun(tmux, args: ["send-keys", "-t", pane, "Enter"])
    }

    private static func sendViaTTY(_ text: String, tty: String) {
        guard let handle = FileHandle(forWritingAtPath: tty) else { return }
        defer { handle.closeFile() }
        // Terminal Enter key is \r (carriage return), not \n (line feed)
        if let data = (text + "\r").data(using: .utf8) {
            handle.write(data)
        }
    }

    private static func findTmuxBinary() -> String? {
        for p in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private static func shellRun(_ path: String, args: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

// MARK: - Private Views

private struct ClaudeMiniIcon: View {
    var size: CGFloat = 14
    private static let color = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        Circle()
            .fill(Self.color.opacity(0.2))
            .frame(width: size, height: size)
            .overlay(
                Text("C")
                    .font(.system(size: size * 0.55, weight: .bold, design: .monospaced))
                    .foregroundStyle(Self.color)
            )
    }
}

private struct ChatLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

// MARK: - Strip directives

private func chatStripDirectives(_ text: String) -> String {
    var result: [String] = []
    var inDirective = false
    var braceDepth = 0

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if inDirective {
            for ch in line {
                if ch == "{" { braceDepth += 1 }
                if ch == "}" { braceDepth -= 1 }
            }
            if braceDepth <= 0 {
                inDirective = false
                braceDepth = 0
            }
            continue
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("::") && trimmed.contains("{") {
            braceDepth = 0
            for ch in line {
                if ch == "{" { braceDepth += 1 }
                if ch == "}" { braceDepth -= 1 }
            }
            if braceDepth > 0 { inDirective = true }
            continue
        }
        result.append(String(line))
    }

    return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}
