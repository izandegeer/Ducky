import AppKit
import SwiftUI

class NotchWindow: NSPanel {
    private var statusObserver: Any?
    private var screenObserver: Any?
    private var eventObserver: Any?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?

    private var notchWidth: CGFloat = 180
    private var notchHeight: CGFloat = 37

    private var isExpanded = false
    private var collapseDebounceTimer: Timer?

    private let pillView = NotchPillView()
    private var pillContentHost: NSHostingView<NotchPillContent>?

    private var toastWindow: NotchToastWindow?
    private var hoverWindow: NotchHoverWindow?
    private var isHovering = false

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        hasShadow = false
        isOpaque = false
        animationBehavior = .none
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
        alphaValue = 1

        if let cv = contentView {
            pillView.frame = cv.bounds
            pillView.autoresizingMask = [.width, .height]
            pillView.alphaValue = 1
            cv.addSubview(pillView)
            cv.wantsLayer = true
            cv.layer?.masksToBounds = false

            let hostView = NSHostingView(rootView: NotchPillContent())
            hostView.frame = cv.bounds
            hostView.autoresizingMask = [.width, .height]
            hostView.alphaValue = 1
            hostView.wantsLayer = true
            hostView.layer?.backgroundColor = .clear
            cv.addSubview(hostView)
            pillContentHost = hostView
        }

        detectNotchSize()
        positionAtNotch()
        orderFrontRegardless()
        observeScreenChanges()
        observeStatusChanges()
        observeSessionEvents()
        setupMouseTracking()
    }

    deinit {
        if let observer = statusObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = screenObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = eventObserver { NotificationCenter.default.removeObserver(observer) }
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMouseMonitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - Mouse tracking for hover

    private func setupMouseTracking() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.checkMouse()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.checkMouse()
            return event
        }
    }

    private func checkMouse() {
        let mouse = NSEvent.mouseLocation
        let notchRect = frame.insetBy(dx: -20, dy: -5)

        if notchRect.contains(mouse) {
            if !isHovering {
                isHovering = true
                showHoverPreview()
            }
        } else {
            // Also check if mouse is in hover window
            let inHover = hoverWindow?.frame.contains(mouse) ?? false
            if isHovering && !inHover {
                isHovering = false
                hideHoverPreview()
            }
        }
    }

    // MARK: - Hover preview

    private func showHoverPreview() {
        let monitor = ClaudeMonitor.shared
        let sessions = monitor.sessions
        guard !sessions.isEmpty else { return }

        if hoverWindow == nil {
            hoverWindow = NotchHoverWindow()
        }
        hoverWindow?.updateSessions(sessions)

        // Calculate the hover preview width (same logic as NotchHoverWindow.showBelow)
        let hoverWidth = max(Self.pillFixedWidth, 520)

        // Animate the pill to match the hover width if the preview is wider
        if hoverWidth > Self.pillFixedWidth {
            animatePillWidth(to: hoverWidth)
        }

        hoverWindow?.showBelow(notchFrame: frame)
    }

    private func hideHoverPreview() {
        hoverWindow?.animateOut()
        // Don't nil it — reuse

        // Animate the pill back to its original width
        animatePillWidth(to: Self.pillFixedWidth)
    }

    private func animatePillWidth(to targetWidth: CGFloat) {
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame
        let targetFrame = NSRect(
            x: screenFrame.midX - targetWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: targetWidth,
            height: notchHeight
        )
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(targetFrame, display: true)
        }
    }

    // MARK: - Toast notifications

    private func observeSessionEvents() {
        eventObserver = NotificationCenter.default.addObserver(
            forName: .DuckySessionEvent,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let name = info["name"] as? String,
                  let emoji = info["emoji"] as? String else { return }
            let message = info["message"] as? String ?? ""
            let duration = info["duration"] as? Double ?? 0
            self?.showToast(name: name, emoji: emoji, message: message, duration: duration)
        }
    }

    private func showToast(name: String, emoji: String, message: String, duration: Double = 0) {
        if toastWindow == nil {
            toastWindow = NotchToastWindow()
        }
        toastWindow?.show(name: name, emoji: emoji, message: message, duration: duration, below: frame)
    }

    // MARK: - Status observation

    private static let pillFixedWidth: CGFloat = 380

    private func observeStatusChanges() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .DuckyStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateVisibility()
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateVisibility()
            self?.pillContentHost?.rootView = NotchPillContent()
        }
    }

    private func updateVisibility() {
        let hasRateLimits = ClaudeMonitor.shared.rateLimitFiveHour != nil || ClaudeMonitor.shared.rateLimitSevenDay != nil
        let hasSessions = !ClaudeMonitor.shared.sessions.isEmpty
        let shouldShow = hasSessions || hasRateLimits

        if shouldShow && !isExpanded {
            collapseDebounceTimer?.invalidate()
            collapseDebounceTimer = nil
            showPill()
        } else if !shouldShow && isExpanded {
            guard collapseDebounceTimer == nil else { return }
            collapseDebounceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.collapseDebounceTimer = nil
                let stillHasData = !ClaudeMonitor.shared.sessions.isEmpty
                    || ClaudeMonitor.shared.rateLimitFiveHour != nil
                    || ClaudeMonitor.shared.rateLimitSevenDay != nil
                if !stillHasData && self.isExpanded {
                    self.hidePill()
                }
            }
        }
    }

    // MARK: - Show / Hide (fixed width, fade only)

    private func showPill() {
        isExpanded = true
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame
        let pillWidth = Self.pillFixedWidth
        let targetFrame = NSRect(
            x: screenFrame.midX - pillWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: pillWidth,
            height: notchHeight
        )
        setFrame(targetFrame, display: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            self.pillView.animator().alphaValue = 1
            self.pillContentHost?.animator().alphaValue = 1
        }
    }

    private func hidePill() {
        isExpanded = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            self.pillView.animator().alphaValue = 0
            self.pillContentHost?.animator().alphaValue = 0
        }, completionHandler: {
            self.positionAtNotch()
        })
    }

    // MARK: - Notch size

    private func detectNotchSize() {
        guard let screen = NSScreen.builtIn else { return }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX
            notchHeight = screen.frame.maxY - min(left.minY, right.minY)
        } else {
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            notchWidth = 180
            notchHeight = max(menuBarHeight, 25)
        }
    }

    private func positionAtNotch() {
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame
        let w = isExpanded ? Self.pillFixedWidth : notchWidth
        setFrame(NSRect(x: screenFrame.midX - w / 2, y: screenFrame.maxY - notchHeight, width: w, height: notchHeight), display: true)
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.detectNotchSize()
            self?.positionAtNotch()
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Toast Window

class NotchToastWindow: NSPanel {
    private var hostView: NSHostingView<NotchToastView>?
    private var hideTimer: Timer?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .black
        hasShadow = false
        isOpaque = true
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        contentView?.wantsLayer = true
    }

    override func mouseDown(with event: NSEvent) {
        if let session = sessionToFocus {
            ClaudeMonitor.focusSession(session)
            animateOut(notchMinY: nil)
        }
    }

    private var sessionToFocus: ClaudeSession?

    func show(name: String, emoji: String, message: String, duration: Double = 0, below notchFrame: NSRect) {
        hideTimer?.invalidate()

        sessionToFocus = ClaudeMonitor.shared.sessions.first { $0.displayName == name }

        let view = NotchToastView(name: name, emoji: emoji, message: message, duration: duration)
        if hostView == nil {
            hostView = NSHostingView(rootView: view)
            contentView = hostView
        } else {
            hostView?.rootView = view
        }

        // Same width as the expanded notch, anchored to its bottom
        let width: CGFloat = notchFrame.width
        let contentHeight: CGFloat = message.isEmpty ? 32 : 48
        let x = notchFrame.origin.x

        // Start at 0 height (hidden), grow downward from notch bottom
        let startY = notchFrame.minY
        setFrame(NSRect(x: x, y: startY, width: width, height: 0), display: true)
        alphaValue = 1
        orderFrontRegardless()

        let targetY = notchFrame.minY - contentHeight
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(NSRect(x: x, y: targetY, width: width, height: contentHeight), display: true)
        }

        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.animateOut(notchMinY: notchFrame.minY)
        }
    }

    func animateOut(notchMinY: CGFloat? = nil) {
        hideTimer?.invalidate()
        let collapseY = notchMinY ?? frame.maxY
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().setFrame(NSRect(x: self.frame.origin.x, y: collapseY, width: self.frame.width, height: 0), display: true)
        }, completionHandler: {
            self.orderOut(nil)
        })
    }
}

struct NotchToastView: View {
    let name: String
    let emoji: String
    let message: String
    var duration: Double = 0

    private var mood: DuckyMood {
        switch emoji {
        case "✅": return .celebrating
        case "🔐", "⚠️": return .alert
        default: return .chillin
        }
    }

    private var durationText: String? {
        guard duration > 0 else { return nil }
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        if mins > 0 {
            return "(\(mins)m \(secs)s)"
        }
        return "(\(secs)s)"
    }

    var body: some View {
        HStack(spacing: 8) {
            DuckyAvatar(mood: mood, size: 24)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    if message.isEmpty {
                        Text("— done")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    if let dt = durationText {
                        Text(dt)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 0))
    }
}

// MARK: - Hover Preview Window

class NotchHoverWindow: NSPanel {
    private var hostView: NSHostingView<NotchHoverView>?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        hasShadow = false
        isOpaque = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView?.wantsLayer = true
    }

    func updateSessions(_ sessions: [ClaudeSession]) {
        let view = NotchHoverView(sessions: sessions) { session in
            ClaudeMonitor.focusSession(session)
        }
        if hostView == nil {
            hostView = NSHostingView(rootView: view)
            contentView = hostView
        } else {
            hostView?.rootView = view
        }
    }

    func showBelow(notchFrame: NSRect) {
        let sessions = ClaudeMonitor.shared.sessions
        // Use the notch frame width directly — the pill already expanded to match
        let width: CGFloat = max(notchFrame.width, 520)
        let x = notchFrame.midX - width / 2

        // Calculate height: big duck + single-line rows
        let duckHeight: CGFloat = 100 // big duck + padding
        var height: CGFloat = duckHeight + 16 // vertical padding
        for _ in sessions {
            height += 30 // single row height
            height += 4 // spacing between sessions
        }
        height += 4 // bottom padding

        setFrame(NSRect(x: x, y: notchFrame.minY, width: width, height: 0), display: true)
        alphaValue = 1
        orderFrontRegardless()

        let targetY = notchFrame.minY - height
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(NSRect(x: x, y: targetY, width: width, height: height), display: true)
        }
    }

    func animateOut() {
        let collapseY = frame.maxY
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().setFrame(NSRect(x: self.frame.origin.x, y: collapseY, width: self.frame.width, height: 0), display: true)
        }, completionHandler: {
            self.orderOut(nil)
        })
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct NotchHoverView: View {
    let sessions: [ClaudeSession]
    var onTap: ((ClaudeSession) -> Void)?

    private var duckyMood: DuckyMood {
        let state = NotchDisplayState.current
        switch state {
        case .working: return .working
        case .taskCompleted: return .celebrating
        case .waitingForInput: return .alert
        case .idle:
            return sessions.isEmpty ? .sleeping : .chillin
        }
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f
    }()

    private func formatLines(_ value: Int) -> String {
        Self.numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func contextBarColor(_ percentage: Double) -> Color {
        if percentage > 80 { return .red }
        if percentage > 50 { return .yellow }
        return .green
    }

    var body: some View {
        VStack(spacing: 8) {
            // Big duck
            DuckyAvatar(mood: duckyMood, size: 80)
                .padding(.top, 12)
                .padding(.bottom, 4)

            // Sessions list
            if !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sessions) { session in
                        SessionRowView(
                            session: session,
                            formatLines: formatLines,
                            contextBarColor: contextBarColor,
                            formatDuration: Self.formatDuration,
                            onTap: onTap
                        )
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 0))
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}

struct SessionRowView: View {
    let session: ClaudeSession
    let formatLines: (Int) -> String
    let contextBarColor: (Double) -> Color
    let formatDuration: (TimeInterval) -> String
    var onTap: ((ClaudeSession) -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            // LEFT group: icon + name + branch
            Image(systemName: session.status.sfSymbol)
                .font(.system(size: 11))
                .foregroundColor(session.status.sfSymbolColor)
                .frame(width: 14)

            Text(session.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            // Duration since current status
            if let since = session.statusSince {
                Text(formatDuration(Date().timeIntervalSince(since)))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            }

            if let branch = session.gitBranch ?? session.worktreeBranch {
                let dirtyMarker = (session.gitDirty == true) ? "*" : ""
                Text(branch + dirtyMarker)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
            }

            Spacer()

            // Lines changed
            if (session.linesAdded ?? 0) != 0 || (session.linesRemoved ?? 0) != 0 {
                HStack(spacing: 3) {
                    if let added = session.linesAdded, added != 0 {
                        Text("+\(formatLines(added))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color.green.opacity(0.8))
                    }
                    if let removed = session.linesRemoved, removed != 0 {
                        Text("-\(formatLines(removed))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color.red.opacity(0.8))
                    }
                }
            }

            // Context progress bar + percentage
            if let ctx = session.contextUsedPercentage {
                HStack(spacing: 4) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(white: 0.2))
                            .frame(width: 40, height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(contextBarColor(ctx))
                            .frame(width: 40 * min(ctx / 100.0, 1.0), height: 4)
                    }
                    Text("\(Int(ctx))%")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            // Cost
            if let cost = session.costUSD {
                Text(String(format: "$%.2f", cost))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?(session)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(isHovered ? 0.1 : 0.001))
        )
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Rate Limit Bar

struct RateLimitBar: View {
    let percentage: Double

    private var barColor: Color {
        if percentage > 80 { return .red }
        if percentage > 50 { return .yellow }
        return .green
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.2))
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor)
                    .frame(width: geo.size.width * min(percentage / 100.0, 1.0))
            }
        }
    }
}

// MARK: - NSScreen helper

extension NSScreen {
    static var builtIn: NSScreen? {
        screens.first { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return CGDisplayIsBuiltin(id) != 0
        } ?? main
    }
}

// MARK: - Notch display state

enum NotchDisplayState: Equatable {
    case idle
    case working
    case waitingForInput
    case taskCompleted

    static var current: NotchDisplayState {
        let sessions = ClaudeMonitor.shared.sessions
        if sessions.contains(where: { $0.status == .taskCompleted }) { return .taskCompleted }
        if sessions.contains(where: { $0.status == .waitingForInput }) { return .waitingForInput }
        if sessions.contains(where: { $0.status == .working }) { return .working }
        return .idle
    }
}

// MARK: - Pill content

struct NotchPillContent: View {
    private static let sectionLeftWidth: CGFloat = 80
    private static let sectionCenterWidth: CGFloat = 210
    private static let sectionRightWidth: CGFloat = 60

    private var displayState: NotchDisplayState { .current }
    private var sessions: [ClaudeSession] { ClaudeMonitor.shared.sessions }
    private var monitor: ClaudeMonitor { ClaudeMonitor.shared }

    private var duckyMood: DuckyMood {
        switch displayState {
        case .working: return .working
        case .taskCompleted: return .celebrating
        case .waitingForInput: return .alert
        case .idle:
            return sessions.isEmpty ? .sleeping : .chillin
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Duck avatar
            DuckyAvatar(mood: duckyMood, size: 28)
                .offset(y: -1)
                .padding(.leading, 6)

            // SECTION 1 (LEFT): Session status
            sessionSection
                .frame(width: Self.sectionLeftWidth, height: 20)

            // SECTION 2 (CENTER): Rate limits
            rateLimitSection
                .frame(width: Self.sectionCenterWidth, height: 20)

            // SECTION 3 (RIGHT): Reserved
            Color.clear
                .frame(width: Self.sectionRightWidth, height: 20)
        }
        .animation(.easeInOut(duration: 0.25), value: displayState)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -2)
    }

    // MARK: - Session section

    @ViewBuilder
    private var sessionSection: some View {
        if displayState != .idle {
            HStack(spacing: 4) {
                if displayState == .working {
                    SpinnerView()
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: dominantSFSymbol)
                        .font(.system(size: 10))
                        .foregroundColor(dominantSFSymbolColor)
                }

                let relevant = relevantCount
                Text("\(relevant)/\(sessions.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }
        } else {
            Color.clear
        }
    }

    private var dominantSFSymbol: String {
        switch displayState {
        case .waitingForInput: return "exclamationmark.triangle.fill"
        case .taskCompleted: return "checkmark.circle.fill"
        case .working: return "bolt.fill"
        case .idle: return "moon.zzz.fill"
        }
    }

    private var dominantSFSymbolColor: Color {
        switch displayState {
        case .waitingForInput: return .orange
        case .taskCompleted: return .green
        case .working: return .yellow
        case .idle: return Color(white: 0.5)
        }
    }

    private var relevantCount: Int {
        switch displayState {
        case .waitingForInput: return sessions.filter { $0.status == .waitingForInput }.count
        case .taskCompleted: return sessions.filter { $0.status == .taskCompleted }.count
        case .working: return sessions.filter { $0.status == .working }.count
        case .idle: return 0
        }
    }

    // MARK: - Rate limit section

    @ViewBuilder
    private var rateLimitSection: some View {
        let hasRateLimits = monitor.rateLimitFiveHour != nil || monitor.rateLimitSevenDay != nil
        if hasRateLimits {
            HStack(spacing: 8) {
                if let fiveHour = monitor.rateLimitFiveHour {
                    PillRateLimitIndicator(label: "5h", percentage: fiveHour)
                }
                if let sevenDay = monitor.rateLimitSevenDay {
                    PillRateLimitIndicator(label: "7d", percentage: sevenDay)
                }
            }
        } else {
            Color.clear
        }
    }
}

// MARK: - Pill sub-components

struct PillRateLimitIndicator: View {
    let label: String
    let percentage: Double

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
            RateLimitBar(percentage: percentage)
                .frame(width: 60, height: 6)
            Text("\(Int(percentage))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
        }
    }
}

struct PillSectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 0.5, height: 14)
    }
}

// MARK: - Spinner

struct SpinnerView: View {
    @State private var isAnimating = false

    var body: some View {
        Image(systemName: "arrow.trianglehead.2.counterclockwise")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.yellow)
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 1.0).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear { isAnimating = true }
    }
}

// MARK: - Pill background

class NotchPillView: NSView {
    private let shapeLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.backgroundColor = .clear
        shapeLayer.fillColor = NSColor.black.cgColor
        layer?.addSublayer(shapeLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updateShape()
    }

    private func updateShape() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }
        shapeLayer.frame = CGRect(x: 0, y: 0, width: w, height: h)
        let cr: CGFloat = 9.5
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: w, y: cr))
        path.addQuadCurve(to: CGPoint(x: w - cr, y: 0), control: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: cr, y: 0))
        path.addQuadCurve(to: CGPoint(x: 0, y: cr), control: CGPoint(x: 0, y: 0))
        path.closeSubpath()
        shapeLayer.path = path
    }
}

// MARK: - CVDisplayLink wrapper

class CVDisplayLinkWrapper {
    private var displayLink: CVDisplayLink?
    private let callback: () -> Bool
    private var stopped = false

    init(callback: @escaping () -> Bool) { self.callback = callback }

    func start() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink else { return }
        let opaqueWrapper = Unmanaged.passRetained(self)
        CVDisplayLinkSetOutputCallback(displayLink, { (_, _, _, _, _, userInfo) -> CVReturn in
            guard let userInfo else { return kCVReturnError }
            let wrapper = Unmanaged<CVDisplayLinkWrapper>.fromOpaque(userInfo).takeUnretainedValue()
            guard !wrapper.stopped else { return kCVReturnSuccess }
            let keepRunning = wrapper.callback()
            if !keepRunning {
                wrapper.stopped = true
                if let link = wrapper.displayLink { CVDisplayLinkStop(link) }
                DispatchQueue.main.async {
                    wrapper.displayLink = nil
                    Unmanaged<CVDisplayLinkWrapper>.fromOpaque(userInfo).release()
                }
            }
            return kCVReturnSuccess
        }, opaqueWrapper.toOpaque())
        CVDisplayLinkStart(displayLink)
    }

    func stop() {
        stopped = true
        guard let displayLink else { return }
        CVDisplayLinkStop(displayLink)
        self.displayLink = nil
    }
}
