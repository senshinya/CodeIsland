import SwiftUI
import CodeIslandCore
import Darwin

/// Chat history view for a supported CLI session.
struct SessionChatView: View {
    private static let chatBottomSentinelID = "chat_bottom_sentinel"

    private enum InitialScrollTiming {
        static let stableSampleInterval: Duration = .milliseconds(16)
        static let stableDetectionTimeout: Duration = .milliseconds(200)
        static let bottomLockSampleInterval: Duration = .milliseconds(16)
        static let bottomLockTimeout: Duration = .milliseconds(350)
        static let requiredStableSamples = 2
        static let finalVerificationDelays = [0, 16, 32, 64, 96]
    }

    let sessionId: String
    let session: SessionSnapshot
    var appState: AppState
    @State private var messages: [SessionChatMessage] = []
    @State private var pendingUserMessages: [SessionChatMessage] = []
    @State private var resolvedPendingDisplayIDs: [String: String] = [:]
    @State private var messageInput = ""
    @State private var isLoading = true
    @State private var inputFocusRequest = 0
    @State private var fileWatchSource: DispatchSourceFileSystemObject?
    @State private var watchedFileDescriptor: Int32 = -1
    @State private var watchedTranscriptPath: String?
    @State private var watcherReloadTask: Task<Void, Never>?
    @State private var transcriptDiscoveryTask: Task<Void, Never>?
    @State private var scrollToBottomTask: Task<Void, Never>?
    @State private var initialContentRevealTask: Task<Void, Never>?
    @State private var hasCompletedInitialScroll = false
    @State private var hasRevealedInitialContent = false
    @State private var isPinnedToBottom = true
    @State private var newMessageCount = 0
    @State private var shouldAutoScrollOnNextLayout = true
    @State private var pendingPinnedScroll = false
    @State private var isPerformingProgrammaticScroll = false
    @State private var programmaticScrollResetTask: Task<Void, Never>?
    @State private var pendingPinnedDocumentHeight: CGFloat?
    @State private var animatedAppearanceMessageIDs: Set<String> = []
    @StateObject private var scrollController = SessionChatScrollController()
    @AppStorage(SettingsKey.contentFontSize) private var contentFontSize = SettingsDefaults.contentFontSize
    @AppStorage(SettingsKey.maxPanelHeight) private var maxPanelHeight = SettingsDefaults.maxPanelHeight

    private var fontSize: CGFloat { CGFloat(contentFontSize) }
    private let claudeAccent = Color(red: 0.85, green: 0.47, blue: 0.34)
    private let codexAccent = Color(red: 0.32, green: 0.60, blue: 0.96)
    private let toolGreen = Color(red: 0.40, green: 0.88, blue: 0.62)
    private var newMessagesAccent: Color {
        session.source == "codex" ? codexAccent : claudeAccent
    }
    private var displayedMessages: [DisplayedChatMessage] {
        SessionChatDisplayReconciler.displayMessages(
            messages: messages,
            pending: pendingUserMessages,
            resolvedDisplayIDs: resolvedPendingDisplayIDs
        )
    }
    private var visibleMessages: [DisplayedChatMessage] {
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
        .onAppear {
            hasCompletedInitialScroll = false
            hasRevealedInitialContent = false
            isPinnedToBottom = true
            newMessageCount = 0
            shouldAutoScrollOnNextLayout = true
            pendingPinnedScroll = false
            pendingPinnedDocumentHeight = nil
            animatedAppearanceMessageIDs = []
            isPerformingProgrammaticScroll = false
            scheduleInitialContentRevealFallback()
            loadMessages()
        }
        .onDisappear {
            scrollToBottomTask?.cancel()
            initialContentRevealTask?.cancel()
            isPerformingProgrammaticScroll = false
            stopWatchingTranscript()
        }
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
                VStack(alignment: .leading, spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(visibleMessages) { msg in
                            messageRow(msg.message)
                                .modifier(
                                    MessageAppearanceModifier(
                                        animateOnAppear: animatedAppearanceMessageIDs.contains(msg.id)
                                    )
                                )
                                .id(msg.id)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                    Color.clear
                        .frame(height: 1)
                        .id(Self.chatBottomSentinelID)
                }
                .background(
                    ScrollViewLiveScrollObserver { atBottom in
                        guard hasCompletedInitialScroll else { return }
                        guard !isPerformingProgrammaticScroll else { return }
                        guard !pendingPinnedScroll else { return }
                        scrollToBottomTask?.cancel()
                        pendingPinnedScroll = false
                        shouldAutoScrollOnNextLayout = false
                        isPinnedToBottom = atBottom
                        if atBottom {
                            newMessageCount = 0
                        }
                    } onResolveScrollView: { scrollView in
                        scrollController.attach(scrollView)
                    }
                )
            }
            .coordinateSpace(name: "chat_scroll")
            .textSelection(.disabled)
            .frame(maxHeight: chatMaxHeight)
            .opacity(hasRevealedInitialContent ? 1 : 0)
            .overlay(alignment: .bottom) {
                if shouldShowNewMessagesButton {
                    newMessagesButton(with: proxy)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear {
                scrollToBottom(with: proxy, isInitial: true)
            }
            .onChange(of: visibleMessages) { _, _ in
                guard shouldAutoScrollOnNextLayout else { return }
                if let previousDocumentHeight = pendingPinnedDocumentHeight, hasCompletedInitialScroll {
                    preservePinnedBottom(with: proxy, previousDocumentHeight: previousDocumentHeight)
                } else {
                    scrollToBottom(with: proxy)
                }
            }
        }
    }

    private func scrollToBottom(
        with proxy: ScrollViewProxy,
        isInitial: Bool = false,
        delay: Duration? = .milliseconds(75),
        verifyBottom: Bool = false
    ) {
        let wasInitialPending = isInitial || !hasCompletedInitialScroll
        scrollToBottomTask?.cancel()
        pendingPinnedScroll = true
        scrollToBottomTask = Task { @MainActor in
            if wasInitialPending {
                await waitForStableInitialLayout()
            } else if let delay {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            performScrollToBottom(with: proxy)
            if wasInitialPending {
                revealInitialContent()
            }
            if verifyBottom {
                let reachedBottom = await confirmBottomPosition(with: proxy)
                guard !Task.isCancelled else { return }
                isPinnedToBottom = reachedBottom
                if reachedBottom {
                    newMessageCount = 0
                }
            }
            if wasInitialPending {
                await settleInitialBottomLock(with: proxy)
                let reachedBottom = await confirmBottomPosition(
                    with: proxy,
                    delays: InitialScrollTiming.finalVerificationDelays
                )
                guard !Task.isCancelled else { return }
                isPinnedToBottom = reachedBottom
            }

            pendingPinnedDocumentHeight = nil

            pendingPinnedScroll = false
            shouldAutoScrollOnNextLayout = false
            if wasInitialPending {
                hasCompletedInitialScroll = true
                revealInitialContent()
            }
            if !verifyBottom, !wasInitialPending, scrollController.documentHeight != nil {
                isPinnedToBottom = scrollController.isAtBottom
            }
            if isPinnedToBottom {
                newMessageCount = 0
            }
        }
    }

    private func confirmBottomPosition(
        with proxy: ScrollViewProxy,
        delays: [Int] = [0, 16, 32]
    ) async -> Bool {
        for (index, delay) in delays.enumerated() {
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(delay))
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled else { return false }

            if scrollController.documentHeight != nil, scrollController.isAtBottom {
                return true
            }

            if index == 0 {
                performScrollToBottom(with: proxy, preferAnchorScroll: true)
            }
        }

        return scrollController.documentHeight != nil && scrollController.isAtBottom
    }

    private func scheduleInitialContentRevealFallback() {
        initialContentRevealTask?.cancel()
        initialContentRevealTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            revealInitialContent()
        }
    }

    @MainActor
    private func revealInitialContent() {
        initialContentRevealTask?.cancel()
        initialContentRevealTask = nil
        hasRevealedInitialContent = true
    }

    private func waitForStableInitialLayout() async {
        var lastHeight: CGFloat?
        var stableSampleCount = 0
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: InitialScrollTiming.stableDetectionTimeout)

        while clock.now < deadline {
            await Task.yield()
            guard !Task.isCancelled else { return }

            guard let documentHeight = scrollController.documentHeight, documentHeight > 0 else {
                stableSampleCount = 0
                try? await Task.sleep(for: InitialScrollTiming.stableSampleInterval)
                continue
            }

            if let lastHeight, abs(documentHeight - lastHeight) < 0.5 {
                stableSampleCount += 1
            } else {
                stableSampleCount = 0
            }

            if stableSampleCount >= InitialScrollTiming.requiredStableSamples {
                return
            }

            lastHeight = documentHeight
            try? await Task.sleep(for: InitialScrollTiming.stableSampleInterval)
        }
    }

    private func settleInitialBottomLock(with proxy: ScrollViewProxy) async {
        var lastHeight = scrollController.documentHeight ?? 0
        var stableSampleCount = 0
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: InitialScrollTiming.bottomLockTimeout)

        while clock.now < deadline {
            try? await Task.sleep(for: InitialScrollTiming.bottomLockSampleInterval)
            guard !Task.isCancelled else { return }

            guard let currentHeight = scrollController.documentHeight, currentHeight > 0 else {
                stableSampleCount = 0
                continue
            }

            if abs(currentHeight - lastHeight) > 0.5 {
                if !scrollController.preservePinnedBottom(previousDocumentHeight: lastHeight) {
                    performScrollToBottom(with: proxy)
                }
                lastHeight = currentHeight
                stableSampleCount = 0
            } else {
                stableSampleCount += 1
                if stableSampleCount >= InitialScrollTiming.requiredStableSamples {
                    if scrollController.isAtBottom {
                        return
                    }
                    performScrollToBottom(with: proxy)
                    stableSampleCount = 0
                    lastHeight = scrollController.documentHeight ?? currentHeight
                }
            }
        }

        performScrollToBottom(with: proxy)
    }

    private func preservePinnedBottom(with proxy: ScrollViewProxy, previousDocumentHeight: CGFloat) {
        // If a previous scroll task is still in-flight, its delta was never applied.
        // Fall back to absolute scrollToBottom to avoid accumulating position drift.
        let previousTaskPending = pendingPinnedScroll && scrollToBottomTask != nil
        scrollToBottomTask?.cancel()

        if previousTaskPending {
            scrollToBottomTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else { return }
                performScrollToBottom(with: proxy)
                pendingPinnedDocumentHeight = nil
                pendingPinnedScroll = false
                shouldAutoScrollOnNextLayout = false
            }
            return
        }

        scrollToBottomTask = Task { @MainActor in
            for delay in [0, 16, 32, 64] {
                if delay > 0 {
                    try? await Task.sleep(for: .milliseconds(delay))
                } else {
                    await Task.yield()
                }
                guard !Task.isCancelled else { return }
                if scrollController.preservePinnedBottom(previousDocumentHeight: previousDocumentHeight) {
                    pendingPinnedDocumentHeight = nil
                    pendingPinnedScroll = false
                    shouldAutoScrollOnNextLayout = false
                    return
                }
            }

            if !Task.isCancelled {
                performScrollToBottom(with: proxy)
            }
            pendingPinnedDocumentHeight = nil
            pendingPinnedScroll = false
            shouldAutoScrollOnNextLayout = false
        }
    }

    private func performScrollToBottom(with proxy: ScrollViewProxy, preferAnchorScroll: Bool = false) {
        programmaticScrollResetTask?.cancel()
        isPerformingProgrammaticScroll = true
        if preferAnchorScroll || !scrollController.scrollToBottom() {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(Self.chatBottomSentinelID, anchor: .bottom)
            }
        }
        programmaticScrollResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            isPerformingProgrammaticScroll = false
        }
    }

    private func prepareForMessageListChange() {
        let shouldStick = isPinnedToBottom || !hasCompletedInitialScroll
        shouldAutoScrollOnNextLayout = shouldStick
        pendingPinnedScroll = shouldStick
        pendingPinnedDocumentHeight = shouldStick && hasCompletedInitialScroll ? scrollController.documentHeight : nil
    }

    private var chatMaxHeight: CGFloat {
        let h = maxPanelHeight > 0 ? CGFloat(maxPanelHeight) : 400
        return h - 80
    }

    private var shouldShowNewMessagesButton: Bool {
        hasCompletedInitialScroll && !isPinnedToBottom && newMessageCount > 0
    }

    private func newMessagesButton(with proxy: ScrollViewProxy) -> some View {
        Button {
            scrollToBottom(with: proxy, delay: nil, verifyBottom: true)
        } label: {
            Text(String(format: L10n.shared["chat_new_messages_count"], newMessageCount))
                .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.96))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    Capsule(style: .continuous)
                        .fill(.black.opacity(0.78))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(newMessagesAccent.opacity(0.55), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
                )
        }
        .buttonStyle(.plain)
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
        if let path = session.transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            return path
        }

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
                    resolvedPendingDisplayIDs = [:]
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
        let reconciliation = SessionChatDisplayReconciler.reconcilePendingMessages(
            pending: pendingUserMessages,
            parsed: parsed,
            existingResolvedDisplayIDs: resolvedPendingDisplayIDs
        )
        let nextDisplayIDs = SessionChatDisplayReconciler.updatedResolvedDisplayIDs(
            existing: resolvedPendingDisplayIDs,
            parsed: parsed,
            matchedDisplayIDs: reconciliation.matchedDisplayIDs
        )
        let messagesChanged = parsed != messages
        let pendingChanged = reconciliation.unresolvedPending != pendingUserMessages
        let displayIDsChanged = nextDisplayIDs != resolvedPendingDisplayIDs

        guard messagesChanged || pendingChanged || displayIDsChanged else { return }

        let oldDisplayedMessages = SessionChatDisplayReconciler.displayMessages(
            messages: messages,
            pending: pendingUserMessages,
            resolvedDisplayIDs: resolvedPendingDisplayIDs
        )
        let newDisplayedMessages = SessionChatDisplayReconciler.displayMessages(
            messages: parsed,
            pending: reconciliation.unresolvedPending,
            resolvedDisplayIDs: nextDisplayIDs
        )
        let insertedDisplayIDs = Set(newDisplayedMessages.map(\.id))
            .subtracting(oldDisplayedMessages.map(\.id))

        prepareForMessageListChange()
        let applyStateChanges = {
            messages = parsed
            pendingUserMessages = reconciliation.unresolvedPending
            resolvedPendingDisplayIDs = nextDisplayIDs
        }

        if !shouldAutoScrollOnNextLayout, hasCompletedInitialScroll {
            newMessageCount += insertedDisplayIDs.count
        }

        if shouldAutoScrollOnNextLayout {
            animatedAppearanceMessageIDs = hasCompletedInitialScroll ? insertedDisplayIDs : []
            applyStateChanges()
        } else {
            animatedAppearanceMessageIDs = []
            applyStateChanges()
        }
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
        // Sending a message always pins to bottom — the user expects to see their own message.
        isPinnedToBottom = true
        newMessageCount = 0
        prepareForMessageListChange()
        animatedAppearanceMessageIDs = hasCompletedInitialScroll ? [pendingMessage.id] : []
        pendingUserMessages.append(pendingMessage)
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

struct DisplayedChatMessage: Identifiable, Equatable {
    let id: String
    let message: SessionChatMessage
}

struct PendingMessageReconciliation: Equatable {
    let unresolvedPending: [SessionChatMessage]
    let matchedDisplayIDs: [String: String]
}

final class SessionChatScrollController: ObservableObject {
    /// Shared threshold for "at bottom" detection — keeps observer and controller consistent.
    static let bottomThreshold: CGFloat = 24

    private weak var scrollView: NSScrollView?

    var documentHeight: CGFloat? {
        scrollView?.documentView?.bounds.height
    }

    var isAtBottom: Bool {
        guard let scrollView else { return false }
        let visibleMaxY = scrollView.contentView.documentVisibleRect.maxY
        let documentMaxY = scrollView.documentView?.bounds.maxY ?? 0
        return visibleMaxY >= documentMaxY - Self.bottomThreshold
    }

    func attach(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
    }

    @discardableResult
    func scrollToBottom() -> Bool {
        guard let scrollView, let documentView = scrollView.documentView else { return false }

        let viewportHeight = scrollView.contentView.bounds.height
        let documentHeight = documentView.bounds.height
        let targetY = max(0, documentHeight - viewportHeight)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return true
    }

    @discardableResult
    func preservePinnedBottom(previousDocumentHeight: CGFloat) -> Bool {
        guard let scrollView, let documentView = scrollView.documentView else { return false }

        let newDocumentHeight = documentView.bounds.height
        let delta = newDocumentHeight - previousDocumentHeight
        guard abs(delta) > 0.5 else { return false }

        let clipView = scrollView.contentView
        let maxY = max(0, newDocumentHeight - clipView.bounds.height)
        var origin = clipView.bounds.origin
        origin.y = min(max(0, origin.y + delta), maxY)
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
        return true
    }
}

private struct ScrollViewLiveScrollObserver: NSViewRepresentable {
    let onScroll: (Bool) -> Void
    var onResolveScrollView: ((NSScrollView) -> Void)? = nil

    func makeNSView(context: Context) -> ScrollObserverView {
        let view = ScrollObserverView()
        view.onScroll = onScroll
        view.onResolveScrollView = onResolveScrollView
        return view
    }

    func updateNSView(_ nsView: ScrollObserverView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onResolveScrollView = onResolveScrollView
        nsView.attachIfNeeded()
    }
}

private final class ScrollObserverView: NSView {
    var onScroll: ((Bool) -> Void)?
    var onResolveScrollView: ((NSScrollView) -> Void)?

    private weak var observedScrollView: NSScrollView?
    private var boundsObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfNeeded()
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            detach()
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    deinit {
        detach()
    }

    func attachIfNeeded() {
        guard let scrollView = enclosingScrollView ?? findEnclosingScrollView() else { return }
        guard observedScrollView !== scrollView else {
            notifyScrollPosition()
            return
        }

        detach()
        observedScrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.notifyScrollPosition()
        }
        onResolveScrollView?(scrollView)
        notifyScrollPosition()
    }

    private func detach() {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
        boundsObserver = nil
        observedScrollView = nil
    }

    private func findEnclosingScrollView() -> NSScrollView? {
        var view = superview
        while let current = view {
            if let scrollView = current as? NSScrollView {
                return scrollView
            }
            view = current.superview
        }
        return nil
    }

    private func notifyScrollPosition() {
        guard let scrollView = observedScrollView else { return }
        let visibleMaxY = scrollView.contentView.documentVisibleRect.maxY
        let documentMaxY = scrollView.documentView?.bounds.maxY ?? 0
        onScroll?(visibleMaxY >= documentMaxY - SessionChatScrollController.bottomThreshold)
    }
}

private struct MessageAppearanceModifier: ViewModifier {
    let animateOnAppear: Bool
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(animateOnAppear ? (isVisible ? 1 : 0.2) : 1)
            .offset(y: animateOnAppear ? (isVisible ? 0 : 8) : 0)
            .scaleEffect(animateOnAppear ? (isVisible ? 1 : 0.985) : 1, anchor: .bottom)
            .onAppear {
                guard animateOnAppear else {
                    isVisible = true
                    return
                }
                isVisible = false
                withAnimation(.easeOut(duration: 0.18)) {
                    isVisible = true
                }
            }
    }
}

enum SessionChatDisplayReconciler {
    static func displayMessages(
        messages: [SessionChatMessage],
        pending: [SessionChatMessage],
        resolvedDisplayIDs: [String: String]
    ) -> [DisplayedChatMessage] {
        let resolvedMessages = messages.map { message in
            DisplayedChatMessage(
                id: resolvedDisplayIDs[message.id] ?? message.id,
                message: message
            )
        }
        let pendingMessages = pending.map { message in
            DisplayedChatMessage(id: message.id, message: message)
        }
        return resolvedMessages + pendingMessages
    }

    static func reconcilePendingMessages(
        pending: [SessionChatMessage],
        parsed: [SessionChatMessage],
        existingResolvedDisplayIDs: [String: String]
    ) -> PendingMessageReconciliation {
        let parsedUsers = parsed.filter(\.isUser)
        guard !parsedUsers.isEmpty, !pending.isEmpty else {
            return PendingMessageReconciliation(unresolvedPending: pending, matchedDisplayIDs: [:])
        }

        var searchIndex = 0
        var unresolved: [SessionChatMessage] = []
        var matchedDisplayIDs: [String: String] = [:]

        for pendingMessage in pending {
            var matched = false

            while searchIndex < parsedUsers.count {
                let candidate = parsedUsers[searchIndex]
                searchIndex += 1

                guard pendingMessageMatchesParsedUser(pendingMessage, candidate) else { continue }
                matchedDisplayIDs[candidate.id] = existingResolvedDisplayIDs[candidate.id] ?? pendingMessage.id
                matched = true
                break
            }

            if !matched {
                unresolved.append(pendingMessage)
            }
        }

        return PendingMessageReconciliation(
            unresolvedPending: unresolved,
            matchedDisplayIDs: matchedDisplayIDs
        )
    }

    static func updatedResolvedDisplayIDs(
        existing: [String: String],
        parsed: [SessionChatMessage],
        matchedDisplayIDs: [String: String]
    ) -> [String: String] {
        let parsedIDs = Set(parsed.map(\.id))
        var updated = existing.filter { parsedIDs.contains($0.key) }
        for (parsedID, displayID) in matchedDisplayIDs {
            updated[parsedID] = displayID
        }
        return updated
    }

    private static func pendingMessageMatchesParsedUser(
        _ pending: SessionChatMessage,
        _ parsed: SessionChatMessage
    ) -> Bool {
        guard parsed.isUser else { return false }
        let sameText = normalizedUserText(parsed.text) == normalizedUserText(pending.text)
        let closeInTime = abs(parsed.timestamp.timeIntervalSince(pending.timestamp)) < 30
        return sameText && closeInTime
    }

    private static func normalizedUserText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
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
