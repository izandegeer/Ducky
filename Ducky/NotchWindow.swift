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
        let sessions = ClaudeMonitor.shared.sessions
        guard !sessions.isEmpty else { return }

        if hoverWindow == nil {
            hoverWindow = NotchHoverWindow()
        }
        hoverWindow?.updateSessions(sessions)
        hoverWindow?.showBelow(notchFrame: frame)
    }

    private func hideHoverPreview() {
        hoverWindow?.animateOut()
        // Don't nil it — reuse
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
            self?.showToast(name: name, emoji: emoji, message: message)
        }
    }

    private func showToast(name: String, emoji: String, message: String) {
        if toastWindow == nil {
            toastWindow = NotchToastWindow()
        }
        toastWindow?.show(name: name, emoji: emoji, message: message, below: frame)
    }

    // MARK: - Status observation

    private func observeStatusChanges() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .DuckyStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateExpansionState()
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateExpansionState()
            self?.pillContentHost?.rootView = NotchPillContent()
        }
    }

    private func updateExpansionState() {
        let shouldExpand = NotchDisplayState.current != .idle

        if shouldExpand && !isExpanded {
            collapseDebounceTimer?.invalidate()
            collapseDebounceTimer = nil
            expandWithBounce()
        } else if !shouldExpand && isExpanded {
            guard collapseDebounceTimer == nil else { return }
            collapseDebounceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.collapseDebounceTimer = nil
                if NotchDisplayState.current == .idle && self.isExpanded {
                    self.collapse()
                }
            }
        }
    }

    // MARK: - Expand / Collapse

    private func expandWithBounce() {
        isExpanded = true
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame

        let targetWidth: CGFloat = notchWidth + 80
        let targetFrame = NSRect(
            x: screenFrame.midX - targetWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: targetWidth,
            height: notchHeight
        )

        pillView.alphaValue = 1
        pillContentHost?.alphaValue = 1

        let startFrame = frame
        let startTime = CACurrentMediaTime()
        let duration: Double = 0.6

        let displayLink = CVDisplayLinkWrapper { [weak self] in
            guard let self else { return false }
            let elapsed = CACurrentMediaTime() - startTime
            let t = min(elapsed / duration, 1.0)
            let bounce = Self.bounceEase(t)
            let currentX = startFrame.origin.x + (targetFrame.origin.x - startFrame.origin.x) * bounce
            let currentWidth = startFrame.width + (targetFrame.width - startFrame.width) * bounce
            DispatchQueue.main.async {
                self.setFrame(NSRect(x: currentX, y: targetFrame.origin.y, width: currentWidth, height: targetFrame.height), display: true)
            }
            return t < 1.0
        }
        displayLink.start()
    }

    private func collapse() {
        isExpanded = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.pillContentHost?.animator().alphaValue = 0
        }
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame
        let targetFrame = NSRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
        let startFrame = frame
        let startTime = CACurrentMediaTime()
        let duration: Double = 0.3
        let displayLink = CVDisplayLinkWrapper { [weak self] in
            guard let self else { return false }
            let elapsed = CACurrentMediaTime() - startTime
            let t = min(elapsed / duration, 1.0)
            let ease = 1.0 - pow(1.0 - t, 3.0)
            let currentX = startFrame.origin.x + (targetFrame.origin.x - startFrame.origin.x) * ease
            let currentWidth = startFrame.width + (targetFrame.width - startFrame.width) * ease
            DispatchQueue.main.async {
                self.setFrame(NSRect(x: currentX, y: targetFrame.origin.y, width: currentWidth, height: targetFrame.height), display: true)
                if t >= 1.0 { self.pillContentHost?.alphaValue = 1 }
            }
            return t < 1.0
        }
        displayLink.start()
    }

    private static func bounceEase(_ t: Double) -> Double {
        let omega = 12.0
        let zeta = 0.4
        return 1.0 - exp(-zeta * omega * t) * cos(sqrt(1.0 - zeta * zeta) * omega * t)
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
        setFrame(NSRect(x: screenFrame.midX - notchWidth / 2, y: screenFrame.maxY - notchHeight, width: notchWidth, height: notchHeight), display: true)
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
        backgroundColor = .clear
        hasShadow = true
        isOpaque = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    override func mouseDown(with event: NSEvent) {
        if let session = sessionToFocus {
            ClaudeMonitor.focusSession(session)
            animateOut()
        }
    }

    private var sessionToFocus: ClaudeSession?

    func show(name: String, emoji: String, message: String, below notchFrame: NSRect) {
        hideTimer?.invalidate()

        // Find the session that matches this name for click-to-focus
        sessionToFocus = ClaudeMonitor.shared.sessions.first { $0.displayName == name }

        let view = NotchToastView(name: name, emoji: emoji, message: message)
        if hostView == nil {
            hostView = NSHostingView(rootView: view)
            contentView = hostView
        } else {
            hostView?.rootView = view
        }

        let width: CGFloat = 280
        let height: CGFloat = message.isEmpty ? 36 : 52
        let x = notchFrame.midX - width / 2
        let y = notchFrame.minY - height - 4

        // Start above (hidden behind notch), animate down
        setFrame(NSRect(x: x, y: notchFrame.minY, width: width, height: height), display: true)
        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
            self.animator().alphaValue = 1
        }

        // Auto-hide after 3 seconds
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.animateOut()
        }
    }

    func animateOut() {
        hideTimer?.invalidate()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.orderOut(nil)
        })
    }
}

struct NotchToastView: View {
    let name: String
    let emoji: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(emoji)
                    .font(.system(size: 14))
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                if message.isEmpty {
                    Text("— listo")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: NSColor(white: 0.12, alpha: 0.95)))
        )
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
        hasShadow = true
        isOpaque = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
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
        let width: CGFloat = 260
        let sessions = ClaudeMonitor.shared.sessions
        let rowHeight: CGFloat = 28
        let height: CGFloat = CGFloat(sessions.count) * rowHeight + 20
        let x = notchFrame.midX - width / 2
        let y = notchFrame.minY - height - 4

        setFrame(NSRect(x: x, y: notchFrame.minY, width: width, height: height), display: true)
        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
            self.animator().alphaValue = 1
        }
    }

    func animateOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 0
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(sessions) { session in
                HStack(spacing: 8) {
                    Text(session.status.emoji)
                        .font(.system(size: 13))
                    Text(session.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                    Spacer()
                    Text(session.status.label)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    onTap?(session)
                }
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.001)) // invisible but hittable
                )
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: NSColor(white: 0.12, alpha: 0.95)))
        )
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
    private var displayState: NotchDisplayState { .current }
    private var sessions: [ClaudeSession] { ClaudeMonitor.shared.sessions }

    var body: some View {
        ZStack {
            if displayState != .idle {
                HStack(spacing: 6) {
                    switch displayState {
                    case .working:
                        SpinnerView()
                            .frame(width: 12, height: 12)
                        let count = sessions.filter { $0.status == .working }.count
                        if count > 1 {
                            Text("\(count)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                    case .taskCompleted:
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.green)
                    case .waitingForInput:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.yellow)
                    case .idle:
                        EmptyView()
                    }

                    Spacer()

                    let working = sessions.filter { $0.status == .working }.count
                    if sessions.count > 0 {
                        Text("\(working)/\(sessions.count)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 12)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: displayState)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -2)
    }
}

struct SpinnerView: View {
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .trim(from: 0.05, to: 0.8)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: isAnimating)
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
