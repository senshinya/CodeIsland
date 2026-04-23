import SwiftUI
import CodeIslandCore
import Darwin
import MarkdownUI
import os.log

private let messageLog = Logger(subsystem: "com.codeisland", category: "MessageSender")

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

    /// Delay before the eager messageList is allowed to render after onAppear,
    /// comfortably past `NotchAnimation.open`'s spring response (0.42s) so
    /// MarkdownUI's block-view construction doesn't land mid-animation.
    private static let openAnimationGuardDelay: Duration = .milliseconds(600)

    let sessionId: String
    let session: SessionSnapshot
    var appState: AppState
    @State private var messages: [SessionChatMessage] = []
    @State private var pendingUserMessages: [SessionChatMessage] = []
    @State private var resolvedPendingDisplayIDs: [String: String] = [:]
    @State private var isLoading = true
    @State private var fileWatchSource: DispatchSourceFileSystemObject?
    @State private var watchedFileDescriptor: Int32 = -1
    @State private var watchedTranscriptPath: String?
    @State private var watcherReloadTask: Task<Void, Never>?
    @State private var transcriptDiscoveryTask: Task<Void, Never>?
    @State private var scrollToBottomTask: Task<Void, Never>?
    @State private var initialContentRevealTask: Task<Void, Never>?
    @State private var messageListGateTask: Task<Void, Never>?
    @State private var hasCompletedInitialScroll = false
    @State private var hasRevealedInitialContent = false
    /// Gates the eager MarkdownUI messageList subtree so its first render
    /// (which can block the main thread for long assistant messages) lands
    /// after the NotchAnimation.open spring settles. See `openAnimationGuardDelay`.
    @State private var canRenderMessageList = false
    @State private var isPinnedToBottom = true
    /// Drives the message-list opacity directly. Bool→Double derived opacity
    /// didn't reliably interpolate under withAnimation (observed as instant
    /// disappear instead of fade), so expose a Double @State and let withAnimation
    /// animate it natively. `hasRevealedInitialContent` is still kept separately
    /// for non-visual logic that depends on "first reveal complete".
    @State private var contentOpacity: Double = 0
    @State private var jumpFadeTask: Task<Void, Never>?
    /// When the user has scrolled away from the bottom, the visibleMessages window
    /// freezes its head at this id so new-message appends grow the window downward
    /// without dropping older rows at the top — which would shift the viewport
    /// content upward since NSScrollView preserves contentOffset, not content meaning.
    /// nil while pinned to bottom (window slides normally in that case).
    @State private var visibleWindowAnchorID: String?
    @State private var newMessageCount = 0
    @State private var shouldAutoScrollOnNextLayout = true
    /// Set by sendMessage so the next onChange-driven scroll routes through the settle
    /// path instead of the fast 4-loop. Post-send scrolls often have to jump across
    /// unmaterialized LazyVStack rows (user was scrolled up), which produces a black
    /// flash with the fast loop. Streaming updates stay on the fast loop.
    @State private var sendTriggeredScrollSettle = false
    @State private var pendingPinnedScroll = false
    @State private var isPerformingProgrammaticScroll = false
    @State private var programmaticScrollResetTask: Task<Void, Never>?
    @State private var inlineCompletionAutoDismissTask: Task<Void, Never>?
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
        // Bounded to keep VStack first-render cheap. MarkdownUI instantiates
        // block views eagerly so cost scales with row count. 150 is enough to
        // cover most in-session history; older messages stay in the transcript
        // file and aren't lost, they're just not rendered in the chat panel.
        let limit = session.source == "codex" ? 120 : 150
        guard displayedMessages.count > limit else { return displayedMessages }

        // While the user is scrolled up reading history, don't slide the window
        // on each new message — that would drop the oldest row from the VStack's
        // top and the viewport would appear to scroll upward since contentOffset
        // is preserved in pixel space, not in row space. Anchor the window head
        // on the row the user was looking at and grow downward as new messages
        // arrive. Once the user returns to the bottom (isPinnedToBottom = true)
        // the anchor is cleared and the window slides normally again.
        if !isPinnedToBottom,
           let anchorID = visibleWindowAnchorID,
           let index = displayedMessages.firstIndex(where: { $0.id == anchorID }) {
            return Array(displayedMessages[index...])
        }

        return Array(displayedMessages.suffix(limit))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            if isLoading || (!canRenderMessageList && !displayedMessages.isEmpty) {
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

            bottomBar
        }
        .onAppear {
            hasCompletedInitialScroll = false
            hasRevealedInitialContent = false
            contentOpacity = 0
            canRenderMessageList = false
            isPinnedToBottom = true
            visibleWindowAnchorID = nil
            newMessageCount = 0
            shouldAutoScrollOnNextLayout = true
            pendingPinnedScroll = false
            isPerformingProgrammaticScroll = false
            scheduleInitialContentRevealFallback()
            scheduleMessageListGate()
            loadMessages()
        }
        .onDisappear {
            scrollToBottomTask?.cancel()
            initialContentRevealTask?.cancel()
            messageListGateTask?.cancel()
            jumpFadeTask?.cancel()
            inlineCompletionAutoDismissTask?.cancel()
            isPerformingProgrammaticScroll = false
            stopWatchingTranscript()
            appState.setMessageInputFocused(false)
            appState.clearInlineCompletion(for: sessionId)
        }
        .onChange(of: session.providerSessionId) { _, _ in
            refreshTranscriptBindingIfNeeded()
        }
        .onChange(of: session.cwd) { _, _ in
            refreshTranscriptBindingIfNeeded()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var inlineCompletionHint: some View {
        VStack(spacing: 0) {
            Line()
                .stroke(.white.opacity(0.15), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                .frame(height: 0.5)
                .padding(.horizontal, 12)
            HStack(spacing: 6) {
                Circle()
                    .fill(newMessagesAccent)
                    .frame(width: 5, height: 5)
                Text(L10n.shared["chat_turn_complete"])
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(height: 20)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(NotchAnimation.open) {
                    appState.clearInlineCompletion(for: sessionId)
                }
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        // Priority: inline completion hint → inline permission → inline question → message input bar → nothing.
        // Only items belonging to this session render inline; other-session items
        // wait in the queue until the user leaves chat (drain-on-leave in AppState).
        if shouldShowInlineCompletionHint {
            VStack(spacing: 0) {
                inlineCompletionHint
                if SessionMessageBarSupport.canShow(for: session) {
                    SessionMessageInputBar(
                        session: session,
                        sessionId: sessionId,
                        appState: appState,
                        fontSize: fontSize,
                        onFocusChange: { appState.setMessageInputFocused($0) },
                        onSubmitText: { sendMessage($0) }
                    )
                }
            }
            .transition(.blurFade.combined(with: .scale(scale: 0.96, anchor: .bottom)))
        } else if let permission = appState.pendingPermission,
           (permission.event.sessionId ?? "default") == sessionId {
            VStack(spacing: 0) {
                Line()
                    .stroke(.white.opacity(0.15), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                    .frame(height: 0.5)
                    .padding(.horizontal, 12)
                ApprovalBar(
                    tool: permission.event.toolName ?? "Unknown",
                    toolInput: permission.event.toolInput,
                    queuePosition: 1,
                    queueTotal: appState.permissionQueue.count,
                    session: session,
                    sessionId: sessionId,
                    appState: appState,
                    onAllow: { withAnimation(NotchAnimation.open) { appState.approvePermission(always: false) } },
                    onAlwaysAllow: { withAnimation(NotchAnimation.open) { appState.approvePermission(always: true) } },
                    onDeny: { withAnimation(NotchAnimation.open) { appState.denyPermission() } },
                    onBypass: { withAnimation(NotchAnimation.open) { appState.bypassPermission() } },
                    onDismiss: { withAnimation(NotchAnimation.open) { appState.dismissPermission() } }
                )
            }
            .transition(.blurFade.combined(with: .scale(scale: 0.96, anchor: .bottom)))
        } else if let q = appState.pendingQuestion,
                  (q.event.sessionId ?? "default") == sessionId {
            VStack(spacing: 0) {
                Line()
                    .stroke(.white.opacity(0.15), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                    .frame(height: 0.5)
                    .padding(.horizontal, 12)
                QuestionBar(
                    question: q.question.question,
                    options: q.question.options,
                    descriptions: q.question.descriptions,
                    allQuestions: q.askUserQuestionState?.items ?? [],
                    sessionSource: session.source,
                    sessionContext: session.cwd,
                    queuePosition: 1,
                    queueTotal: appState.questionQueue.count,
                    onAnswer: { answer in withAnimation(NotchAnimation.open) { appState.answerQuestion(answer) } },
                    onAnswerMulti: { answers in withAnimation(NotchAnimation.open) { appState.answerQuestionMulti(answers) } },
                    onDismiss: { withAnimation(NotchAnimation.open) { appState.dismissQuestion() } }
                )
            }
            .transition(.blurFade.combined(with: .scale(scale: 0.96, anchor: .bottom)))
        } else if SessionMessageBarSupport.canShow(for: session) {
            SessionMessageInputBar(
                session: session,
                sessionId: sessionId,
                appState: appState,
                fontSize: fontSize,
                onFocusChange: { appState.setMessageInputFocused($0) },
                onSubmitText: { sendMessage($0) }
            )
            .transition(.blurFade.combined(with: .scale(scale: 0.96, anchor: .bottom)))
        }
    }

    private var headerBar: some View {
        ZStack {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                    MascotView(source: session.source, status: session.status, size: 20)
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
                    // Eager VStack instead of LazyVStack. Rationale: the visible-window
                    // is bounded (150 Claude / 120 Codex, see `visibleMessages`), and
                    // LazyVStack's height-estimation races with MarkdownUI's variable-height
                    // block rendering caused scroll-to-bottom to land in unmaterialized
                    // regions (persistent black panel). Eager layout trades a slightly
                    // slower first-render for correct, race-free scroll positioning.
                    // See git history for the /hunt sessions that arrived at this.
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(visibleMessages) { msg in
                            messageRow(msg.message)
                                .id(msg.id)
                                .transition(.opacity.animation(.easeOut(duration: 0.18)))
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
                        guard !scrollController.isAnimatingScroll else { return }
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
            // Opacity driven by a Double @State so `withAnimation` interpolates it
            // natively. revealInitialContent raises it to 1 on first reveal; the
            // jump helper fades it to 0 before the instant scroll and back to 1
            // after settle. Bool-derived opacity didn't animate reliably here.
            .opacity(contentOpacity)
            .onAppear {
                scrollController.onNewMessagesTapped = {
                    // Fade-out → instant jump → settle → fade-in. Replaces the older
                    // long spring scroll which stuttered whenever MarkdownUI rows were
                    // still re-measuring during the animation.
                    jumpToBottomWithFade(with: proxy)
                }
                scrollToBottom(with: proxy, isInitial: true)
            }
            .onChange(of: shouldShowNewMessagesButton) { _, show in
                if show {
                    scrollController.showNewMessagesButton(
                        count: newMessageCount,
                        accentColor: NSColor(newMessagesAccent),
                        fontSize: fontSize,
                        completionPulse: isCompletionPulseActive
                    )
                } else {
                    scrollController.hideNewMessagesButton()
                    // User scrolled back to bottom → pill went away, also clear
                    // the completion flag so the pulse won't reappear next time.
                    if appState.inlineCompletionSessionId == sessionId {
                        appState.clearInlineCompletion(for: sessionId)
                    }
                }
            }
            .onChange(of: newMessageCount) { _, count in
                if shouldShowNewMessagesButton {
                    scrollController.showNewMessagesButton(
                        count: count,
                        accentColor: NSColor(newMessagesAccent),
                        fontSize: fontSize,
                        completionPulse: isCompletionPulseActive
                    )
                }
            }
            .onChange(of: appState.inlineCompletionSessionId) { _, newValue in
                // Re-paint the pill when completion arrives/clears mid-display.
                if shouldShowNewMessagesButton {
                    scrollController.showNewMessagesButton(
                        count: newMessageCount,
                        accentColor: NSColor(newMessagesAccent),
                        fontSize: fontSize,
                        completionPulse: isCompletionPulseActive
                    )
                }
                // Start/refresh the 6s auto-dismiss timer for state A (pinned).
                inlineCompletionAutoDismissTask?.cancel()
                if newValue == sessionId && isPinnedToBottom {
                    inlineCompletionAutoDismissTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        guard !Task.isCancelled else { return }
                        appState.clearInlineCompletion(for: sessionId)
                    }
                }
            }
            .onChange(of: isPinnedToBottom) { _, pinned in
                // Freeze the visible-window head when the user scrolls away from the
                // bottom; snapshot the current top row's id so subsequent appends grow
                // the window downward without dropping the top. Clearing on re-pin lets
                // the window resume its normal suffix-limit sliding behavior.
                if pinned {
                    visibleWindowAnchorID = nil
                } else if visibleWindowAnchorID == nil {
                    visibleWindowAnchorID = visibleMessages.first?.id
                }

                // Transitioning between A and B — restart or cancel the timer.
                inlineCompletionAutoDismissTask?.cancel()
                if pinned && appState.inlineCompletionSessionId == sessionId {
                    inlineCompletionAutoDismissTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        guard !Task.isCancelled else { return }
                        appState.clearInlineCompletion(for: sessionId)
                    }
                }
            }
            .onChange(of: visibleMessages) { _, _ in
                guard shouldAutoScrollOnNextLayout else { return }
                if hasCompletedInitialScroll {
                    if sendTriggeredScrollSettle {
                        // After sendMessage when the user was scrolled up: fade + instant
                        // jump + settle. Using the fade path hides both the scroll
                        // re-position and any MarkdownUI black-flash during row
                        // materialization.
                        sendTriggeredScrollSettle = false
                        jumpToBottomWithFade(with: proxy)
                    } else {
                        // Streaming path — cheap fast loop. At this point we're already
                        // near the bottom from the previous scroll, so the rows being
                        // updated are already materialized and 64ms is sufficient.
                        scrollToBottomTask?.cancel()
                        scrollToBottomTask = Task { @MainActor in
                            for _ in 0..<4 {
                                try? await Task.sleep(for: .milliseconds(16))
                                guard !Task.isCancelled else { return }
                                performScrollToBottom(with: proxy)
                                if scrollController.isAtBottom { break }
                            }
                            isPinnedToBottom = true
                            pendingPinnedScroll = false
                            shouldAutoScrollOnNextLayout = false
                        }
                    }
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
        verifyBottom: Bool = false,
        settle: Bool = false,
        animated: Bool = false
    ) {
        let wasInitialPending = isInitial || !hasCompletedInitialScroll
        // Initial path already polls for layout stability — reuse the same settle loop
        // for any caller that opts in. This handles layout races from lazy rows whose
        // real heights only materialize after the scroll jump (MarkdownUI blocks are
        // the common trigger).
        let shouldSettle = settle || wasInitialPending
        scrollToBottomTask?.cancel()
        pendingPinnedScroll = true
        scrollToBottomTask = Task { @MainActor in
            if wasInitialPending {
                await waitForStableInitialLayout()
            } else if let delay {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }

            if animated {
                // Spring path: the animator auto-retargets to the current bottom every
                // tick, so growing MarkdownUI rows keep the spring aimed correctly
                // instead of leaving us short. Replaces the settle/verify loops.
                performScrollToBottom(with: proxy, animated: true)
                while scrollController.isAnimatingScroll {
                    try? await Task.sleep(for: .milliseconds(16))
                    guard !Task.isCancelled else { return }
                }
                // If the user scrolled during the spring, the live-scroll cancel
                // already handed control back to them — don't snap them back.
                if !scrollController.wasSpringInterruptedByUser,
                   !scrollController.isAtBottom {
                    performScrollToBottom(with: proxy)
                }
                let reachedBottom = scrollController.isAtBottom
                isPinnedToBottom = reachedBottom
                if reachedBottom {
                    newMessageCount = 0
                }
            } else {
                performScrollToBottom(with: proxy)

                if shouldSettle {
                    await settleInitialBottomLock(with: proxy)
                    guard !Task.isCancelled else { return }
                    let reachedBottom = await confirmBottomPosition(
                        with: proxy,
                        delays: InitialScrollTiming.finalVerificationDelays
                    )
                    guard !Task.isCancelled else { return }
                    isPinnedToBottom = reachedBottom
                    if reachedBottom {
                        newMessageCount = 0
                    }
                } else if verifyBottom {
                    let reachedBottom = await confirmBottomPosition(with: proxy)
                    guard !Task.isCancelled else { return }
                    isPinnedToBottom = reachedBottom
                    if reachedBottom {
                        newMessageCount = 0
                    }
                }
            }

            pendingPinnedScroll = false
            shouldAutoScrollOnNextLayout = false
            if wasInitialPending {
                hasCompletedInitialScroll = true
                revealInitialContent()
            }
            if !animated, !verifyBottom, !shouldSettle, scrollController.documentHeight != nil {
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
            // Hard-deadline safety net only — the scroll-based path at line ~567
            // is the normal reveal trigger and fires once settleInitialBottomLock +
            // confirmBottomPosition finish pumping performScrollToBottom. Those
            // loops can run up to ~550ms past the 600ms messageList gate for
            // sessions where MarkdownUI's eager block construction and height
            // stabilization take a while; if we reveal before that, the 0.12s
            // opacity fade runs concurrent with scroll-offset commits and stutters.
            try? await Task.sleep(for: .milliseconds(2000))
            guard !Task.isCancelled else { return }
            revealInitialContent()
        }
    }

    private func scheduleMessageListGate() {
        messageListGateTask?.cancel()
        messageListGateTask = Task { @MainActor in
            try? await Task.sleep(for: Self.openAnimationGuardDelay)
            guard !Task.isCancelled else { return }
            canRenderMessageList = true
        }
    }

    @MainActor
    private func revealInitialContent() {
        initialContentRevealTask?.cancel()
        initialContentRevealTask = nil
        withAnimation(.easeIn(duration: 0.12)) {
            hasRevealedInitialContent = true
            contentOpacity = 1
        }
    }

    /// Jump-to-bottom used by the "new messages" pill tap and the post-send scroll
    /// when the user was scrolled up. The previous implementation animated a long
    /// spring scroll that stuttered when MarkdownUI rows were still settling their
    /// heights. This replaces it with: fade-out → instant scroll (while invisible)
    /// → settle → fade-in, which is both smoother to look at and robust to rows
    /// re-measuring during the settle window.
    @MainActor
    private func jumpToBottomWithFade(with proxy: ScrollViewProxy) {
        // Optimistically mark pinned so the floating pill / count badge hide right
        // away. `settle` at the end confirms reachedBottom and un-pins only if the
        // scroll actually failed to land.
        isPinnedToBottom = true
        newMessageCount = 0
        pendingPinnedScroll = false
        shouldAutoScrollOnNextLayout = false

        jumpFadeTask?.cancel()
        jumpFadeTask = Task { @MainActor in
            withAnimation(.easeIn(duration: 0.10)) {
                contentOpacity = 0
            }
            try? await Task.sleep(for: .milliseconds(110))
            guard !Task.isCancelled else {
                withAnimation(.easeOut(duration: 0.12)) { contentOpacity = 1 }
                return
            }

            // Instant jump while invisible — disablesAnimations transaction inside
            // performScrollToBottom keeps SwiftUI from interpolating the offset.
            performScrollToBottom(with: proxy)

            // Settle pass: MarkdownUI rows we skipped over (user was scrolled up)
            // may re-measure now that they're near the viewport.
            await settleInitialBottomLock(with: proxy)
            guard !Task.isCancelled else {
                withAnimation(.easeOut(duration: 0.12)) { contentOpacity = 1 }
                return
            }

            let reachedBottom = await confirmBottomPosition(
                with: proxy,
                delays: InitialScrollTiming.finalVerificationDelays
            )
            guard !Task.isCancelled else {
                withAnimation(.easeOut(duration: 0.12)) { contentOpacity = 1 }
                return
            }
            isPinnedToBottom = reachedBottom
            if reachedBottom {
                newMessageCount = 0
            }

            withAnimation(.easeOut(duration: 0.18)) {
                contentOpacity = 1
            }
        }
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

    private func performScrollToBottom(
        with proxy: ScrollViewProxy,
        preferAnchorScroll: Bool = false,
        animated: Bool = false
    ) {
        programmaticScrollResetTask?.cancel()
        isPerformingProgrammaticScroll = true
        let usedAppKit: Bool
        if preferAnchorScroll {
            usedAppKit = false
        } else {
            usedAppKit = scrollController.scrollToBottom(animated: animated)
        }
        if !usedAppKit {
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
    }

    private var chatMaxHeight: CGFloat {
        let h = maxPanelHeight > 0 ? CGFloat(maxPanelHeight) : 400
        return h - 80
    }

    private var shouldShowNewMessagesButton: Bool {
        hasCompletedInitialScroll && !isPinnedToBottom
    }

    /// Inline completion hint (state A): user is pinned to bottom and a completion
    /// arrived for this session. State B (not pinned) piggy-backs on the existing
    /// floating "N new messages" pill via `completionPulse`.
    private var shouldShowInlineCompletionHint: Bool {
        guard appState.inlineCompletionSessionId == sessionId else { return false }
        guard isPinnedToBottom else { return false }
        // Don't steal bottomBar real estate from Approval/Question cards.
        if let p = appState.pendingPermission, (p.event.sessionId ?? "default") == sessionId { return false }
        if let q = appState.pendingQuestion, (q.event.sessionId ?? "default") == sessionId { return false }
        return true
    }

    private var isCompletionPulseActive: Bool {
        appState.inlineCompletionSessionId == sessionId && !isPinnedToBottom
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
            Markdown(chatStripDirectives(text))
                .markdownTheme(pixelMarkdownTheme)
                .markdownSoftBreakMode(.lineBreak)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// Pixel-style MarkdownUI theme — monospaced throughout, white on dark, tight spacing.
    /// Tracks `fontSize` so settings changes propagate.
    private var pixelMarkdownTheme: Theme {
        let base = fontSize + 2
        return Theme()
            .text {
                FontFamilyVariant(.monospaced)
                FontSize(base)
                ForegroundColor(.white.opacity(0.9))
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.95))
                BackgroundColor(.white.opacity(0.12))
                ForegroundColor(Color(red: 0.95, green: 0.82, blue: 0.55))
            }
            .strong {
                FontWeight(.bold)
                ForegroundColor(.white.opacity(0.98))
            }
            .emphasis {
                FontStyle(.italic)
            }
            .link {
                ForegroundColor(Color(red: 0.46, green: 0.78, blue: 1.0))
                UnderlineStyle(.single)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(.em(1.25))
                    }
                    .markdownMargin(top: 10, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(.em(1.15))
                    }
                    .markdownMargin(top: 10, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(1.05))
                    }
                    .markdownMargin(top: 8, bottom: 4)
            }
            .paragraph { configuration in
                configuration.label
                    .lineSpacing(4)
                    .markdownMargin(top: 0, bottom: 6)
            }
            .codeBlock { configuration in
                configuration.label
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.92))
                        ForegroundColor(.white.opacity(0.92))
                    }
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
                    .markdownMargin(top: 6, bottom: 6)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 2, bottom: 2)
            }
            .blockquote { configuration in
                configuration.label
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 2)
                    }
                    .markdownTextStyle {
                        ForegroundColor(.white.opacity(0.7))
                        FontStyle(.italic)
                    }
                    .markdownMargin(top: 6, bottom: 6)
            }
            .table { configuration in
                configuration.label
                    .markdownTableBackgroundStyle(
                        .alternatingRows(Color.clear, Color.white.opacity(0.03))
                    )
                    .markdownTableBorderStyle(
                        .init(color: .white.opacity(0.15))
                    )
                    .markdownMargin(top: 6, bottom: 6)
            }
            .thematicBreak {
                Divider()
                    .overlay(Color.white.opacity(0.15))
                    .markdownMargin(top: 8, bottom: 8)
            }
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

    private var hasVisibleSessionHistory: Bool {
        !session.recentMessages.isEmpty
            || !(session.lastUserPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(session.lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
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

        applyStateChanges()
    }

    private func sendMessage(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
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
        shouldAutoScrollOnNextLayout = true
        pendingPinnedScroll = true
        sendTriggeredScrollSettle = true
        pendingUserMessages.append(pendingMessage)
        Task { @MainActor in
            if watchedTranscriptPath == nil {
                startTranscriptDiscovery()
            }
        }
        Task.detached {
            await MessageSender.send(text, to: session, sessionId: sessionId)
        }
    }

enum SessionMessageBarSupport {
    static func canShow(for session: SessionSnapshot) -> Bool {
        MessageSender.supportedTransport(for: session, resolveTTYIfNeeded: false) != nil
    }
}

struct SessionMessageInputBar: View {
    let session: SessionSnapshot
    let sessionId: String
    var appState: AppState
    let fontSize: CGFloat
    var onFocusChange: ((Bool) -> Void)? = nil
    var onSubmitText: ((String) -> Void)? = nil
    var outerHorizontalPadding: CGFloat = 18
    var outerTopPadding: CGFloat = 10
    var outerBottomPadding: CGFloat = 14

    @State private var inputFocusRequest = 0
    @State private var measuredInputHeight: CGFloat = 24

    private var editorFont: NSFont {
        .monospacedSystemFont(ofSize: fontSize + 1, weight: .regular)
    }

    private var inputHeightRange: (min: CGFloat, max: CGFloat) {
        ChatInputMetrics.heightRange(for: editorFont)
    }

    /// Draft lives on AppState so it survives when the view is torn down (e.g. session list
    /// toggle, chat↔approval swap). Prior to this we used `@State` and lost the in-progress
    /// message every time SwiftUI recreated the view.
    private var messageInputBinding: Binding<String> {
        Binding(
            get: { appState.pendingInputText[sessionId] ?? "" },
            set: { appState.pendingInputText[sessionId] = $0 }
        )
    }

    private var placeholderText: String {
        switch session.source {
        case "codex": return L10n.shared["chat_placeholder_codex"]
        default: return L10n.shared["chat_placeholder"]
        }
    }

    var body: some View {
        let range = inputHeightRange
        ChatInputEditor(
            text: messageInputBinding,
            font: editorFont,
            placeholderText: placeholderText,
            focusRequest: inputFocusRequest,
            maxHeight: range.max,
            onSubmit: submitMessage,
            onFocusChange: onFocusChange,
            onHeightChange: { newHeight in
                let clamped = min(max(newHeight, range.min), range.max)
                if abs(clamped - measuredInputHeight) > 0.5 {
                    measuredInputHeight = clamped
                }
            }
        )
        .frame(height: min(max(measuredInputHeight, range.min), range.max))
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
        .padding(.horizontal, outerHorizontalPadding)
        .padding(.top, outerTopPadding)
        .padding(.bottom, outerBottomPadding)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            inputFocusRequest += 1
        }
        .onHover { _ in }
        .onDisappear {
            DispatchQueue.main.async {
                onFocusChange?(false)
            }
        }
    }

    private func submitMessage() {
        let text = (appState.pendingInputText[sessionId] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        appState.pendingInputText[sessionId] = ""
        if let onSubmitText {
            onSubmitText(text)
        } else {
            Task.detached {
                await MessageSender.send(text, to: session, sessionId: sessionId)
            }
        }
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

}

struct DisplayedChatMessage: Identifiable, Equatable {
    let id: String
    let message: SessionChatMessage
}

struct PendingMessageReconciliation: Equatable {
    let unresolvedPending: [SessionChatMessage]
    let matchedDisplayIDs: [String: String]
}

/// Drives an NSScrollView to its bottom via a per-frame spring integration.
/// Target is recomputed every tick so the animation keeps tracking the bottom as
/// lazily-rendered content grows the document; it terminates only once the spring
/// is at rest AND the current bottom has stopped moving.
private final class ScrollSpringAnimator {
    // Spring params roughly match SwiftUI's .spring(response: 0.45, dampingFraction: 0.85):
    // slight overshoot, snappy arrival. Y-clamp at maxY hides the overshoot visually.
    private let stiffness: CGFloat = 200
    private let damping: CGFloat = 24
    private let mass: CGFloat = 1.0

    private weak var scrollView: NSScrollView?
    private var timer: Timer?
    private var currentY: CGFloat = 0
    private var velocity: CGFloat = 0
    private var targetY: CGFloat = 0
    private var lastTime: CFTimeInterval = 0

    var onFinish: (() -> Void)?

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
    }

    func start(to target: CGFloat) {
        guard let scrollView else { return }
        currentY = scrollView.contentView.bounds.origin.y
        velocity = 0
        targetY = target
        lastTime = CACurrentMediaTime()

        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.step()
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func cancel() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        onFinish?()
    }

    private func step() {
        guard let scrollView, let documentView = scrollView.documentView else {
            cancel()
            return
        }

        let now = CACurrentMediaTime()
        // Clamp dt so a stalled main thread doesn't produce a giant integration step.
        let dt = max(CGFloat(1.0 / 240.0), min(CGFloat(now - lastTime), CGFloat(1.0 / 30.0)))
        lastTime = now

        let viewportHeight = scrollView.contentView.bounds.height
        let documentHeight = documentView.bounds.height
        let maxY = max(0, documentHeight - viewportHeight)
        // Recompute target every tick — keeps us aimed at the current bottom as
        // MarkdownUI blocks finish laying out and grow the document.
        targetY = maxY

        let displacement = currentY - targetY
        let springForce = -stiffness * displacement
        let dampingForce = -damping * velocity
        let acceleration = (springForce + dampingForce) / mass
        velocity += acceleration * dt
        currentY += velocity * dt

        let visualY = min(max(currentY, 0), maxY)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: visualY))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        if abs(displacement) < 0.5 && abs(velocity) < 0.5 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            cancel()
        }
    }
}

final class SessionChatScrollController: ObservableObject {
    /// Shared threshold for "at bottom" detection — keeps observer and controller consistent.
    static let bottomThreshold: CGFloat = 24

    private weak var scrollView: NSScrollView?
    private var floatingButton: NSButton?
    private var springAnimator: ScrollSpringAnimator?
    private var liveScrollObserverToken: NSObjectProtocol?
    var onNewMessagesTapped: (() -> Void)?

    var documentHeight: CGFloat? {
        scrollView?.documentView?.bounds.height
    }

    var isAtBottom: Bool {
        guard let scrollView else { return false }
        let visibleMaxY = scrollView.contentView.documentVisibleRect.maxY
        let documentMaxY = scrollView.documentView?.bounds.maxY ?? 0
        return visibleMaxY >= documentMaxY - Self.bottomThreshold
    }

    var isAnimatingScroll: Bool { springAnimator != nil }

    /// Set when a live-scroll gesture cancelled the spring. Readers (the waiting
    /// scrollToBottom Task) use this to skip the follow-up "snap to bottom" and
    /// avoid fighting the user's scroll input. Cleared when a new animation starts.
    private(set) var wasSpringInterruptedByUser: Bool = false

    func attach(_ scrollView: NSScrollView) {
        self.scrollView = scrollView
        if let token = liveScrollObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        // Cancel any in-flight spring the moment the user starts a live scroll
        // (trackpad pan, scroll wheel) so we don't fight their input.
        liveScrollObserverToken = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.springAnimator != nil else { return }
            self.wasSpringInterruptedByUser = true
            self.cancelSpringAnimation()
        }
    }

    deinit {
        if let token = liveScrollObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
        springAnimator?.cancel()
    }

    private func cancelSpringAnimation() {
        springAnimator?.cancel()
        springAnimator = nil
    }

    // MARK: - Floating "new messages" button (AppKit-native)
    // SwiftUI buttons in overlays don't receive clicks in this borderless panel
    // because hitTest returns NotchHostingView (not the button's backing view).
    // An AppKit NSButton added via addFloatingSubview IS returned by hitTest,
    // and HoverBlockingContainerView.mouseDown forwards the event to it.

    func showNewMessagesButton(count: Int, accentColor: NSColor, fontSize: CGFloat, completionPulse: Bool = false) {
        guard let scrollView else { return }

        if floatingButton == nil {
            let btn = NSButton()
            btn.bezelStyle = .recessed
            btn.isBordered = false
            btn.wantsLayer = true
            btn.target = self
            btn.action = #selector(floatingButtonTapped)
            btn.layer?.cornerRadius = 17
            scrollView.addFloatingSubview(btn, for: .vertical)
            floatingButton = btn
        }

        guard let btn = floatingButton else { return }
        let baseTitle = count > 0
            ? String(format: L10n.shared["chat_new_messages_count"], count)
            : "\(L10n.shared["chat_scroll_to_bottom"])  ↓"
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let attrStr = NSMutableAttributedString()
        if completionPulse {
            attrStr.append(NSAttributedString(
                string: "●  ",
                attributes: [
                    .font: font,
                    .foregroundColor: accentColor.withAlphaComponent(0.95),
                ]
            ))
        }
        attrStr.append(NSAttributedString(
            string: baseTitle,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.96),
            ]
        ))
        btn.attributedTitle = attrStr
        btn.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        btn.layer?.borderColor = accentColor.withAlphaComponent(0.55).cgColor
        btn.layer?.borderWidth = 1
        btn.sizeToFit()
        let btnSize = NSSize(width: btn.frame.width + 24, height: 34)
        let scrollBounds = scrollView.bounds
        btn.frame = NSRect(
            x: (scrollBounds.width - btnSize.width) / 2,
            y: scrollBounds.height - btnSize.height - 16,
            width: btnSize.width,
            height: btnSize.height
        )
        btn.isHidden = false
    }

    func hideNewMessagesButton() {
        floatingButton?.isHidden = true
    }

    @objc private func floatingButtonTapped() {
        onNewMessagesTapped?()
    }

    @discardableResult
    func scrollToBottom(animated: Bool = false) -> Bool {
        guard let scrollView, let documentView = scrollView.documentView else { return false }

        let viewportHeight = scrollView.contentView.bounds.height
        let documentHeight = documentView.bounds.height
        let targetY = max(0, documentHeight - viewportHeight)

        if animated {
            if springAnimator == nil {
                wasSpringInterruptedByUser = false
                let animator = ScrollSpringAnimator(scrollView: scrollView)
                animator.onFinish = { [weak self, weak animator] in
                    // Only clear if still the active animator — guards against late
                    // callbacks after a cancel + restart.
                    if self?.springAnimator === animator {
                        self?.springAnimator = nil
                    }
                }
                springAnimator = animator
                animator.start(to: targetY)
            }
            // Existing animator auto-retargets via its per-tick recompute, so no-op.
            return true
        }

        // Non-animated callers during an in-flight spring would normally snap and
        // interrupt the animation. The animator auto-tracks the current bottom, so
        // we can safely let it keep running instead of snapping mid-flight.
        if springAnimator != nil {
            return true
        }

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
        let origin = NSPoint(x: 0, y: maxY)
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
    private var pendingAtBottom: Bool?
    private var throttleWorkItem: DispatchWorkItem?
    private var lastCallbackTime: CFAbsoluteTime = 0
    private static let throttleInterval: TimeInterval = 0.12

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
        DispatchQueue.main.async { [weak self, weak scrollView] in
            guard let self, let scrollView, self.observedScrollView === scrollView else { return }
            self.onResolveScrollView?(scrollView)
        }
        notifyScrollPosition()
    }

    private func detach() {
        throttleWorkItem?.cancel()
        throttleWorkItem = nil
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
        let atBottom = visibleMaxY >= documentMaxY - SessionChatScrollController.bottomThreshold
        pendingAtBottom = atBottom
        throttleWorkItem?.cancel()

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastCallbackTime >= Self.throttleInterval {
            lastCallbackTime = now
            pendingAtBottom = nil
            onScroll?(atBottom)
        } else {
            let remaining = Self.throttleInterval - (now - lastCallbackTime)
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, let pending = self.pendingAtBottom else { return }
                self.pendingAtBottom = nil
                self.lastCallbackTime = CFAbsoluteTimeGetCurrent()
                self.onScroll?(pending)
            }
            throttleWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: workItem)
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

enum ChatInputMetrics {
    static let minimumHeight: CGFloat = 24
    static let visibleLineLimit = 3
    static let verticalInsets: CGFloat = 8

    static func heightRange(for font: NSFont) -> (min: CGFloat, max: CGFloat) {
        // Match NSTextView's actual line metrics. ascender/descender/leading
        // undercounts the monospaced system font enough to make exactly 3 lines
        // overflow by 1px, which exposed a useless scroller and clipped selection.
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let maxHeight = ceil(lineHeight * CGFloat(visibleLineLimit)) + verticalInsets
        return (minimumHeight, max(maxHeight, minimumHeight))
    }
}

/// Multi-line text input: Enter sends, Shift+Enter inserts newline.
private struct ChatInputEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var placeholderText: String
    var focusRequest: Int
    var maxHeight: CGFloat = .greatestFiniteMagnitude
    var onSubmit: () -> Void
    var onFocusChange: ((Bool) -> Void)? = nil
    var onHeightChange: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller?.controlSize = .mini
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = false
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
        // Manual sizing: we drive both width and height explicitly from reportHeight.
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        textView.minSize = .zero
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
        context.coordinator.onHeightChange = onHeightChange
        context.coordinator.maxHeight = maxHeight
        textView.onFocusChange = context.coordinator.onFocusChange
        context.coordinator.updatePlaceholder()
        DispatchQueue.main.async {
            context.coordinator.reportHeight()
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! ChatInputTextView
        if textView.string != text {
            context.coordinator.isApplyingExternalText = true
            textView.string = text
            context.coordinator.isApplyingExternalText = false
            context.coordinator.updatePlaceholder()
        }
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onFocusChange = onFocusChange
        context.coordinator.onHeightChange = onHeightChange
        context.coordinator.maxHeight = maxHeight
        textView.onFocusChange = context.coordinator.onFocusChange
        context.coordinator.reportHeight()
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
        var onFocusChange: ((Bool) -> Void)?
        var onHeightChange: ((CGFloat) -> Void)?
        var maxHeight: CGFloat = .greatestFiniteMagnitude
        var placeholderAttr: NSAttributedString?
        weak var textView: NSTextView?
        private var placeholderView: NSTextField?
        var lastFocusRequest: Int
        var isApplyingExternalText = false
        private var lastReportedHeight: CGFloat = -1

        init(_ parent: ChatInputEditor) {
            self.parent = parent
            self.onSubmit = parent.onSubmit
            self.onFocusChange = parent.onFocusChange
            self.onHeightChange = parent.onHeightChange
            self.maxHeight = parent.maxHeight
            self.lastFocusRequest = parent.focusRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            guard !isApplyingExternalText else {
                updatePlaceholder()
                reportHeight()
                return
            }
            // Keep the SwiftUI/AppState binding in sync before reportHeight triggers
            // a layout-driven updateNSView. An async write lets the old binding value
            // bounce back into the editor, which shows up as "delete twice to clear".
            parent.text = tv.string
            updatePlaceholder()
            reportHeight()
        }

        func reportHeight() {
            guard let tv = textView,
                  let scrollView = tv.enclosingScrollView,
                  let layoutManager = tv.layoutManager,
                  let textContainer = tv.textContainer else { return }

            // 1. Match textView width to the clip view before measuring — width
            //    determines line wrapping, so usedRect is only valid afterwards.
            let targetWidth = scrollView.contentSize.width
            if targetWidth > 0, abs(tv.frame.width - targetWidth) > 0.5 {
                tv.frame.size.width = targetWidth
            }

            // 2. Force full layout of all glyphs so usedRect (and selectAll)
            //    reflect the entire text, not just what's on screen.
            layoutManager.ensureLayout(for: textContainer)
            let glyphRange = layoutManager.glyphRange(for: textContainer)
            _ = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            let insets = tv.textContainerInset.height * 2
            let contentHeight = ceil(used.height + insets)

            // 3. When content fits within the cap, match clip size exactly to
            //    avoid the scroller flickering on. When it overflows, size the
            //    document to the full height so scrolling has room.
            let clipHeight = scrollView.contentSize.height
            let fitsWithinCap = contentHeight <= maxHeight + 0.5
            let newTextViewHeight: CGFloat = fitsWithinCap
                ? max(contentHeight, clipHeight)
                : contentHeight
            if abs(tv.frame.height - newTextViewHeight) > 0.5 {
                tv.frame.size.height = newTextViewHeight
            }
            let shouldShowScroller = !fitsWithinCap
            if scrollView.hasVerticalScroller != shouldShowScroller {
                scrollView.hasVerticalScroller = shouldShowScroller
            }

            let clamped = min(contentHeight, maxHeight)
            if abs(clamped - lastReportedHeight) > 0.5 {
                lastReportedHeight = clamped
                onHeightChange?(clamped)
            }
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
    var onFocusChange: ((Bool) -> Void)?

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

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            DispatchQueue.main.async {
                self.onFocusChange?(true)
            }
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            suppressAutomaticFocus = true
            DispatchQueue.main.async {
                self.onFocusChange?(false)
            }
        }
        return resigned
    }
}

// MARK: - Message Sender

enum MessageSender {
    enum Transport {
        case tmux(pane: String, tmuxEnv: String?)
        case kaku(paneId: String?, tty: String?, cwd: String?)
        case ghostty(tty: String?, cwd: String?)
        case iterm2(itermSessionId: String, tty: String?)
        case terminalApp(tty: String)
        case wezterm(tty: String?, cwd: String?)
        case kitty(windowId: String)
    }

    static func supportedTransport(
        for session: SessionSnapshot,
        resolveTTYIfNeeded: Bool = true,
        ttyResolver: (() -> String?)? = nil
    ) -> Transport? {
        guard session.isClaude || session.isCodex else { return nil }
        // Priority: tmux first — tmux send-keys is more reliable than routing through
        // the host terminal, even when that host is Kaku/Ghostty/iTerm2/etc.
        if let pane = session.tmuxPane?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pane.isEmpty {
            return .tmux(pane: pane, tmuxEnv: session.tmuxEnv)
        }
        let cwd = trimmedNonEmpty(session.cwd)
        let termBundleId = session.termBundleId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let termApp = session.termApp?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rawTTY = normalizeTTYPath(session.ttyPath)
        var cachedTTY = rawTTY
        var didResolveTTY = rawTTY != nil

        func tty() -> String? {
            if let cachedTTY {
                return cachedTTY
            }
            guard resolveTTYIfNeeded, !didResolveTTY else { return nil }
            didResolveTTY = true
            cachedTTY = normalizeTTYPath(ttyResolver?() ?? resolvedTTYPath(session: session))
            return cachedTTY
        }

        if termBundleId == "fun.tw93.kaku" || termApp == "kaku" {
            let paneId = trimmedNonEmpty(session.kakuPaneId)
            let tty = rawTTY ?? ((paneId == nil && cwd == nil) ? tty() : nil)
            if paneId != nil || tty != nil || cwd != nil {
                return .kaku(paneId: paneId, tty: tty, cwd: cwd)
            }
        }
        if termBundleId == "com.mitchellh.ghostty" || termApp == "ghostty" {
            let tty = rawTTY ?? (cwd == nil ? tty() : nil)
            if tty != nil || cwd != nil {
                return .ghostty(tty: tty, cwd: cwd)
            }
        }
        // iTerm2 — precise targeting requires a session UUID.
        if termBundleId == "com.googlecode.iterm2" || (termApp?.contains("iterm") ?? false) {
            if let iid = trimmedNonEmpty(session.itermSessionId) {
                return .iterm2(itermSessionId: iid, tty: rawTTY)
            }
        }
        // Terminal.app — requires a tty to match the right tab.
        if termBundleId == "com.apple.terminal" || termApp == "apple_terminal" || termApp == "terminal" {
            let tty = rawTTY ?? tty()
            if let tty {
                return .terminalApp(tty: tty)
            }
        }
        // WezTerm — pane resolved later via `wezterm cli list` using tty/cwd.
        if termBundleId == "com.github.wez.wezterm" || (termApp?.contains("wezterm") ?? false) {
            let tty = rawTTY ?? (cwd == nil ? tty() : nil)
            if tty != nil || cwd != nil {
                return .wezterm(tty: tty, cwd: cwd)
            }
        }
        // kitty — precise targeting requires a KITTY_WINDOW_ID.
        if termBundleId == "net.kovidgoyal.kitty" || termApp == "kitty" {
            if let wid = trimmedNonEmpty(session.kittyWindowId) {
                return .kitty(windowId: wid)
            }
        }
        return nil
    }

    static func send(_ text: String, to session: SessionSnapshot, sessionId: String? = nil) async {
        switch supportedTransport(for: session) {
        case let .tmux(pane, tmuxEnv):
            messageLog.info("send transport=tmux pane=\(pane, privacy: .public)")
            await sendViaTmux(text, pane: pane, tmuxEnv: tmuxEnv)
        case let .kaku(paneId, tty, cwd):
            messageLog.info("send transport=kaku paneId=\((paneId ?? "-"), privacy: .public) tty=\((tty ?? "-"), privacy: .public)")
            await sendViaKaku(text, paneId: paneId, tty: tty, cwd: cwd, source: session.source)
        case let .ghostty(tty, cwd):
            messageLog.info("send transport=ghostty sessionId=\((sessionId ?? "-"), privacy: .public) tty=\((tty ?? "-"), privacy: .public) cwd=\((cwd ?? "-"), privacy: .public)")
            await sendViaGhostty(text, tty: tty, cwd: cwd, sessionId: sessionId)
        case let .iterm2(iid, tty):
            messageLog.info("send transport=iterm2 iid=\(iid, privacy: .public) tty=\((tty ?? "-"), privacy: .public)")
            await sendViaITerm2(text, itermSessionId: iid, tty: tty)
        case let .terminalApp(tty):
            messageLog.info("send transport=terminalApp tty=\(tty, privacy: .public)")
            await sendViaTerminalApp(text, tty: tty)
        case let .wezterm(tty, cwd):
            messageLog.info("send transport=wezterm tty=\((tty ?? "-"), privacy: .public) cwd=\((cwd ?? "-"), privacy: .public)")
            await sendViaWezTerm(text, tty: tty, cwd: cwd, source: session.source)
        case let .kitty(windowId):
            messageLog.info("send transport=kitty windowId=\(windowId, privacy: .public)")
            await sendViaKitty(text, windowId: windowId, source: session.source)
        case nil:
            messageLog.warning("send transport=none source=\(session.source, privacy: .public)")
            return
        }
    }

    private static func sendViaTmux(_ text: String, pane: String, tmuxEnv: String?) async {
        guard let tmux = findTmuxBinary() else { return }
        if let tmuxStr = tmuxEnv, let socketPath = tmuxStr.split(separator: ",").first {
            let args = ["-S", String(socketPath), "send-keys", "-t", pane, "-l", text]
            _ = try? await shellRun(tmux, args: args)
            _ = try? await shellRun(tmux, args: ["-S", String(socketPath), "send-keys", "-t", pane, "Enter"])
            messageLog.info("tmux send completed via socket pane=\(pane, privacy: .public)")
            return
        }
        _ = try? await shellRun(tmux, args: ["send-keys", "-t", pane, "-l", text])
        _ = try? await shellRun(tmux, args: ["send-keys", "-t", pane, "Enter"])
        messageLog.info("tmux send completed pane=\(pane, privacy: .public)")
    }

    private static func sendViaGhostty(_ text: String, tty: String?, cwd: String?, sessionId: String?) async {
        let escapedText = escapeAppleScript(text)
        let escapedTTY = escapeAppleScript(tty ?? "")
        let trimmedCwd = (cwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd1 = stripTrailingSlashes(trimmedCwd)
        let cwd2 = stripTrailingSlashes(URL(fileURLWithPath: cwd1).resolvingSymlinksInPath().path)
        let dirName = (cwd1 as NSString).lastPathComponent
        let home = NSHomeDirectory()
        let tildeCwd: String = {
            if cwd1 == home { return "~" }
            if cwd1.hasPrefix(home + "/") {
                return "~" + String(cwd1.dropFirst(home.count))
            }
            return ""
        }()
        let escapedCwd1 = escapeAppleScript(cwd1)
        let escapedCwd2 = escapeAppleScript(cwd2)
        let escapedDirName = escapeAppleScript(dirName)
        let escapedTildeCwd = escapeAppleScript(tildeCwd)
        let escapedSessionIdPrefix = escapeAppleScript(String((sessionId ?? "").prefix(8)))
        let script = """
        tell application "Ghostty"
            set targetTerm to missing value

            if "\(escapedTTY)" is not "" then
                try
                    set ttyMatches to (every terminal whose tty is "\(escapedTTY)")
                    if (count of ttyMatches) > 0 then
                        set targetTerm to item 1 of ttyMatches
                    end if
                end try
            end if

            if targetTerm is missing value then
                set matches to {}
                if "\(escapedCwd1)" is not "" then
                    try
                        set matches to (every terminal whose working directory is "\(escapedCwd1)")
                    end try
                end if
                if (count of matches) = 0 and "\(escapedCwd2)" is not "" and "\(escapedCwd2)" is not "\(escapedCwd1)" then
                    try
                        set matches to (every terminal whose working directory is "\(escapedCwd2)")
                    end try
                end if
                if (count of matches) = 0 then
                    repeat with t in terminals
                        try
                            set tname to (name of t as text)
                            if ("\(escapedTildeCwd)" is not "" and tname contains "\(escapedTildeCwd)") or ("\(escapedCwd1)" is not "" and tname contains "\(escapedCwd1)") or ("\(escapedDirName)" is not "" and tname contains "\(escapedDirName)") then
                                set end of matches to t
                            end if
                        end try
                    end repeat
                end if

                if "\(escapedSessionIdPrefix)" is not "" then
                    repeat with t in matches
                        try
                            if name of t contains "\(escapedSessionIdPrefix)" then
                                set targetTerm to t
                                exit repeat
                            end if
                        end try
                    end repeat
                end if

                if targetTerm is missing value and (count of matches) > 0 then
                    set targetTerm to item 1 of matches
                end if
            end if

            if targetTerm is not missing value then
                focus targetTerm
                activate
                input text "\(escapedText)" to targetTerm
                delay 0.12
                send key "enter" to targetTerm
            end if
        end tell
        """
        do {
            _ = try await runOsaScript(script)
            messageLog.info("ghostty osascript completed")
        } catch {
            messageLog.error("ghostty osascript failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func findTmuxBinary() -> String? {
        for p in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private static func findKakuBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.config/kaku/zsh/bin/kaku",
            "/usr/local/bin/kaku",
            "/opt/homebrew/bin/kaku",
            "/Applications/Kaku.app/Contents/MacOS/kaku",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    private static func findWezTermBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/wezterm",
            "/usr/local/bin/wezterm",
            "/Applications/WezTerm.app/Contents/MacOS/wezterm",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    private static func findKittenBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/kitten",
            "/usr/local/bin/kitten",
            "/Applications/kitty.app/Contents/MacOS/kitten",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    // MARK: - iTerm2

    /// iTerm2 exposes `write text` on sessions; this is the native TUI-safe input path.
    /// We target by `unique id` when available (set by the Claude hook via ITERM_SESSION_ID),
    /// falling back to `tty` matching. Deliberately no "current session" fallback — better
    /// to noop than type into a random unrelated tab.
    private static func sendViaITerm2(_ text: String, itermSessionId: String, tty: String?) async {
        let escapedText = escapeAppleScript(text)
        let escapedId = escapeAppleScript(itermSessionId)
        let escapedTTY = escapeAppleScript(tty ?? "")
        let script = """
        tell application "iTerm2"
            set targetSession to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if (unique id of s as text) is "\(escapedId)" then
                                set targetSession to s
                                exit repeat
                            end if
                        end try
                    end repeat
                    if targetSession is not missing value then exit repeat
                end repeat
                if targetSession is not missing value then exit repeat
            end repeat

            if targetSession is missing value and "\(escapedTTY)" is not "" then
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                if (tty of s as text) is "\(escapedTTY)" then
                                    set targetSession to s
                                    exit repeat
                                end if
                            end try
                        end repeat
                        if targetSession is not missing value then exit repeat
                    end repeat
                    if targetSession is not missing value then exit repeat
                end repeat
            end if

            if targetSession is not missing value then
                tell targetSession to write text "\(escapedText)"
            end if
        end tell
        """
        do {
            _ = try await runOsaScript(script)
            messageLog.info("iterm2 osascript completed")
        } catch {
            messageLog.error("iterm2 osascript failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Terminal.app

    /// Terminal.app's `do script "..." in tab` injects text + newline into the tab's tty.
    /// Despite the name, when given an existing tab it does NOT spawn a shell — it just
    /// writes to the pty, which is what we want for the Claude/Codex TUI.
    private static func sendViaTerminalApp(_ text: String, tty: String) async {
        let escapedText = escapeAppleScript(text)
        let escapedTTY = escapeAppleScript(tty)
        let script = """
        tell application "Terminal"
            set targetTab to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if (tty of t as text) is "\(escapedTTY)" then
                            set targetTab to t
                            exit repeat
                        end if
                    end try
                end repeat
                if targetTab is not missing value then exit repeat
            end repeat
            if targetTab is not missing value then
                do script "\(escapedText)" in targetTab
            end if
        end tell
        """
        do {
            _ = try await runOsaScript(script)
            messageLog.info("terminal.app osascript completed")
        } catch {
            messageLog.error("terminal.app osascript failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - WezTerm

    /// Resolve a WezTerm pane id by listing panes and matching on tty_name or cwd,
    /// mirroring the kaku resolver. Returns the pane id as a string for `--pane-id`.
    private static func resolveWezTermPaneId(wezterm: String, tty: String?, cwd: String?) async -> String? {
        let output: String
        do {
            output = try await shellRun(wezterm, args: ["cli", "list", "--format", "json"])
        } catch {
            return nil
        }
        guard let data = output.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        func paneIdString(_ pane: [String: Any]) -> String? {
            if let n = pane["pane_id"] as? Int { return String(n) }
            if let s = pane["pane_id"] as? String { return s }
            return nil
        }

        let normalizedTTY = normalizeTTYPath(tty)
        if let normalizedTTY {
            for pane in panes {
                if let ptty = pane["tty_name"] as? String, ptty == normalizedTTY,
                   let id = paneIdString(pane) {
                    return id
                }
            }
        }

        if let targetCwd = trimmedNonEmpty(cwd).map({ stripTrailingSlashes($0) }) {
            for pane in panes {
                guard let raw = pane["cwd"] as? String else { continue }
                var path = raw
                if path.hasPrefix("file://") {
                    path = String(path.dropFirst("file://".count))
                }
                // wezterm cwds often include a trailing host component — strip it
                if let qIdx = path.firstIndex(of: "?") { path = String(path[..<qIdx]) }
                path = stripTrailingSlashes(path)
                if path == targetCwd, let id = paneIdString(pane) {
                    return id
                }
            }
        }

        return nil
    }

    private static func sendViaWezTerm(_ text: String, tty: String?, cwd: String?, source: String) async {
        guard let wezterm = findWezTermBinary() else {
            messageLog.error("wezterm binary not found")
            return
        }
        guard let paneId = await resolveWezTermPaneId(wezterm: wezterm, tty: tty, cwd: cwd) else {
            messageLog.error("wezterm: no pane id resolvable (tty=\((tty ?? "-"), privacy: .public))")
            return
        }

        do {
            try await sendRawTextBatches(
                via: wezterm,
                args: ["cli", "send-text", "--pane-id", paneId, "--no-paste"],
                batches: rawTerminalSendBatches(text: text, source: source)
            )
        } catch {
            messageLog.error("wezterm send-text failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        messageLog.info("wezterm send completed paneId=\(paneId, privacy: .public)")
    }

    // MARK: - kitty

    private static func sendViaKitty(_ text: String, windowId: String, source: String) async {
        guard let kitten = findKittenBinary() else {
            messageLog.error("kitten binary not found")
            return
        }

        do {
            try await sendRawTextBatches(
                via: kitten,
                args: ["@", "send-text", "--match", "id:\(windowId)", "--stdin"],
                batches: rawTerminalSendBatches(text: text, source: source)
            )
        } catch {
            messageLog.error("kitty send-text failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        messageLog.info("kitty send completed windowId=\(windowId, privacy: .public)")
    }

    private static func sendViaKaku(_ text: String, paneId: String?, tty: String?, cwd: String?, source: String) async {
        guard let kaku = findKakuBinary() else {
            messageLog.error("kaku binary not found")
            return
        }

        let resolvedPaneId: String
        if let explicit = paneId?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            resolvedPaneId = explicit
        } else if let matched = await resolveKakuPaneIdFromList(kaku: kaku, tty: tty, cwd: cwd) {
            resolvedPaneId = matched
        } else {
            messageLog.error("kaku: no pane id resolvable (tty=\((tty ?? "-"), privacy: .public))")
            return
        }

        do {
            try await sendRawTextBatches(
                via: kaku,
                args: ["cli", "send-text", "--pane-id", resolvedPaneId, "--no-paste"],
                batches: rawTerminalSendBatches(text: text, source: source)
            )
        } catch {
            messageLog.error("kaku send-text failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        messageLog.info("kaku send completed pane=\(resolvedPaneId, privacy: .public)")
    }

    private static func resolveKakuPaneIdFromList(kaku: String, tty: String?, cwd: String?) async -> String? {
        let output: String
        do {
            output = try await shellRun(kaku, args: ["cli", "list", "--format", "json"])
        } catch {
            return nil
        }
        guard let data = output.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        func paneIdString(_ pane: [String: Any]) -> String? {
            if let n = pane["pane_id"] as? Int { return String(n) }
            if let s = pane["pane_id"] as? String { return s }
            return nil
        }

        let normalizedTTY = normalizeTTYPath(tty)
        if let normalizedTTY {
            for pane in panes {
                if let ptty = pane["tty_name"] as? String, ptty == normalizedTTY,
                   let id = paneIdString(pane) {
                    return id
                }
            }
        }

        let targetCwd = trimmedNonEmpty(cwd).map { stripTrailingSlashes($0) }
        if let targetCwd {
            for pane in panes {
                guard let raw = pane["cwd"] as? String else { continue }
                var path = raw
                if path.hasPrefix("file://") {
                    path = String(path.dropFirst("file://".count))
                }
                path = stripTrailingSlashes(path)
                if path == targetCwd, let id = paneIdString(pane) {
                    return id
                }
            }
        }

        return nil
    }

    static func rawTerminalSendBatches(text: String, source: String) -> [String] {
        if source == "codex" {
            return [text, "\r"]
        }
        return [text + "\r"]
    }

    private static func sendRawTextBatches(via path: String, args: [String], batches: [String]) async throws {
        for batch in batches where !batch.isEmpty {
            _ = try await shellRunWithStdin(path, args: args, stdin: batch)
        }
    }

    private static func shellRunWithStdin(_ path: String, args: [String], stdin: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        process.standardInput = stdinPipe
        try process.run()
        if let data = stdin.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        return String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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

    private static func runOsaScript(_ source: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus == 0 {
            return out
        }
        throw OsaScriptError(stderr: err.isEmpty ? out : err, status: process.terminationStatus)
    }

    private static func escapeAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func stripTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func normalizeTTYPath(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value != "/dev/tty",
              value != "tty" else { return nil }
        if value.hasPrefix("/dev/") { return value }
        if value.hasPrefix("tty") || value.hasPrefix("pts/") {
            return "/dev/\(value)"
        }
        return value
    }

    private static func resolvedTTYPath(session: SessionSnapshot) -> String? {
        if let normalized = normalizeTTYPath(session.ttyPath) {
            return normalized
        }
        guard let pid = session.cliPid, pid > 0 else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "tty="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty, output != "??" else { return nil }
        return normalizeTTYPath(output)
    }

    private struct OsaScriptError: LocalizedError {
        let stderr: String
        let status: Int32

        var errorDescription: String? {
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "osascript exited with status \(status)"
            }
            return "osascript exited with status \(status): \(trimmed)"
        }
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
