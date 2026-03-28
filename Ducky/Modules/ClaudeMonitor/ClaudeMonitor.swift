import AppKit
import AVFoundation
import SwiftUI

enum ClaudeSessionStatus: Equatable {
    case idle
    case working
    case waitingForInput  // permission or attention
    case taskCompleted

    var emoji: String {
        switch self {
        case .working: return "⏳"
        case .taskCompleted: return "✅"
        case .waitingForInput: return "⚠️"
        case .idle: return "💤"
        }
    }

    var label: String {
        switch self {
        case .working: return "working"
        case .taskCompleted: return "done"
        case .waitingForInput: return "needs attention"
        case .idle: return "idle"
        }
    }

    var sfSymbol: String {
        switch self {
        case .working: return "bolt.fill"
        case .idle: return "moon.zzz.fill"
        case .taskCompleted: return "checkmark.circle.fill"
        case .waitingForInput: return "exclamationmark.triangle.fill"
        }
    }

    var sfSymbolColor: Color {
        switch self {
        case .working: return .yellow
        case .idle: return Color(white: 0.5)
        case .taskCompleted: return .green
        case .waitingForInput: return .orange
        }
    }
}

struct ClaudeSession: Identifiable {
    let id: Int // PID
    let sessionId: String
    let projectDir: String
    let name: String?
    let startedAt: Date
    var status: ClaudeSessionStatus
    var cpuUsage: Double
    var hookMessage: String?
    var hookStatus: String?
    var tty: String?
    /// When this session entered its current status
    var statusSince: Date?

    // Status line data
    var rateLimitFiveHour: Double? // percentage 0-100
    var rateLimitFiveHourResetsAt: Date?
    var rateLimitSevenDay: Double? // percentage 0-100
    var rateLimitSevenDayResetsAt: Date?
    var costUSD: Double?
    var linesAdded: Int?
    var linesRemoved: Int?
    var contextUsedPercentage: Double?
    var contextWindowSize: Int?
    var worktreeName: String?
    var worktreeBranch: String?
    var worktreeOriginalBranch: String?
}

@Observable
class ClaudeMonitor {
    static let shared = ClaudeMonitor()

    var sessions: [ClaudeSession] = []

    // Aggregate rate limits (worst case across all sessions, since limits are account-level)
    var rateLimitFiveHour: Double? {
        sessions.compactMap(\.rateLimitFiveHour).max()
    }

    var rateLimitSevenDay: Double? {
        sessions.compactMap(\.rateLimitSevenDay).max()
    }

    var rateLimitFiveHourResetsAt: Date? {
        guard let max = rateLimitFiveHour else { return nil }
        return sessions.first(where: { $0.rateLimitFiveHour == max })?.rateLimitFiveHourResetsAt
    }

    var rateLimitSevenDayResetsAt: Date? {
        guard let max = rateLimitSevenDay else { return nil }
        return sessions.first(where: { $0.rateLimitSevenDay == max })?.rateLimitSevenDayResetsAt
    }

    private var pollingTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var lastSoundPlayedAt: Date = .distantPast
    /// How many consecutive idle polls per session (must stay idle for multiple cycles)
    private var idleCount: [Int: Int] = [Int: Int]()
    /// Number of consecutive idle polls needed before "done" (2s each = 12s total)
    private static let idleCyclesRequired = 6
    /// When each session started working (to filter short responses)
    private var workingStartedAt: [Int: Date] = [Int: Date]()
    /// Cooldown: don't notify same session within 10 seconds
    private var lastNotifiedAt: [Int: Date] = [Int: Date]()
    /// Track which hook timestamps we already notified about
    private var lastHookTimestamp: [String: Int] = [String: Int]()

    func start() {
        poll()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func poll() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let detected = Self.detectSessions()
            DispatchQueue.main.async {
                self?.updateSessions(detected)
            }
        }
    }

    /// Track statusSince across polls
    private var statusSinceMap: [Int: Date] = [Int: Date]()

    private func updateSessions(_ detected: [ClaudeSession]) {
        let oldStatuses = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.status) })

        // Clean up statusline files for sessions that have ended
        let oldSessionIds = Set(sessions.map(\.sessionId))
        let newSessionIds = Set(detected.map(\.sessionId))
        let endedSessionIds = oldSessionIds.subtracting(newSessionIds)
        if !endedSessionIds.isEmpty {
            DispatchQueue.global(qos: .utility).async {
                let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
                let statuslineDir = home + "/.ducky/statusline"
                let fm = FileManager.default
                for sid in endedSessionIds {
                    let path = statuslineDir + "/" + sid + ".json"
                    try? fm.removeItem(atPath: path)
                }
            }
        }

        // Update statusSince for each session
        var updated = detected
        for i in updated.indices {
            let old = oldStatuses[updated[i].id]
            if old != updated[i].status || statusSinceMap[updated[i].id] == nil {
                statusSinceMap[updated[i].id] = Date()
            }
            updated[i].statusSince = statusSinceMap[updated[i].id]
        }
        sessions = updated

        for session in sessions {
            let oldStatus = oldStatuses[session.id]

            // Track when session started working
            if session.status == .working && oldStatus != .working {
                workingStartedAt[session.id] = Date()
                // Clear hook files when session resumes working
                let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
                let stateFile = home + "/.ducky/sessions/" + session.sessionId + ".json"
                try? FileManager.default.removeItem(atPath: stateFile)
            }

            if let old = oldStatus {
                if session.status == .waitingForInput && old != .waitingForInput {
                    // Permission/attention — notify immediately
                    idleCount.removeValue(forKey: session.id)
                    workingStartedAt.removeValue(forKey: session.id)
                    notifyIfCooldown(session: session, isWaiting: true)
                } else if session.status == .working {
                    // Back to working — reset idle counter
                    idleCount.removeValue(forKey: session.id)
                } else if session.status == .idle {
                    let count = (idleCount[session.id] ?? 0) + 1
                    idleCount[session.id] = count
                    if count == Self.idleCyclesRequired, let started = workingStartedAt[session.id] {
                        // Only notify if we actually tracked working start
                        let workedFor = Date().timeIntervalSince(started)
                        workingStartedAt.removeValue(forKey: session.id)
                        if workedFor > 15 {
                            notifyIfCooldown(session: session, isWaiting: false)
                        }
                    }
                }
            }
        }

        NotificationCenter.default.post(name: .DuckyStatusChanged, object: nil)
    }

    private func notifyIfCooldown(session: ClaudeSession, isWaiting: Bool) {
        let now = Date()
        if let last = lastNotifiedAt[session.id], now.timeIntervalSince(last) < 10 {
            return // cooldown active
        }
        lastNotifiedAt[session.id] = now
        if isWaiting {
            onWaitingForInput(session: session)
        } else {
            onTaskCompleted(session: session)
        }
    }

    private func onTaskCompleted(session: ClaudeSession) {
        if DuckySettings.shared.soundEnabled {
            playSound(named: "taskCompleted")
        }
        let duration = workingStartedAt[session.id].map { Date().timeIntervalSince($0) } ?? 0
        NotificationCenter.default.post(
            name: .DuckySessionEvent,
            object: nil,
            userInfo: [
                "name": session.displayName,
                "emoji": "✅",
                "message": "",
                "duration": duration
            ]
        )
    }

    private func onWaitingForInput(session: ClaudeSession) {
        if DuckySettings.shared.soundEnabled {
            playSound(named: "waitingForInput")
        }
        let emoji: String
        let message: String
        if session.hookStatus == "permission" {
            emoji = "🔐"
            message = session.hookMessage ?? "needs permission"
        } else {
            emoji = "⚠️"
            message = session.hookMessage ?? "needs attention"
        }
        let duration = workingStartedAt[session.id].map { Date().timeIntervalSince($0) } ?? 0
        NotificationCenter.default.post(
            name: .DuckySessionEvent,
            object: nil,
            userInfo: [
                "name": session.displayName,
                "emoji": emoji,
                "message": message,
                "duration": duration
            ]
        )
    }

    private func playSound(named name: String) {
        let now = Date()
        guard now.timeIntervalSince(lastSoundPlayedAt) >= 1.0 else { return }
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else { return }
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
            lastSoundPlayedAt = now
        } catch {}
    }

    // MARK: - Detection

    private static func detectSessions() -> [ClaudeSession] {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let claudeSessionsDir = home + "/.claude/sessions"
        let duckySessionsDir = home + "/.ducky/sessions"
        let duckyStatuslineDir = home + "/.ducky/statusline"
        let fm = FileManager.default

        // Ensure statusline directory exists
        if !fm.fileExists(atPath: duckyStatuslineDir) {
            try? fm.createDirectory(atPath: duckyStatuslineDir, withIntermediateDirectories: true)
        }

        guard let files = try? fm.contentsOfDirectory(atPath: claudeSessionsDir) else { return [] }

        // Read all ducky hook states indexed by session_id
        var hookStates: [String: (status: String, message: String, timestamp: Int)] = [:]
        if let duckyFiles = try? fm.contentsOfDirectory(atPath: duckySessionsDir) {
            for file in duckyFiles where file.hasSuffix(".json") {
                let path = duckySessionsDir + "/" + file
                guard let data = fm.contents(atPath: path),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sid = json["session_id"] as? String,
                      let status = json["status"] as? String else { continue }
                let message = json["message"] as? String ?? ""
                let ts = json["timestamp"] as? Int ?? 0
                hookStates[sid] = (status, message, ts)
            }
        }

        // Read all ducky statusline data indexed by session_id
        struct StatuslineData {
            var rateLimitFiveHour: Double?
            var rateLimitFiveHourResetsAt: Date?
            var rateLimitSevenDay: Double?
            var rateLimitSevenDayResetsAt: Date?
            var costUSD: Double?
            var linesAdded: Int?
            var linesRemoved: Int?
            var contextUsedPercentage: Double?
            var contextWindowSize: Int?
            var worktreeName: String?
            var worktreeBranch: String?
            var worktreeOriginalBranch: String?
        }
        var statuslineStates: [String: StatuslineData] = [:]
        if let statuslineFiles = try? fm.contentsOfDirectory(atPath: duckyStatuslineDir) {
            for file in statuslineFiles where file.hasSuffix(".json") {
                let path = duckyStatuslineDir + "/" + file
                guard let data = fm.contents(atPath: path),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sid = json["session_id"] as? String else { continue }
                // Statusline data (rate limits, cost, context, worktree) doesn't go stale quickly.
                // It's only updated after each assistant message, so we read it regardless of age.
                // Cleanup happens when the session itself ends (see updateSessions).

                var sl = StatuslineData()

                if let rateLimits = json["rate_limits"] as? [String: Any] {
                    if let fiveHour = rateLimits["five_hour"] as? [String: Any] {
                        sl.rateLimitFiveHour = fiveHour["used_percentage"] as? Double
                        if let resetsAt = fiveHour["resets_at"] as? Double {
                            sl.rateLimitFiveHourResetsAt = Date(timeIntervalSince1970: resetsAt)
                        }
                    }
                    if let sevenDay = rateLimits["seven_day"] as? [String: Any] {
                        sl.rateLimitSevenDay = sevenDay["used_percentage"] as? Double
                        if let resetsAt = sevenDay["resets_at"] as? Double {
                            sl.rateLimitSevenDayResetsAt = Date(timeIntervalSince1970: resetsAt)
                        }
                    }
                }

                if let cost = json["cost"] as? [String: Any] {
                    sl.costUSD = cost["total_cost_usd"] as? Double
                    sl.linesAdded = cost["total_lines_added"] as? Int
                    sl.linesRemoved = cost["total_lines_removed"] as? Int
                }

                if let ctx = json["context_window"] as? [String: Any] {
                    sl.contextUsedPercentage = ctx["used_percentage"] as? Double
                    sl.contextWindowSize = ctx["context_window_size"] as? Int
                }

                if let wt = json["worktree"] as? [String: Any] {
                    sl.worktreeName = wt["name"] as? String
                    sl.worktreeBranch = wt["branch"] as? String
                    sl.worktreeOriginalBranch = wt["original_branch"] as? String
                }

                statuslineStates[sid] = sl
            }
        }

        var results: [ClaudeSession] = []

        for file in files where file.hasSuffix(".json") {
            let path = claudeSessionsDir + "/" + file
            guard let data = fm.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int,
                  let sessionId = json["sessionId"] as? String,
                  let cwd = json["cwd"] as? String else { continue }

            let (cpuUsage, tty) = getProcessInfo(pid: pid)
            guard cpuUsage >= 0 else { continue }

            let name = json["name"] as? String
            let startedAtMs: Double
            if let ms = json["startedAt"] as? Double {
                startedAtMs = ms
            } else if let ms = json["startedAt"] as? Int {
                startedAtMs = Double(ms)
            } else {
                startedAtMs = 0
            }
            let startedAt = Date(timeIntervalSince1970: startedAtMs / 1000)

            // Determine status: prefer hook state, fallback to CPU
            let hookState = hookStates[sessionId]
            var status: ClaudeSessionStatus
            var hookMessage: String?
            var hookStatusRaw: String?

            // Hooks provide permission/attention. Working/idle from CPU.
            // Hook state is valid if CPU is low AND it's newer than last time we saw working.
            if cpuUsage > 5.0 {
                status = .working
                hookMessage = nil
                hookStatusRaw = nil
            } else if let hs = hookState, (hs.status == "permission" || hs.status == "attention") {
                status = .waitingForInput
                hookStatusRaw = hs.status
                hookMessage = hs.message.isEmpty ? nil : hs.message
            } else {
                status = .idle
                hookMessage = nil
                hookStatusRaw = nil
            }

            let sl = statuslineStates[sessionId]
            results.append(ClaudeSession(
                id: pid,
                sessionId: sessionId,
                projectDir: cwd,
                name: name,
                startedAt: startedAt,
                status: status,
                cpuUsage: cpuUsage,
                hookMessage: hookMessage,
                hookStatus: hookStatusRaw,
                tty: tty,
                statusSince: nil,
                rateLimitFiveHour: sl?.rateLimitFiveHour,
                rateLimitFiveHourResetsAt: sl?.rateLimitFiveHourResetsAt,
                rateLimitSevenDay: sl?.rateLimitSevenDay,
                rateLimitSevenDayResetsAt: sl?.rateLimitSevenDayResetsAt,
                costUSD: sl?.costUSD,
                linesAdded: sl?.linesAdded,
                linesRemoved: sl?.linesRemoved,
                contextUsedPercentage: sl?.contextUsedPercentage,
                contextWindowSize: sl?.contextWindowSize,
                worktreeName: sl?.worktreeName,
                worktreeBranch: sl?.worktreeBranch,
                worktreeOriginalBranch: sl?.worktreeOriginalBranch
            ))
        }

        return results.sorted { $0.startedAt < $1.startedAt }
    }

    /// Get CPU usage and TTY for a PID. Returns (-1, nil) if process doesn't exist.
    private static func getProcessInfo(pid: Int) -> (cpu: Double, tty: String?) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "%cpu=,tty="]
        task.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return (-1, nil)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return (-1, nil)
        }

        let parts = output.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cpuStr = parts.first else { return (-1, nil) }
        let normalized = cpuStr.replacingOccurrences(of: ",", with: ".")
        let cpu = Double(normalized) ?? -1
        let tty = parts.count > 1 ? parts[1] : nil
        return (cpu, tty)
    }

    /// Activate iTerm and switch to the tab containing this session's TTY
    static func focusSession(_ session: ClaudeSession) {
        guard let tty = session.tty else { return }

        // Select the correct tab AND bring its window to front
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                tell w
                    repeat with t in tabs
                        tell t
                            repeat with s in sessions
                                if (tty of s) contains "\(tty)" then
                                    select t
                                    -- Bring this specific window to front
                                    set index of w to 1
                                end if
                            end repeat
                        end tell
                    end repeat
                end tell
            end repeat
            activate
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            try? proc.run()
        }
    }
}

extension ClaudeSession {
    var displayName: String {
        name ?? projectDir.components(separatedBy: "/").last ?? "claude"
    }
}

extension Notification.Name {
    static let DuckyStatusChanged = Notification.Name("DuckyStatusChanged")
    static let DuckySessionEvent = Notification.Name("DuckySessionEvent")
}
