import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var notchWindow: NotchWindow?
    private let settings = DuckySettings.shared
    private let claudeMonitor = ClaudeMonitor.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        if settings.showNotch {
            setupNotchWindow()
        }
        claudeMonitor.start()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(named: "menuIcon")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupNotchWindow() {
        notchWindow = NotchWindow()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        showMenu()
    }

    private func showMenu() {
        let menu = NSMenu()

        // -- Claude Monitor section --
        let headerItem = NSMenuItem(title: "Claude Monitor", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        let sessions = claudeMonitor.sessions
        if sessions.isEmpty {
            let noSessions = NSMenuItem(title: "  Sin sesiones activas", action: nil, keyEquivalent: "")
            noSessions.isEnabled = false
            menu.addItem(noSessions)
        } else {
            let working = sessions.filter { $0.status == .working }.count
            let idle = sessions.filter { $0.status == .idle || $0.status == .taskCompleted }.count
            let waiting = sessions.filter { $0.status == .waitingForInput }.count

            let summaryParts = [
                working > 0 ? "\(working) trabajando" : nil,
                idle > 0 ? "\(idle) idle" : nil,
                waiting > 0 ? "\(waiting) esperando" : nil
            ].compactMap { $0 }

            let summaryItem = NSMenuItem(title: "  \(sessions.count) sesiones: \(summaryParts.joined(separator: ", "))", action: nil, keyEquivalent: "")
            summaryItem.isEnabled = false
            menu.addItem(summaryItem)

            for session in sessions {
                let item = NSMenuItem(title: "  \(session.status.emoji) \(session.displayName)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // -- Settings section --
        let notchItem = NSMenuItem(
            title: "Mostrar notch",
            action: #selector(toggleNotch),
            keyEquivalent: ""
        )
        notchItem.target = self
        notchItem.state = settings.showNotch ? .on : .off
        menu.addItem(notchItem)

        let soundItem = NSMenuItem(
            title: "Sonido al completar",
            action: #selector(toggleSound),
            keyEquivalent: ""
        )
        soundItem.target = self
        soundItem.state = settings.soundEnabled ? .on : .off
        menu.addItem(soundItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Ducky",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleNotch() {
        settings.showNotch.toggle()
        if settings.showNotch {
            setupNotchWindow()
        } else {
            notchWindow?.orderOut(nil)
            notchWindow = nil
        }
    }

    @objc private func toggleSound() {
        settings.soundEnabled.toggle()
    }
}
