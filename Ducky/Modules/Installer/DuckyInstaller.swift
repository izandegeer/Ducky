import Foundation

/// Handles installing Ducky's hook and statusline scripts into the user's system.
/// The statusline configuration in ~/.claude/settings.json is now user-consent-based
/// and managed separately via installStatusLine() / removeStatusLine().
enum DuckyInstaller {

    private static let fm = FileManager.default

    private static var home: String { fm.homeDirectoryForCurrentUser.path }
    private static var duckyDir: String { home + "/.ducky" }
    private static var claudeSettingsPath: String { home + "/.claude/settings.json" }
    private static var statuslineDestination: String { duckyDir + "/statusline.sh" }
    private static var userStatuslinePath: String { duckyDir + "/user-statusline-command" }

    /// Run installation steps that are safe to do automatically on every launch.
    /// This copies scripts and creates directories, but does NOT modify ~/.claude/settings.json.
    static func installIfNeeded() {
        // Ensure directories exist
        createDirectoryIfNeeded(duckyDir)
        createDirectoryIfNeeded(duckyDir + "/statusline")
        createDirectoryIfNeeded(home + "/.claude")
        createDirectoryIfNeeded(duckyDir + "/sessions")

        // Copy bundled statusline.sh to ~/.ducky/statusline.sh (always keep up to date)
        installStatuslineScript(to: statuslineDestination)
    }

    // MARK: - Status Line Management (user-consent-based)

    /// Check if our statusline is currently configured in Claude Code settings.
    static func isStatusLineInstalled() -> Bool {
        guard let data = fm.contents(atPath: claudeSettingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = json["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return false
        }
        return command == statuslineDestination
    }

    /// Install our statusline wrapper into ~/.claude/settings.json,
    /// preserving the user's existing command if any.
    static func installStatusLine() {
        var settings: [String: Any]

        if let data = fm.contents(atPath: claudeSettingsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        } else {
            settings = [:]
        }

        // Check for existing non-Ducky statusline command and preserve it
        if let existing = settings["statusLine"] as? [String: Any],
           let command = existing["command"] as? String,
           command != statuslineDestination {
            saveUserStatuslineCommand(command, to: userStatuslinePath)
        }

        // Install our wrapper as the statusLine command
        settings["statusLine"] = [
            "type": "command",
            "command": statuslineDestination
        ] as [String: Any]

        // Write back
        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: claudeSettingsPath))
            DuckySettings.shared.statusLineInstalled = true
            print("[Ducky] Status line installed successfully")
        } catch {
            print("[Ducky] Failed to install status line: \(error)")
        }
    }

    /// Remove our statusline wrapper from ~/.claude/settings.json,
    /// restoring the user's previous command if one was saved.
    static func removeStatusLine() {
        var settings: [String: Any]

        guard let data = fm.contents(atPath: claudeSettingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            DuckySettings.shared.statusLineInstalled = false
            return
        }
        settings = json

        // Restore user's original command if we saved one
        if fm.fileExists(atPath: userStatuslinePath),
           let savedCommand = try? String(contentsOfFile: userStatuslinePath, encoding: .utf8) {
            settings["statusLine"] = [
                "type": "command",
                "command": savedCommand
            ] as [String: Any]
            try? fm.removeItem(atPath: userStatuslinePath)
            print("[Ducky] Restored user's original statusline command: \(savedCommand)")
        } else {
            // No saved command — remove the statusLine key entirely
            settings.removeValue(forKey: "statusLine")
            print("[Ducky] Removed statusLine from claude settings")
        }

        // Write back
        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: claudeSettingsPath))
            DuckySettings.shared.statusLineInstalled = false
        } catch {
            print("[Ducky] Failed to update claude settings: \(error)")
        }
    }

    // MARK: - Private

    private static func createDirectoryIfNeeded(_ path: String) {
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }

    private static func installStatuslineScript(to destination: String) {
        guard let bundledURL = Bundle.main.url(forResource: "statusline", withExtension: "sh") else {
            print("[Ducky] statusline.sh not found in bundle")
            return
        }

        // Always overwrite to keep the script up to date with the app version
        try? fm.removeItem(atPath: destination)
        do {
            try fm.copyItem(at: bundledURL, to: URL(fileURLWithPath: destination))
            // Ensure executable permission
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination)
        } catch {
            print("[Ducky] Failed to install statusline.sh: \(error)")
        }
    }

    /// Saves the user's original statusline command so it can be restored later.
    private static func saveUserStatuslineCommand(_ command: String, to path: String) {
        do {
            try command.write(toFile: path, atomically: true, encoding: .utf8)
            print("[Ducky] Preserved user statusline command: \(command)")
        } catch {
            print("[Ducky] Failed to save user statusline command: \(error)")
        }
    }
}
