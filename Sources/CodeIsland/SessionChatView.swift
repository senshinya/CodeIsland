import SwiftUI
import CodeIslandCore
import Darwin

/// Chat history view for a supported CLI session.
struct SessionChatView: View {
    let sessionId: String
    let session: SessionSnapshot
    var appState: AppState
    @State private var messages: [SessionChatMessage] = []
    @State private var pendingUserMessages: [SessionChatMessage] = []
    @State private var messageInput = ""
    @State private var isLoading = true
    @State private var inputFocusRequest = 0
    @State private var fileWatchSource: DispatchSourceFileSystemObject?
    @State private var watchedFileDescriptor: Int32 = -1
    @State private var watchedTranscriptPath: String?
    @State private var watcherReloadTask: Task<Void, Never>?
    @State private var transcriptDiscoveryTask: Task<Void, Never>?
    @State private var scrollToBottomTask: Task<Void, Never>?
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    @AppStorage(SettingsKey.maxPanelHeight) private var maxPanelHeight = SettingsDefaults.maxPanelHeight

    private var fontSize: CGFloat { CGFloat(contentFontSize) }
    private let accent = Color(red: 0.85, green: 0.47, blue: 0.34)
    private let toolGreen = Color(red: 0.40, green: 0.88, blue: 0.62)
    private var displayedMessages: [SessionChatMessage] { messages + pendingUserMessages }
    private var visibleMessages: [SessionChatMessage] {
        let limit = session.source == "codex" ? 240 : 400
        if displayedMessages.count > limit {
            return Array(displayedMessages.suffix(limit))
        }
        return displayedMessages
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            if isLoading {
                Spacer()
                Text(L10n.shared["chat_loading"])
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
                Spacer()
            } else if displayedMessages.isEmpty {
                Spacer()
                Text(L10n.shared["chat_empty"])
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.2))
                Spacer()
            } else {
                messageList
            }

            if canShowInputBar {
                inputBar
            }
        }
        .onAppear { loadMessages() }
        .onDisappear { stopWatchingTranscript() }
        .onChange(of: session.providerSessionId) { _, _ in
            refreshTranscriptBindingIfNeeded()
        }
        .onChange(of: session.cwd) { _, _ in
            refreshTranscriptBindingIfNeeded()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        ZStack {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                    Text(session.sessionLabel ?? session.projectDisplayName)
                        .font(.system(size: fontSize + 2, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    if let icon = cliIcon(source: session.source, size: 13) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 13, height: 13)
                    }
                    if let model = session.shortModelName {
                        Text(model)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                }
            }
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                colors: [
                    .white.opacity(0.02),
                    .white.opacity(0.008),
                    .clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.white.opacity(0.055))
                    .frame(height: 0.5)
                    .padding(.horizontal, 10)
            }
        )
        .zIndex(2)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleMessages) { msg in
                        messageRow(msg)
                            .id(msg.id)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                    Color.clear.frame(height: 1).id("chat_bottom")
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            .textSelection(.disabled)
            .frame(maxHeight: chatMaxHeight)
            .onAppear {
                scrollToBottom(with: proxy)
            }
            .onChange(of: visibleMessages) { _, _ in
                scrollToBottom(with: proxy)
            }
        }
    }

    private func scrollToBottom(with proxy: ScrollViewProxy) {
        scrollToBottomTask?.cancel()
        scrollToBottomTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(75))
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo("chat_bottom", anchor: .bottom)
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
        case .tool(let name):
            toolRow(msg.text, name: name)
        }
    }

    /// User message — right-aligned bubble, width fits content, max ~container-50
    private func userRow(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 72)
            Text(text)
                .font(.system(size: fontSize + 1, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.94))
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.white.opacity(0.13))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                        )
                )
                .frame(maxWidth: 520, alignment: .trailing)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// Assistant message — left-aligned with ● marker
    private func assistantRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("●")
                .font(.system(size: max(7, fontSize * 0.62), weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
                .padding(.top, 4)
            Text(renderMarkdown(chatStripDirectives(text)))
                .font(.system(size: fontSize + 2, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(nil)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// Tool call — same level as assistant, bold tool name
    private func toolRow(_ text: String, name: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("●")
                .font(.system(size: max(7, fontSize * 0.62), weight: .regular, design: .monospaced))
                .foregroundStyle(toolGreen)
                .padding(.top, 3)
            toolText(text, name: name)
            Spacer(minLength: 16)
        }
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    /// Renders tool text with bold name prefix
    private func toolText(_ text: String, name: String) -> Text {
        let desc = String(text.dropFirst(name.count).drop(while: { $0 == ":" || $0 == " " }))
        return Text(name)
            .font(.system(size: fontSize + 1, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.96))
        +
        Text(desc.isEmpty ? "" : " " + desc)
            .font(.system(size: fontSize + 1, weight: .regular, design: .monospaced))
            .foregroundColor(.white.opacity(0.48))
    }

    // MARK: - Input Bar

    private var canSendMessage: Bool {
        guard let pane = session.tmuxPane?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !pane.isEmpty
    }

    private var canShowInputBar: Bool {
        session.isClaude && canSendMessage
    }

    private var hasVisibleSessionHistory: Bool {
        !session.recentMessages.isEmpty
            || !(session.lastUserPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(session.lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var inputBar: some View {
        ChatInputEditor(
            text: $messageInput,
            font: .monospacedSystemFont(ofSize: fontSize + 1, weight: .regular),
            placeholderText: L10n.shared["chat_placeholder"],
            focusRequest: inputFocusRequest,
            onSubmit: sendMessage
        )
        .frame(height: 24)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1.2)
                )
        )
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            inputFocusRequest += 1
        }
        .onHover { _ in }
    }

    // MARK: - Actions

    private var effectiveTranscriptPath: String? {
        switch session.source {
        case "claude":
            return ClaudeSessionReader.jsonlPath(sessionId: preferredTranscriptSessionId, cwd: session.cwd)
        case "codex":
            return CodexSessionReader.transcriptPath(
                sessionId: preferredTranscriptSessionId,
                cwd: session.cwd,
                processStart: session.cliStartTime
            )
        default:
            return nil
        }
    }

    private var preferredTranscriptSessionId: String {
        guard let providerSessionId = session.providerSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerSessionId.isEmpty else {
            return sessionId
        }

        guard session.isClaude, providerSessionId != sessionId, !hasVisibleSessionHistory else {
            return providerSessionId
        }

        guard let path = ClaudeSessionReader.jsonlPath(sessionId: providerSessionId, cwd: session.cwd),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date,
              let start = session.cliStartTime,
              modified >= start.addingTimeInterval(-1) else {
            return sessionId
        }

        return providerSessionId
    }

    private func loadMessages() {
        isLoading = true
        let path = effectiveTranscriptPath
        let source = session.source
        Task.detached {
            guard let path else {
                await MainActor.run {
                    messages = []
                    pendingUserMessages = []
                    stopWatchingTranscript()
                    isLoading = false
                    startTranscriptDiscovery()
                }
                return
            }
            let parsed = Self.readMessages(source: source, at: path)
            await MainActor.run {
                applyParsedMessages(parsed)
                isLoading = false
                stopTranscriptDiscovery()
                startWatchingTranscript(at: path)
            }
        }
    }

    @MainActor
    private func startWatchingTranscript(at path: String, forceReopen: Bool = false) {
        if !forceReopen, watchedTranscriptPath == path, fileWatchSource != nil {
            return
        }

        stopWatchingTranscript()

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            watchedTranscriptPath = nil
            return
        }

        watchedFileDescriptor = fd
        watchedTranscriptPath = path

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [path] in
            let flags = source.data
            Task { @MainActor in
                handleTranscriptEvent(flags, fallbackPath: path)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        fileWatchSource = source
        source.resume()
    }

    @MainActor
    private func stopWatchingTranscript() {
        watcherReloadTask?.cancel()
        watcherReloadTask = nil
        stopTranscriptDiscovery()

        fileWatchSource?.cancel()
        fileWatchSource = nil

        watchedFileDescriptor = -1
        watchedTranscriptPath = nil
    }

    @MainActor
    private func handleTranscriptEvent(_ flags: DispatchSource.FileSystemEvent, fallbackPath: String) {
        let needsRewatch = flags.contains(.rename) || flags.contains(.delete)
        scheduleTranscriptReload(rewatch: needsRewatch, fallbackPath: fallbackPath)
    }

    @MainActor
    private func scheduleTranscriptReload(rewatch: Bool, fallbackPath: String) {
        watcherReloadTask?.cancel()
        watcherReloadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }

            let path = effectiveTranscriptPath ?? fallbackPath
            if rewatch {
                startWatchingTranscript(at: path, forceReopen: true)
            }

            let source = session.source
            let parsed = await Task.detached {
                Self.readMessages(source: source, at: path)
            }.value
            applyParsedMessages(parsed)
        }
    }

    @MainActor
    private func startTranscriptDiscovery() {
        guard transcriptDiscoveryTask == nil else { return }

        transcriptDiscoveryTask = Task { @MainActor in
            while !Task.isCancelled {
                if let path = effectiveTranscriptPath {
                    let source = session.source
                    let parsed = await Task.detached {
                        Self.readMessages(source: source, at: path)
                    }.value
                    applyParsedMessages(parsed)
                    isLoading = false
                    startWatchingTranscript(at: path)
                    transcriptDiscoveryTask = nil
                    return
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    @MainActor
    private func stopTranscriptDiscovery() {
        transcriptDiscoveryTask?.cancel()
        transcriptDiscoveryTask = nil
    }

    @MainActor
    private func refreshTranscriptBindingIfNeeded() {
        if let path = effectiveTranscriptPath {
            stopTranscriptDiscovery()
            if watchedTranscriptPath != path || fileWatchSource == nil {
                let parsed = Self.readMessages(source: session.source, at: path)
                applyParsedMessages(parsed)
                isLoading = false
                startWatchingTranscript(at: path, forceReopen: watchedTranscriptPath != path)
            }
        } else if fileWatchSource == nil {
            startTranscriptDiscovery()
        }
    }

    @MainActor
    private func applyParsedMessages(_ parsed: [SessionChatMessage]) {
        if parsed != messages {
            if shouldAnimateMessageInsertion(from: messages, to: parsed) {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                    messages = parsed
                }
            } else {
                messages = parsed
            }
        }
        reconcilePendingMessages(with: parsed)
    }

    private func sendMessage() {
        let text = messageInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let pendingMessage = SessionChatMessage(
            id: "pending-user-\(UUID().uuidString)",
            role: .user,
            text: text,
            timestamp: Date()
        )
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            pendingUserMessages.append(pendingMessage)
        }
        messageInput = ""
        Task { @MainActor in
            if watchedTranscriptPath == nil {
                startTranscriptDiscovery()
            }
        }
        Task.detached {
            await MessageSender.send(text, to: session)
        }
    }

    private func reconcilePendingMessages(with parsed: [SessionChatMessage]) {
        let parsedUsers = parsed.filter(\.isUser)
        guard !parsedUsers.isEmpty, !pendingUserMessages.isEmpty else { return }

        var searchIndex = 0
        var unresolved: [SessionChatMessage] = []

        for pending in pendingUserMessages {
            let pendingText = normalizedUserText(pending.text)
            var matched = false

            while searchIndex < parsedUsers.count {
                let candidate = parsedUsers[searchIndex]
                searchIndex += 1

                let sameText = normalizedUserText(candidate.text) == pendingText
                let closeInTime = abs(candidate.timestamp.timeIntervalSince(pending.timestamp)) < 30
                if sameText && closeInTime {
                    matched = true
                    break
                }
            }

            if !matched {
                unresolved.append(pending)
            }
        }

        if unresolved != pendingUserMessages {
            withAnimation(.easeOut(duration: 0.18)) {
                pendingUserMessages = unresolved
            }
        }
    }

    private func normalizedUserText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldAnimateMessageInsertion(from old: [SessionChatMessage], to new: [SessionChatMessage]) -> Bool {
        guard !old.isEmpty else { return false }
        let oldIds = Set(old.map(\.id))
        return new.contains { !oldIds.contains($0.id) }
    }

    // MARK: - Helpers

    nonisolated private static func readMessages(source: String, at path: String) -> [SessionChatMessage] {
        switch source {
        case "claude":
            return ClaudeSessionReader.readMessages(at: path)
        case "codex":
            return CodexSessionReader.readMessages(at: path)
        default:
            return []
        }
    }

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
    var focusRequest: Int
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.contentView.drawsBackground = false

        let textView = ChatInputTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.font = font
        textView.textColor = .white
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.insertionPointColor = .white.withAlphaComponent(0.7)
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        scrollView.documentView = textView

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
        let textView = scrollView.documentView as! ChatInputTextView
        if textView.frame.size != scrollView.contentSize {
            textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        }
        if textView.string != text {
            textView.string = text
            context.coordinator.updatePlaceholder()
        }
        context.coordinator.onSubmit = onSubmit
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async {
                guard textView.window != nil else { return }
                textView.suppressAutomaticFocus = false
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputEditor
        var onSubmit: (() -> Void)?
        var placeholderAttr: NSAttributedString?
        weak var textView: NSTextView?
        private var placeholderView: NSTextField?
        var lastFocusRequest: Int

        init(_ parent: ChatInputEditor) {
            self.parent = parent
            self.onSubmit = parent.onSubmit
            self.lastFocusRequest = parent.focusRequest
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
                    label.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: 8),
                    label.topAnchor.constraint(equalTo: tv.topAnchor, constant: 4),
                ])
                placeholderView = label
            }
            placeholderView?.isHidden = !tv.string.isEmpty
        }
    }
}

private final class ChatInputTextView: NSTextView {
    var suppressAutomaticFocus = true

    override var acceptsFirstResponder: Bool {
        if suppressAutomaticFocus {
            return false
        }
        return super.acceptsFirstResponder
    }

    override func mouseDown(with event: NSEvent) {
        suppressAutomaticFocus = false
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
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
