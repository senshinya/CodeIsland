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
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    @AppStorage(SettingsKey.maxPanelHeight) private var maxPanelHeight = SettingsDefaults.maxPanelHeight

    private var fontSize: CGFloat { CGFloat(contentFontSize) }
    private let accent = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 0.5)
                .padding(.horizontal, 10)

            if isLoading {
                Spacer()
                Text(L10n.shared["chat_loading"])
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
                Spacer()
            } else if messages.isEmpty {
                Spacer()
                Text(L10n.shared["chat_empty"])
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.2))
                Spacer()
            } else {
                messageList
            }

            if session.isClaude, canSendMessage {
                inputBar
            }
        }
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
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                    Text(session.sessionLabel ?? session.projectDisplayName)
                        .font(.system(size: fontSize + 1, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
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
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(messages) { msg in
                        messageRow(msg)
                    }
                    Color.clear.frame(height: 1).id("chat_bottom")
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)
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

    // MARK: - Message Rows

    @ViewBuilder
    private func messageRow(_ msg: SessionChatMessage) -> some View {
        switch msg.role {
        case .user:
            userRow(msg.text)
        case .assistant:
            assistantRow(msg.text)
        case .tool:
            toolRow(msg.text)
        }
    }

    /// User message — right-aligned dark bubble
    private func userRow(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 50)
            Text(text)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.trailing)
                .lineLimit(nil)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.10))
                )
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// Assistant message — left-aligned with ◇ marker
    private func assistantRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("◇")
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .foregroundStyle(accent.opacity(0.65))
            Text(renderMarkdown(chatStripDirectives(text)))
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(nil)
                .textSelection(.enabled)
            Spacer(minLength: 16)
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    /// Tool call — compact muted row
    private func toolRow(_ text: String) -> some View {
        HStack(spacing: 5) {
            Text("▸")
                .font(.system(size: fontSize - 2, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.2))
            Text(text)
                .font(.system(size: fontSize - 1.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, 20)
        .padding(.vertical, 1)
    }

    // MARK: - Input Bar

    private var canSendMessage: Bool {
        session.ttyPath != nil || session.tmuxPane != nil || (session.cliPid ?? 0) > 0
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 0.5)

            ChatInputEditor(
                text: $messageInput,
                font: .monospacedSystemFont(ofSize: fontSize, weight: .regular),
                placeholderText: L10n.shared["chat_placeholder"],
                onSubmit: sendMessage
            )
            .frame(minHeight: 28, maxHeight: 80)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
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
}

// MARK: - Chat Input Editor (NSTextView wrapper)

/// Multi-line text input: Enter sends, Shift+Enter inserts newline.
private struct ChatInputEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var placeholderText: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.font = font
        textView.textColor = .white
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.insertionPointColor = .white.withAlphaComponent(0.7)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.string = text

        // Placeholder
        let placeholder = NSAttributedString(
            string: placeholderText,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.2),
                .font: font,
            ]
        )
        context.coordinator.placeholderAttr = placeholder
        context.coordinator.textView = textView
        context.coordinator.updatePlaceholder()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
            context.coordinator.updatePlaceholder()
        }
        context.coordinator.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputEditor
        var onSubmit: (() -> Void)?
        var placeholderAttr: NSAttributedString?
        weak var textView: NSTextView?
        private var placeholderView: NSTextField?

        init(_ parent: ChatInputEditor) {
            self.parent = parent
            self.onSubmit = parent.onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            updatePlaceholder()
        }

        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                onSubmit?()
                return true
            }
            return false
        }

        func updatePlaceholder() {
            guard let tv = textView else { return }
            if placeholderView == nil {
                let label = NSTextField(labelWithString: "")
                label.isEditable = false
                label.isBordered = false
                label.drawsBackground = false
                label.attributedStringValue = placeholderAttr ?? NSAttributedString()
                label.translatesAutoresizingMaskIntoConstraints = false
                tv.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: 9),
                    label.topAnchor.constraint(equalTo: tv.topAnchor, constant: 4),
                ])
                placeholderView = label
            }
            placeholderView?.isHidden = !tv.string.isEmpty
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

        let tty = resolveRealTTY(session: session)
        if let tty, !tty.isEmpty {
            sendViaTTY(text, tty: tty)
        }
    }

    private static func resolveRealTTY(session: SessionSnapshot) -> String? {
        if let tty = session.ttyPath, !tty.isEmpty, tty != "/dev/tty" {
            return tty
        }
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
