import AppKit
import AVFoundation

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
        case .working: return "trabajando"
        case .taskCompleted: return "listo"
        case .waitingForInput: return "necesita atención"
        case .idle: return "idle"
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
}

@Observable
class ClaudeMonitor {
    static let shared = ClaudeMonitor()

    var sessions: [ClaudeSession] = []

    private var pollingTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var lastSoundPlayedAt: Date = .distantPast

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

    private func updateSessions(_ detected: [ClaudeSession]) {
        let oldStatuses = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.status) })
        sessions = detected

        for session in sessions {
            let oldStatus = oldStatuses[session.id]
            if let old = oldStatus {
                if old == .working && session.status == .taskCompleted {
                    onTaskCompleted(session: session)
                } else if old == .working && session.status == .waitingForInput {
                    onWaitingForInput(session: session)
                }
            }
        }

        NotificationCenter.default.post(name: .DuckyStatusChanged, object: nil)
    }

    private func onTaskCompleted(session: ClaudeSession) {
        if DuckySettings.shared.soundEnabled {
            playSound(named: "taskCompleted")
        }
        NotificationCenter.default.post(
            name: .DuckySessionEvent,
            object: nil,
            userInfo: [
                "name": session.displayName,
                "emoji": "✅",
                "message": ""
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
            message = session.hookMessage ?? "necesita permiso"
        } else {
            emoji = "⚠️"
            message = session.hookMessage ?? "necesita atención"
        }
        NotificationCenter.default.post(
            name: .DuckySessionEvent,
            object: nil,
            userInfo: [
                "name": session.displayName,
                "emoji": emoji,
                "message": message
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
        let fm = FileManager.default

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

            if let hs = hookState {
                hookStatusRaw = hs.status
                hookMessage = hs.message.isEmpty ? nil : hs.message
                switch hs.status {
                case "working":
                    status = .working
                case "completed":
                    status = .taskCompleted
                case "permission", "attention":
                    status = .waitingForInput
                default:
                    // Fallback to CPU
                    status = cpuUsage > 5.0 ? .working : .idle
                    hookStatusRaw = nil
                    hookMessage = nil
                }
            } else {
                // No hook data, use CPU
                status = cpuUsage > 5.0 ? .working : .idle
                hookMessage = nil
                hookStatusRaw = nil
            }

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
                tty: tty
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
        let script = """
        tell application "iTerm2"
            activate
            repeat with w in windows
                tell w
                    repeat with t in tabs
                        tell t
                            repeat with s in sessions
                                if (tty of s) contains "\(tty)" then
                                    select t
                                    return
                                end if
                            end repeat
                        end tell
                    end repeat
                end tell
            end repeat
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
