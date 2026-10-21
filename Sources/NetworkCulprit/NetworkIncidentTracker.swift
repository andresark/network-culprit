import Foundation

struct NetworkIssueSummary: Codable, Equatable, Sendable {
    var layer: NetworkLayer
    var title: String
    var confidence: String
}

struct NetworkIncidentNotice: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case started, recovered }
    var incidentID: UUID
    var kind: Kind
    var issue: NetworkIssueSummary
    var firstObserved: Date
    var observedThrough: Date
    var id: String { "local.NetworkCulprit.network-incident.\(incidentID.uuidString).\(kind.rawValue)" }
    var duration: TimeInterval { max(0, observedThrough.timeIntervalSince(firstObserved)) }
    var durationDescription: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration < 3600 ? [.minute, .second] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(1, duration)) ?? "less than a minute"
    }
}

/// Sample-based incident state, independent of Notification Center and clocks.
/// Persisting this value preserves deduplication and recovery pairing on restart.
struct NetworkIncidentTracker: Codable, Sendable {
    struct Incident: Codable, Sendable {
        var id = UUID()
        var issue: NetworkIssueSummary
        var firstProblem: Date
        var lastProblem: Date
        var problemSamples = 1
        var startNoticeQueued = false
        var firstHealthy: Date?
        var lastHealthy: Date?
        var healthySamples = 0
    }
    struct Recovery: Codable, Sendable { var layer: NetworkLayer; var confirmedAt: Date }
    var incident: Incident?
    var lastObservation: Date?
    var lastRecovery: Recovery?

    private static let maximumConfirmationGap: TimeInterval = 120
    private static let recoveryConfirmationDuration: TimeInterval = 30
    private static let repeatAlertCooldown: TimeInterval = 300

    /// Faster checks only while confirming or following an observed incident.
    var followUpDelay: TimeInterval? {
        guard let incident else { return nil }
        return incident.startNoticeQueued && incident.firstHealthy == nil ? 60 : 30
    }

    mutating func observe(_ snapshot: DiagnosticSnapshot, minimumProblemDuration: TimeInterval = 60) -> [NetworkIncidentNotice] {
        let date = snapshot.date
        // A path event can arrive while an older diagnostic is still running.
        guard lastObservation.map({ date > $0 }) ?? true else { return [] }
        lastObservation = date

        let pathEvent = snapshot.kind == "Network path event"
        // An unavailable/uninstalled integration is not evidence that the
        // previously failing layer recovered, even if other paths are healthy.
        let affectedLayerHealthy = incident.map { snapshot.layerHealth($0.issue.layer) == .good } ?? true
        let isHealthy = !pathEvent && snapshot.finding.health == .good && affectedLayerHealthy && snapshot.probes.contains { $0.health == .good }
        let issue: NetworkIssueSummary?
        if pathEvent {
            issue = snapshot.probes.contains(where: { $0.key == "local.path-event" && $0.health == .failed })
                ? NetworkIssueSummary(layer: .local, title: "Local network connection unavailable", confidence: "Measured") : nil
        } else if snapshot.finding.health != .good, let layer = snapshot.finding.layer {
            issue = NetworkIssueSummary(layer: layer, title: snapshot.finding.title, confidence: snapshot.finding.confidence)
        } else { issue = nil }

        if let issue {
            if incident == nil || (incident?.startNoticeQueued == false && date.timeIntervalSince(incident!.lastProblem) > Self.maximumConfirmationGap) {
                incident = Incident(issue: issue, firstProblem: date, lastProblem: date)
            } else {
                incident!.issue = issue
                incident!.lastProblem = date
                incident!.problemSamples += 1
                incident!.firstHealthy = nil; incident!.lastHealthy = nil; incident!.healthySamples = 0
            }
            guard var current = incident else { return [] }
            let cooledDown = lastRecovery.map { $0.layer != issue.layer || date.timeIntervalSince($0.confirmedAt) >= Self.repeatAlertCooldown } ?? true
            if !current.startNoticeQueued, current.problemSamples >= 2,
               date.timeIntervalSince(current.firstProblem) >= max(60, minimumProblemDuration), cooledDown {
                current.startNoticeQueued = true
                incident = current
                return [NetworkIncidentNotice(incidentID: current.id, kind: .started, issue: issue,
                                              firstObserved: current.firstProblem, observedThrough: date)]
            }
        } else if isHealthy {
            guard var current = incident else { return [] }
            // No recovery alert for an unannounced brief blip.
            guard current.startNoticeQueued else { incident = nil; return [] }
            if current.lastHealthy.map({ date.timeIntervalSince($0) > Self.maximumConfirmationGap }) ?? true {
                current.firstHealthy = date; current.healthySamples = 1
            } else { current.healthySamples += 1 }
            current.lastHealthy = date
            incident = current
            if current.healthySamples >= 2, let firstHealthy = current.firstHealthy,
               date.timeIntervalSince(firstHealthy) >= Self.recoveryConfirmationDuration {
                incident = nil
                lastRecovery = Recovery(layer: current.issue.layer, confirmedAt: date)
                return [NetworkIncidentNotice(incidentID: current.id, kind: .recovered, issue: current.issue,
                                              firstObserved: current.firstProblem, observedThrough: firstHealthy)]
            }
        } else if var current = incident {
            // A connected route or uncertain assessment is not proof of recovery.
            current.firstHealthy = nil; current.lastHealthy = nil; current.healthySamples = 0
            incident = !current.startNoticeQueued && date.timeIntervalSince(current.lastProblem) > Self.maximumConfirmationGap ? nil : current
        }
        return []
    }
}
