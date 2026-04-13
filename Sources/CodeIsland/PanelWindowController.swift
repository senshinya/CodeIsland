import AppKit
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.codeisland", category: "Panel")
private let hostingLog = Logger(subsystem: "com.codeisland", category: "NotchHostingView")

private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Ensures first click on a nonactivatingPanel fires SwiftUI actions
/// instead of being consumed for key-window activation.
/// Also guards against NSHostingView constraint-update re-entrancy crash:
/// during updateConstraints(), SwiftUI may invalidate the view graph and
/// call setNeedsUpdateConstraints again, which AppKit forbids.
private class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// When true, the deferred handler is setting super — don't re-defer.
    private var applyingDeferred = false

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Borderless transparent panels can otherwise return nil for empty SwiftUI regions,
    /// which lets hover/click tracking fall through to apps beneath the panel.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil { return hit }
        return bounds.contains(point) ? self : nil
    }

    /// Always defer `needsUpdateConstraints = true` to the next run-loop turn.
    /// During AppKit's display-cycle (constraint-update or layout phases),
    /// calling setNeedsUpdateConstraints synchronously re-enters
    /// `_postWindowNeedsUpdateConstraints` and throws.  Deferring avoids
    /// that entirely; the one-tick delay is imperceptible.
    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set {
            if applyingDeferred {
                super.needsUpdateConstraints = newValue
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.applySuperNeedsUpdateConstraints(newValue)
            }
        }
    }

    private func applySuperNeedsUpdateConstraints(_ value: Bool) {
        applyingDeferred = true
        super.needsUpdateConstraints = value
        applyingDeferred = false
    }

    override var needsLayout: Bool {
        get { super.needsLayout }
        set {
            if applyingDeferred {
                super.needsLayout = newValue
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.applySuperNeedsLayout(newValue)
            }
        }
    }

    private func applySuperNeedsLayout(_ value: Bool) {
        applyingDeferred = true
        super.needsLayout = value
        applyingDeferred = false
    }
}

enum PanelMouseEventRouting {
    static func continuedGestureTarget(for view: NSView?) -> NSView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        if let scroller = view as? NSScroller { return scroller }
        if let control = view as? NSControl { return control }
        if let scrollView = view as? NSScrollView { return scrollView }
        if let clipView = view as? NSClipView,
           let scrollView = clipView.superview as? NSScrollView {
            return scrollView
        }
        return nil
    }

    static func scrollTarget(for view: NSView?) -> NSView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView {
            return textView.enclosingScrollView ?? textView
        }
        if let scroller = view as? NSScroller { return scroller }
        if let scrollView = view as? NSScrollView { return scrollView }
        if let clipView = view as? NSClipView,
           let scrollView = clipView.superview as? NSScrollView {
            return scrollView
        }
        if let scrollView = view.enclosingScrollView {
            return scrollView
        }
        guard !isHostedSwiftUIView(view) else { return nil }
        return view
    }

    static func isHostedSwiftUIView(_ view: NSView) -> Bool {
        var currentView: NSView? = view
        while let view = currentView {
            if classChainContainsHostingView(type(of: view)) {
                return true
            }
            currentView = view.superview
        }
        return false
    }

    private static func classChainContainsHostingView(_ cls: AnyClass?) -> Bool {
        var currentClass: AnyClass? = cls
        while let current = currentClass {
            if NSStringFromClass(current).contains("NSHostingView") {
                return true
            }
            currentClass = class_getSuperclass(current)
        }
        return false
    }
}

private final class HoverBlockingContainerView<Content: View>: NSView {
    let hostingView: NotchHostingView<Content>
    let appState: AppState
    private var blockingTrackingArea: NSTrackingArea?
    private var isHandlingMouseDown = false
    private var isHandlingMouseUp = false
    private weak var activeMouseTarget: NSView?

    init(hostingView: NotchHostingView<Content>, appState: AppState) {
        self.hostingView = hostingView
        self.appState = appState
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let converted = convert(point, to: hostingView)
        if let hit = hostingView.hitTest(converted) {
            return hit
        }
        return bounds.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let blockingTrackingArea {
            removeTrackingArea(blockingTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        blockingTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        appState.isPanelHovered = true
        window?.makeKey()
        NSApp.activate(ignoringOtherApps: false)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        appState.isPanelHovered = false
        super.mouseExited(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isHandlingMouseDown else {
            super.mouseDown(with: event)
            return
        }
        isHandlingMouseDown = true
        defer { isHandlingMouseDown = false }

        if shouldInterceptChatBack(at: event.locationInWindow) {
            withAnimation(NotchAnimation.open) {
                appState.surface = .sessionList
            }
            return
        }
        forwardMouseDown(event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let activeMouseTarget {
            activeMouseTarget.mouseDragged(with: event)
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard !isHandlingMouseUp else {
            super.mouseUp(with: event)
            return
        }
        isHandlingMouseUp = true
        defer { isHandlingMouseUp = false }

        let target = activeMouseTarget
        activeMouseTarget = nil
        if let target {
            target.mouseUp(with: event)
        } else {
            super.mouseUp(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if let scrollTarget = PanelMouseEventRouting.scrollTarget(
            for: forwardedHitView(at: event.locationInWindow)
        ) {
            scrollTarget.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private func forwardMouseDown(_ event: NSEvent) {
        // Borderless NSPanel sends all mouseDown to the content view.
        // Forward to the actual hit-tested view so AppKit controls
        // (NSButton, NSTextField, NSScroller, etc.) receive the full gesture.
        if let hitView = forwardedHitView(at: event.locationInWindow) {
            activeMouseTarget = PanelMouseEventRouting.continuedGestureTarget(for: hitView)
            hitView.mouseDown(with: event)
        } else {
            activeMouseTarget = nil
            super.mouseDown(with: event)
        }
    }

    private func forwardedHitView(at windowPoint: NSPoint) -> NSView? {
        let localPoint = convert(windowPoint, from: nil)
        guard let hitView = hitTest(localPoint), hitView !== self, hitView !== hostingView else {
            return nil
        }
        return hitView
    }

    private func shouldInterceptChatBack(at windowPoint: NSPoint) -> Bool {
        guard case .chatHistory = appState.surface else { return false }
        let localPoint = convert(windowPoint, from: nil)
        let backRect = NSRect(x: 0, y: 32, width: 260, height: 36)
        return backRect.contains(localPoint)
    }
}

struct PanelScreenHopFrames {
    let outgoing: NSRect
    let incoming: NSRect
}

struct PanelScreenHopMotion {
    let outgoingOffset: CGFloat
    let incomingOffset: CGFloat
    let fadeOutDuration: TimeInterval
    let incomingPauseDuration: TimeInterval
    let fadeInDuration: TimeInterval
}

@MainActor
class PanelWindowController: NSObject, NSWindowDelegate {
    private enum ScreenHopMetrics {
        static let outgoingOffset: CGFloat = 18
        static let incomingOffset: CGFloat = 30
        static let fadeOutDuration: TimeInterval = 0.14
        static let incomingPauseDuration: TimeInterval = 0.06
        static let fadeInDuration: TimeInterval = 0.34
    }

    nonisolated static func screenHopMotion() -> PanelScreenHopMotion {
        PanelScreenHopMotion(
            outgoingOffset: ScreenHopMetrics.outgoingOffset,
            incomingOffset: ScreenHopMetrics.incomingOffset,
            fadeOutDuration: ScreenHopMetrics.fadeOutDuration,
            incomingPauseDuration: ScreenHopMetrics.incomingPauseDuration,
            fadeInDuration: ScreenHopMetrics.fadeInDuration
        )
    }

    private var panel: NSPanel?
    private var hostingView: NotchHostingView<NotchPanelView>?
    private let appState: AppState

    nonisolated static func screenHopFrames(
        oldFrame: NSRect,
        newFrame: NSRect
    ) -> PanelScreenHopFrames {
        let motion = screenHopMotion()
        return PanelScreenHopFrames(
            outgoing: oldFrame.offsetBy(dx: 0, dy: motion.outgoingOffset),
            incoming: newFrame.offsetBy(dx: 0, dy: motion.incomingOffset)
        )
    }

    private func panelSize(for screen: NSScreen) -> NSSize {
        let maxSessions = CGFloat(max(2, UserDefaults.standard.integer(forKey: SettingsKey.maxVisibleSessions)))
        let maxH = max(300, maxSessions * 90 + 60)
        let screenW = screen.frame.width
        let customExpandedWidth = UserDefaults.standard.double(forKey: SettingsKey.expandedWidth)
        let baseWidth = customExpandedWidth > 0 ? CGFloat(customExpandedWidth) : CGFloat(SettingsDefaults.expandedWidth)
        // Add 30px margin for the NotchPanelShape wing extensions (topExtension up to 14px each side)
        let width = min(baseWidth + 30, screenW - 10)
        return NSSize(width: width, height: maxH)
    }

    private var panelSize: NSSize {
        panelSize(for: chosenScreen())
    }

    private var visibilityTimer: Timer?
    private var autoScreenPoller: Timer?
    private var fullscreenPoller: Timer?
    private var sessionObservationTask: Task<Void, Never>?
    private var fullscreenLatch = false
    private var settingsObservers: [NSObjectProtocol] = []
    private var globalClickMonitor: Any?
    private var lastChosenScreenSignature = ""
    private var isAnimatingScreenHop = false
    private var dragStartMouseX: CGFloat?
    private var dragStartPanelX: CGFloat?
    private var isDraggingPanel = false
    private var localDragMonitor: Any?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func showPanel() {
        let screen = chosenScreen()
        let contentView = makeHostingView(for: screen)

        let size = panelSize
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.acceptsMouseMovedEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .readOnly
        panel.contentView = contentView
        panel.delegate = self

        self.panel = panel
        self.lastChosenScreenSignature = ScreenDetector.signature(for: screen)

        setupHorizontalDragMonitor()
        updatePosition()
        panel.orderFrontRegardless()

        // Screen change observer
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCurrentScreen(forceRebuild: true)
                // macOS may not have finished updating NSScreen.screens when the notification fires.
                // Rebuild again after a short delay to pick up the final screen configuration.
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.refreshCurrentScreen(forceRebuild: true)
            }
        }

        // Active space change — check fullscreen
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.refreshCurrentScreen()
                if self.isActiveSpaceFullscreen() {
                    self.fullscreenLatch = true
                    self.updateVisibility()
                    self.startFullscreenExitPoller()
                } else if !self.fullscreenLatch {
                    self.updateVisibility()
                }
                // If latch is set but not detected: ignore (poller will handle exit)
            }
        }

        // Frontmost app change
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.refreshCurrentScreen()
                if !self.fullscreenLatch { self.updateVisibility() }
            }
        }

        // Observe session changes via @Observable tracking
        sessionObservationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                withObservationTracking {
                    _ = self?.appState.sessions
                    _ = self?.appState.surface
                } onChange: {
                    Task { @MainActor in self?.updateVisibility() }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        // Observe settings changes (display choice, panel height)
        observeSettingsChanges()
        configureAutoScreenPolling()

        // Global click monitor: close panel + repost click when clicking outside
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self = self, self.appState.surface.isExpanded else { return }
                // Don't close during approval/question
                switch self.appState.surface {
                case .approvalCard, .questionCard: return
                default: break
                }
                // Don't collapse if click is within the panel frame (event leaked on external display)
                if let panelFrame = self.panel?.frame {
                    let clickLocation = NSEvent.mouseLocation
                    if panelFrame.contains(clickLocation) { return }
                }
                withAnimation(NotchAnimation.close) {
                    self.appState.surface = .collapsed
                    self.appState.cancelCompletionQueue()
                }
            }
        }
    }

    private func makeHostingView(for screen: NSScreen) -> HoverBlockingContainerView<NotchPanelView> {
        let hasNotch = ScreenDetector.screenHasNotch(screen)
        let notchHeight = ScreenDetector.topBarHeight(for: screen)
        let notchW = ScreenDetector.notchWidth(for: screen)

        let rootView = NotchPanelView(
            appState: appState,
            hasNotch: hasNotch,
            notchHeight: notchHeight,
            notchW: notchW,
            screenWidth: screen.frame.width
        )
        let hostingView = NotchHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        self.hostingView = hostingView
        return HoverBlockingContainerView(hostingView: hostingView, appState: appState)
    }

    /// Rebuild the SwiftUI view when the target screen changes
    /// (notchHeight, notchWidth, hasNotch may be different)
    private func rebuildForCurrentScreen(_ screen: NSScreen) {
        guard let panel = panel else { return }
        let contentView = makeHostingView(for: screen)
        panel.contentView = contentView
        lastChosenScreenSignature = ScreenDetector.signature(for: screen)
        updatePosition()
    }

    private func refreshCurrentScreen(forceRebuild: Bool = false) {
        if isAnimatingScreenHop { return }

        let screen = chosenScreen()
        let signature = ScreenDetector.signature(for: screen)

        if forceRebuild {
            rebuildForCurrentScreen(screen)
            return
        }

        if signature != lastChosenScreenSignature {
            animateScreenHop(to: screen, signature: signature)
        }
    }

    private func animateScreenHop(to screen: NSScreen, signature: String) {
        guard let panel = panel else {
            rebuildForCurrentScreen(screen)
            return
        }

        if !panel.isVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            rebuildForCurrentScreen(screen)
            panel.alphaValue = 1
            return
        }

        isAnimatingScreenHop = true
        let oldFrame = panel.frame
        let newFrame = panelFrame(for: screen)
        let motion = Self.screenHopMotion()
        let frames = Self.screenHopFrames(oldFrame: oldFrame, newFrame: newFrame)
        let targetSignature = signature

        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(frames.outgoing, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard let panel = self.panel else {
                    self.isAnimatingScreenHop = false
                    return
                }

                let targetScreen = NSScreen.screens.first {
                    ScreenDetector.signature(for: $0) == targetSignature
                } ?? self.chosenScreen()

                self.rebuildForCurrentScreen(targetScreen)
                panel.alphaValue = 0
                panel.setFrame(frames.incoming, display: true)

                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(motion.incomingPauseDuration * 1_000_000_000))
                    guard let self = self else { return }
                    guard let panel = self.panel else {
                        self.isAnimatingScreenHop = false
                        return
                    }

                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = motion.fadeInDuration
                        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
                        panel.animator().alphaValue = 1
                        panel.animator().setFrame(newFrame, display: true)
                    } completionHandler: { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.lastChosenScreenSignature = targetSignature
                            self?.isAnimatingScreenHop = false
                        }
                    }
                }
            }
        }
    }

    private var lastDisplayChoice = ""
    private var lastExpandedWidth = 0.0
    private var lastNotchHeightMode = SettingsDefaults.notchHeightMode
    private var lastCustomNotchHeight = SettingsDefaults.customNotchHeight
    private var expandedWidthCollapseTimer: Timer?

    private func observeSettingsChanges() {
        lastDisplayChoice = SettingsManager.shared.displayChoice
        lastExpandedWidth = SettingsManager.shared.expandedWidth
        lastNotchHeightMode = SettingsManager.shared.notchHeightMode.rawValue
        lastCustomNotchHeight = SettingsManager.shared.customNotchHeight
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let newChoice = SettingsManager.shared.displayChoice
                let newHeightMode = SettingsManager.shared.notchHeightMode.rawValue
                let newCustomHeight = SettingsManager.shared.customNotchHeight
                if newChoice != self.lastDisplayChoice {
                    self.lastDisplayChoice = newChoice
                    self.refreshCurrentScreen(forceRebuild: true)
                    self.configureAutoScreenPolling()
                } else if newHeightMode != self.lastNotchHeightMode
                    || abs(newCustomHeight - self.lastCustomNotchHeight) > 0.001 {
                    self.lastNotchHeightMode = newHeightMode
                    self.lastCustomNotchHeight = newCustomHeight
                    self.refreshCurrentScreen(forceRebuild: true)
                } else {
                    // Auto-expand when expanded width setting changes, auto-collapse when done
                    let newExpandedWidth = SettingsManager.shared.expandedWidth
                    if newExpandedWidth != self.lastExpandedWidth {
                        self.lastExpandedWidth = newExpandedWidth
                        if self.appState.surface == .collapsed {
                            withAnimation(NotchAnimation.open) {
                                self.appState.surface = .sessionList
                            }
                        }
                        // Reset collapse timer — fires after user stops dragging
                        self.expandedWidthCollapseTimer?.invalidate()
                        self.expandedWidthCollapseTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
                            Task { @MainActor [weak self] in
                                guard let self = self else { return }
                                if self.appState.surface == .sessionList {
                                    withAnimation(NotchAnimation.close) {
                                        self.appState.surface = .collapsed
                                    }
                                }
                            }
                        }
                    }
                    self.updateVisibility()
                    self.updatePosition()
                }
            }
        }
        settingsObservers.append(observer)
    }

    private func configureAutoScreenPolling() {
        autoScreenPoller?.invalidate()
        autoScreenPoller = nil

        guard SettingsManager.shared.displayChoice == "auto" else { return }

        autoScreenPoller = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCurrentScreen()
            }
        }
    }

    private func updatePosition() {
        guard let panel = panel else { return }
        let screen = chosenScreen()
        panel.setFrame(panelFrame(for: screen), display: true)
    }

    private func panelFrame(for screen: NSScreen) -> NSRect {
        let size = panelSize(for: screen)
        let screenFrame = screen.frame
        let centeredX = centeredX(for: size, screen: screen)
        let dragOffset = SettingsManager.shared.allowHorizontalDrag
            ? CGFloat(SettingsManager.shared.panelHorizontalOffset)
            : 0
        let x = clampedX(centeredX + dragOffset, panelWidth: size.width, on: screen)
        let y = screenFrame.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func centeredX(for size: NSSize, screen: NSScreen) -> CGFloat {
        screen.frame.midX - size.width / 2
    }

    private func clampedX(_ desiredX: CGFloat, panelWidth: CGFloat, on screen: NSScreen) -> CGFloat {
        min(max(desiredX, screen.frame.minX), screen.frame.maxX - panelWidth)
    }

    private func setupHorizontalDragMonitor() {
        let dragThreshold: CGFloat = 5

        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let panel = self.panel,
                  SettingsManager.shared.allowHorizontalDrag else { return event }

            switch event.type {
            case .leftMouseDown:
                if event.window === panel {
                    self.dragStartMouseX = NSEvent.mouseLocation.x
                    self.dragStartPanelX = panel.frame.origin.x
                    self.isDraggingPanel = false
                }
            case .leftMouseDragged:
                if let startMouseX = self.dragStartMouseX,
                   let startPanelX = self.dragStartPanelX {
                    let deltaX = NSEvent.mouseLocation.x - startMouseX
                    // Only start moving after exceeding threshold
                    if !self.isDraggingPanel {
                        guard abs(deltaX) > dragThreshold else { return event }
                        self.isDraggingPanel = true
                    }
                    let screen = self.chosenScreen()
                    let size = panel.frame.size
                    let newX = self.clampedX(startPanelX + deltaX, panelWidth: size.width, on: screen)
                    let fixedY = screen.frame.maxY - size.height
                    panel.setFrameOrigin(NSPoint(x: newX, y: fixedY))
                }
            case .leftMouseUp:
                if self.isDraggingPanel, let panel = self.panel {
                    let screen = self.chosenScreen()
                    let size = panel.frame.size
                    let offset = panel.frame.origin.x - self.centeredX(for: size, screen: screen)
                    SettingsManager.shared.panelHorizontalOffset = Double(offset)
                }
                self.dragStartMouseX = nil
                self.dragStartPanelX = nil
                self.isDraggingPanel = false
            default:
                break
            }
            return event
        }
    }

    /// Choose which screen to display on based on displayChoice setting
    private func chosenScreen() -> NSScreen {
        let choice = SettingsManager.shared.displayChoice

        // Handle specific screen index: "screen_0", "screen_1", etc.
        if choice.hasPrefix("screen_"),
           let index = Int(choice.dropFirst(7)),
           index < NSScreen.screens.count {
            return NSScreen.screens[index]
        }

        // "auto" — prefer notch screen, fallback to main
        return ScreenDetector.preferredScreen
    }

    /// Poll every 1.5s while in fullscreen; stop when fullscreen ends
    private func startFullscreenExitPoller() {
        fullscreenPoller?.invalidate()
        fullscreenPoller = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else { timer.invalidate(); return }
                if !self.isActiveSpaceFullscreen() {
                    self.fullscreenLatch = false
                    self.updateVisibility()
                    timer.invalidate()
                    self.fullscreenPoller = nil
                }
            }
        }
    }

    /// Update panel visibility based on settings
    private func updateVisibility() {
        guard let panel = panel else { return }
        let settings = SettingsManager.shared
        if settings.hideInFullscreen && fullscreenLatch {
            panel.orderOut(nil)
            return
        }

        if settings.hideWhenNoSession && appState.activeSessionCount == 0 {
            panel.orderOut(nil)
            return
        }

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func isActiveSpaceFullscreen() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }

        let screen = chosenScreen()

        // Primary: check if frontmost app has a window covering the entire screen
        if let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] {
            for window in windowList {
                guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                      pid == frontApp.processIdentifier,
                      let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                      let bounds = window[kCGWindowBounds as String] as? [String: Any],
                      let w = bounds["Width"] as? CGFloat,
                      let h = bounds["Height"] as? CGFloat else { continue }
                if w >= screen.frame.width && h >= screen.frame.height {
                    return true
                }
            }
        }

        // Fallback: menu bar disappeared on this screen (no Screen Recording permission needed)
        let menuBarGap = screen.frame.maxY - screen.visibleFrame.maxY
        if menuBarGap < 1 {
            return true
        }

        return false
    }

    /// Fast check: is the terminal running the active session the foreground app?
    /// Main-thread safe — no AppleScript or subprocess calls.
    func isActiveTerminalForeground() -> Bool {
        guard let sessionId = appState.activeSessionId,
              let session = appState.sessions[sessionId],
              session.termApp != nil else { return false }
        return TerminalVisibilityDetector.isTerminalFrontmostForSession(session)
    }

    func windowDidMove(_ notification: Notification) {
        // Drag is handled by setupHorizontalDragMonitor — no correction needed here.
    }

    deinit {
        autoScreenPoller?.invalidate()
        fullscreenPoller?.invalidate()
        for observer in settingsObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localDragMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
