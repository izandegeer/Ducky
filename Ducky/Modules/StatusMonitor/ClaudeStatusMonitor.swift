import Foundation
import SwiftUI

enum ClaudeSystemStatus: String {
    case operational
    case degradedPerformance = "degraded_performance"
    case partialOutage = "partial_outage"
    case majorOutage = "major_outage"
    case unknown
}

struct StatusIncident {
    let name: String
    let status: String  // investigating, identified, monitoring, resolved
    let impact: String  // critical, major, minor, none
    let createdAt: Date
}

@Observable
class ClaudeStatusMonitor {
    static let shared = ClaudeStatusMonitor()

    var overallStatus: ClaudeSystemStatus = .unknown
    var statusDescription: String = ""
    var claudeCodeStatus: ClaudeSystemStatus = .unknown
    var activeIncidents: [StatusIncident] = []
    var lastChecked: Date?

    private var pollingTimer: Timer?

    private init() {
        fetchAll()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.fetchAll()
        }
    }

    deinit {
        pollingTimer?.invalidate()
    }

    // MARK: - Color helper

    var statusColor: Color {
        colorFor(overallStatus)
    }

    var claudeCodeStatusColor: Color {
        colorFor(claudeCodeStatus)
    }

    func colorFor(_ status: ClaudeSystemStatus) -> Color {
        switch status {
        case .operational: return .green
        case .degradedPerformance: return .yellow
        case .partialOutage: return .orange
        case .majorOutage: return .red
        case .unknown: return Color(white: 0.4)
        }
    }

    var displayLabel: String {
        switch overallStatus {
        case .operational: return "operational"
        case .degradedPerformance: return "degraded performance"
        case .partialOutage: return "partial outage"
        case .majorOutage: return "major outage"
        case .unknown: return "unknown"
        }
    }

    var claudeCodeDisplayLabel: String {
        switch claudeCodeStatus {
        case .operational: return "operational"
        case .degradedPerformance: return "degraded performance"
        case .partialOutage: return "partial outage"
        case .majorOutage: return "major outage"
        case .unknown: return "unknown"
        }
    }

    /// Whether there is something worth showing (non-operational)
    var hasIssues: Bool {
        overallStatus != .operational || claudeCodeStatus != .operational || !activeIncidents.isEmpty
    }

    // MARK: - Fetch

    private func fetchAll() {
        fetchStatus()
        fetchComponents()
        fetchIncidents()
    }

    private func fetchStatus() {
        guard let url = URL(string: "https://status.claude.com/api/v2/status.json") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data, error == nil else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let statusObj = json["status"] as? [String: Any],
                  let indicator = statusObj["indicator"] as? String,
                  let description = statusObj["description"] as? String else { return }

            let mapped = Self.mapIndicator(indicator)
            DispatchQueue.main.async {
                self?.overallStatus = mapped
                self?.statusDescription = description
                self?.lastChecked = Date()
            }
        }.resume()
    }

    private func fetchComponents() {
        guard let url = URL(string: "https://status.claude.com/api/v2/components.json") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data, error == nil else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let components = json["components"] as? [[String: Any]] else { return }

            let claudeCode = components.first { ($0["name"] as? String) == "Claude Code" }
            let statusStr = claudeCode?["status"] as? String ?? "unknown"
            let mapped = Self.mapComponentStatus(statusStr)

            DispatchQueue.main.async {
                self?.claudeCodeStatus = mapped
            }
        }.resume()
    }

    private func fetchIncidents() {
        guard let url = URL(string: "https://status.claude.com/api/v2/incidents.json") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data, error == nil else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let incidents = json["incidents"] as? [[String: Any]] else { return }

            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let fallbackFormatter = ISO8601DateFormatter()
            fallbackFormatter.formatOptions = [.withInternetDateTime]

            let active: [StatusIncident] = incidents.compactMap { inc in
                guard let name = inc["name"] as? String,
                      let status = inc["status"] as? String,
                      let impact = inc["impact"] as? String else { return nil }

                // Filter out resolved/postmortem
                if status == "resolved" || status == "postmortem" { return nil }

                let createdAtStr = inc["created_at"] as? String ?? ""
                let createdAt = dateFormatter.date(from: createdAtStr)
                    ?? fallbackFormatter.date(from: createdAtStr)
                    ?? Date()

                return StatusIncident(name: name, status: status, impact: impact, createdAt: createdAt)
            }

            DispatchQueue.main.async {
                self?.activeIncidents = active
            }
        }.resume()
    }

    // MARK: - Mapping helpers

    private static func mapIndicator(_ indicator: String) -> ClaudeSystemStatus {
        switch indicator {
        case "none": return .operational
        case "minor": return .degradedPerformance
        case "major": return .partialOutage
        case "critical": return .majorOutage
        default: return .unknown
        }
    }

    private static func mapComponentStatus(_ status: String) -> ClaudeSystemStatus {
        switch status {
        case "operational": return .operational
        case "degraded_performance": return .degradedPerformance
        case "partial_outage": return .partialOutage
        case "major_outage": return .majorOutage
        default: return .unknown
        }
    }
}
