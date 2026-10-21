import Foundation
import Testing
import UserNotifications
@testable import NetworkCulprit

private func observation(_ seconds: TimeInterval, health: Health = .failed, layer: NetworkLayer? = .dns,
                         pathEvent: Bool = false) -> DiagnosticSnapshot {
    let finding = Finding(title: health == .good ? "No fault detected" : "Resolver path is failing", explanation: "Synthetic test evidence",
                          health: health, layer: health == .good ? nil : layer, confidence: "High", evidence: [], nextStep: "Inspect evidence")
    return DiagnosticSnapshot(date: Date(timeIntervalSince1970: 1_000_000 + seconds), kind: pathEvent ? "Network path event" : "Quick check",
                              context: NetworkContext(),
                              probes: pathEvent ? [Probe(key: "local.path-event", layer: .local, name: "Path event", target: "This Mac", health: health, detail: "Synthetic path event")]
                                : NetworkLayer.allCases.map { Probe(key: "fixture.\($0.rawValue)", layer: $0, name: "Synthetic check", target: "Test fixture", health: health, detail: "Synthetic measurement") },
                              finding: finding, duration: 1)
}

private func confirmedIncident() -> NetworkIncidentTracker {
    var tracker = NetworkIncidentTracker()
    _ = tracker.observe(observation(0)); _ = tracker.observe(observation(60))
    return tracker
}

@Test func briefNetworkBlipsNeverProduceStartOrOrphanRecoveryNotices() {
    var tracker = NetworkIncidentTracker()
    #expect(tracker.observe(observation(0)).isEmpty)
    #expect(tracker.followUpDelay == 30)
    #expect(tracker.observe(observation(25, health: .good)).isEmpty)
    #expect(tracker.observe(observation(120, health: .good)).isEmpty)
    #expect(tracker.incident == nil)
    #expect(tracker.followUpDelay == nil)
}

@Test func sustainedIssueProducesExactlyOneStartAfterTheThreshold() throws {
    var tracker = NetworkIncidentTracker()
    for time in [0.0, 30, 59] { #expect(tracker.observe(observation(time)).isEmpty) }
    let notice = try #require(tracker.observe(observation(60)).first)
    #expect(notice.kind == .started)
    #expect(notice.duration == 60)
    #expect(notice.issue.layer == .dns)
    #expect(tracker.followUpDelay == 60)
    for time in [90.0, 120, 180, 240] { #expect(tracker.observe(observation(time)).isEmpty) }
}

@Test func configurableConfirmationWindowsRequireRepeatedFreshObservations() throws {
    for threshold in [60.0, 120, 300] {
        var tracker = NetworkIncidentTracker()
        for time in stride(from: 0.0, to: threshold, by: 30) {
            #expect(tracker.observe(observation(time), minimumProblemDuration: threshold).isEmpty)
        }
        let notice = try #require(tracker.observe(observation(threshold), minimumProblemDuration: threshold).first)
        #expect(notice.duration == threshold)
    }
}

@Test func recoveryNeedsTwoHealthyChecksSpacedThirtySecondsAndUsesFirstHealthyTime() throws {
    var tracker = confirmedIncident()
    #expect(tracker.observe(observation(90, health: .good)).isEmpty)
    #expect(tracker.followUpDelay == 30)
    #expect(tracker.observe(observation(119, health: .good)).isEmpty)
    let recovery = try #require(tracker.observe(observation(120, health: .good)).first)
    #expect(recovery.kind == .recovered)
    #expect(recovery.duration == 90) // Confirmation time is not counted as outage time.
    #expect(tracker.observe(observation(180, health: .good)).isEmpty)
    #expect(tracker.followUpDelay == nil)
}

@Test func flappingDuringRecoveryRemainsOneIncident() throws {
    var tracker = confirmedIncident()
    let incidentID = try #require(tracker.incident?.id)
    #expect(tracker.observe(observation(90, health: .good)).isEmpty)
    #expect(tracker.observe(observation(100)).isEmpty)
    #expect(tracker.observe(observation(120, health: .good)).isEmpty)
    let recovery = try #require(tracker.observe(observation(150, health: .good)).first)
    #expect(recovery.incidentID == incidentID)
    #expect(recovery.duration == 120)
}

@Test func uncertainWarningsAndConnectedPathChangesDoNotCreateIncidents() {
    var tracker = NetworkIncidentTracker()
    for time in [0.0, 60, 120] { #expect(tracker.observe(observation(time, health: .warning, layer: nil)).isEmpty) }
    #expect(tracker.observe(observation(180, health: .warning, layer: .local, pathEvent: true)).isEmpty)
    #expect(tracker.incident == nil)
}

@Test func connectedRouteAloneDoesNotDeclareRecovery() throws {
    var tracker = NetworkIncidentTracker()
    #expect(tracker.observe(observation(0, layer: .local, pathEvent: true)).isEmpty)
    #expect(tracker.observe(observation(60, layer: .local, pathEvent: true)).first?.kind == .started)
    #expect(tracker.observe(observation(90, health: .warning, layer: .local, pathEvent: true)).isEmpty)
    #expect(tracker.incident?.startNoticeQueued == true)
    #expect(tracker.observe(observation(120, health: .good)).isEmpty)
    #expect(tracker.observe(observation(150, health: .good)).first?.kind == .recovered)
}

@Test func staleOrDuplicateResultsCannotConfirmOrClearAnIncident() throws {
    var tracker = NetworkIncidentTracker()
    _ = tracker.observe(observation(0))
    #expect(tracker.observe(observation(0)).isEmpty)
    #expect(tracker.incident?.problemSamples == 1)
    #expect(tracker.observe(observation(60)).first?.kind == .started)
    #expect(tracker.observe(observation(50, health: .good)).isEmpty)
    #expect(tracker.incident?.firstHealthy == nil)
    _ = tracker.observe(observation(90, health: .good))
    #expect(tracker.observe(observation(120, health: .good)).first?.kind == .recovered)
}

@Test func longObservationGapRestartsAnUnconfirmedCandidate() throws {
    var tracker = NetworkIncidentTracker()
    _ = tracker.observe(observation(0))
    #expect(tracker.observe(observation(600)).isEmpty)
    let notice = try #require(tracker.observe(observation(660)).first)
    #expect(notice.duration == 60)
}

@Test func widelySeparatedHealthySamplesDoNotConfirmRecovery() {
    var tracker = confirmedIncident()
    _ = tracker.observe(observation(90, health: .good))
    #expect(tracker.observe(observation(300, health: .good)).isEmpty)
    #expect(tracker.observe(observation(330, health: .good)).first?.duration == 300)
}

@Test func uncertainAssessmentInterruptsRecoveryConfirmation() {
    var tracker = confirmedIncident()
    _ = tracker.observe(observation(90, health: .good))
    _ = tracker.observe(observation(100, health: .warning, layer: nil))
    #expect(tracker.observe(observation(120, health: .good)).isEmpty)
    #expect(tracker.observe(observation(150, health: .good)).first?.duration == 120)
}

@Test func changingLikelyCulpritUpdatesOneOngoingIncident() throws {
    var tracker = confirmedIncident()
    let id = try #require(tracker.incident?.id)
    #expect(tracker.observe(observation(90, layer: .local)).isEmpty)
    _ = tracker.observe(observation(120, health: .good))
    let recovery = try #require(tracker.observe(observation(150, health: .good)).first)
    #expect(recovery.incidentID == id)
    #expect(recovery.issue.layer == .local)
}

@Test func sameLayerCooldownSuppressesAnotherBriefEpisodeButNotAPersistentRecurrence() {
    var tracker = confirmedIncident()
    _ = tracker.observe(observation(90, health: .good)); _ = tracker.observe(observation(120, health: .good))
    #expect(tracker.observe(observation(150)).isEmpty)
    #expect(tracker.observe(observation(210)).isEmpty)
    #expect(tracker.observe(observation(240, health: .good)).isEmpty)
    _ = tracker.observe(observation(300))
    #expect(tracker.observe(observation(360)).isEmpty)
    #expect(tracker.observe(observation(420)).first?.kind == .started)
}

@Test func aDifferentNetworkLayerDoesNotInheritThePreviousLayerCooldown() {
    var tracker = confirmedIncident()
    _ = tracker.observe(observation(90, health: .good)); _ = tracker.observe(observation(120, health: .good))
    _ = tracker.observe(observation(150, layer: .ipv6))
    #expect(tracker.observe(observation(210, layer: .ipv6)).first?.kind == .started)
}

@Test func restartPreservesDeduplicationAndPairsRecoveryWithOriginalIncident() throws {
    let original = confirmedIncident()
    var restored = try JSONDecoder().decode(NetworkIncidentTracker.self, from: JSONEncoder().encode(original))
    #expect(restored.observe(observation(90)).isEmpty)
    _ = restored.observe(observation(120, health: .good))
    let recovery = try #require(restored.observe(observation(150, health: .good)).first)
    #expect(recovery.incidentID == original.incident?.id)
}

@Test func persistentNotificationOutboxRetainsStableIdentifiersAndIncidentState() throws {
    var tracker = NetworkIncidentTracker()
    _ = tracker.observe(observation(0))
    let notices = tracker.observe(observation(60))
    let state = PersistedNetworkIncidentState(tracker: tracker, pendingNotices: notices)
    let restored = try JSONDecoder().decode(PersistedNetworkIncidentState.self, from: JSONEncoder().encode(state))
    #expect(restored.pendingNotices == notices)
    #expect(restored.tracker.incident?.id == notices.first?.incidentID)
}

@Test func nativeNotificationPayloadIncludesCulpritDurationAndRespectsSilentDefault() throws {
    var tracker = NetworkIncidentTracker()
    _ = tracker.observe(observation(0))
    let start = try #require(tracker.observe(observation(60)).first)
    _ = tracker.observe(observation(90, health: .good))
    let recovery = try #require(tracker.observe(observation(120, health: .good)).first)
    let content = recovery.notificationContent(playSound: false)
    #expect(content.title == "Network recovered")
    #expect(content.subtitle.contains("DNS / NextDNS"))
    #expect(content.body.contains(recovery.durationDescription))
    #expect(content.sound == nil)
    #expect(content.interruptionLevel == .active)
    #expect(start.id != recovery.id)
    #expect(start.notificationContent(playSound: true).sound != nil)
}

@Test func delayedStartAndRecoveryAreCoalescedInsteadOfBurstingAfterDeliveryFailure() {
    var state = PersistedNetworkIncidentState()
    _ = state.tracker.observe(observation(0))
    state.enqueue(state.tracker.observe(observation(60)), observedAt: observation(60).date)
    #expect(state.pendingNotices.count == 1)
    _ = state.tracker.observe(observation(90, health: .good))
    state.enqueue(state.tracker.observe(observation(120, health: .good)), observedAt: observation(120).date)
    #expect(state.pendingNotices.count == 1)
    #expect(state.pendingNotices.first?.kind == .recovered)
}

@Test func staleResolvedSummariesDoNotFloodNotificationsAfterAnOfflinePeriod() {
    var state = PersistedNetworkIncidentState()
    _ = state.tracker.observe(observation(0))
    state.enqueue(state.tracker.observe(observation(60)), observedAt: observation(60).date)
    _ = state.tracker.observe(observation(90, health: .good))
    state.enqueue(state.tracker.observe(observation(120, health: .good)), observedAt: observation(120).date)
    state.enqueue([], observedAt: observation(2000).date)
    #expect(state.pendingNotices.isEmpty)
}

@Test func unavailableAffectedLayerCannotBeReportedAsRecovered() {
    var tracker = confirmedIncident()
    for time in [90.0, 120] {
        var missing = observation(time, health: .good)
        missing.probes.removeAll { $0.layer == .dns }
        missing.probes.append(Probe(key: "fixture.missing", layer: .dns, name: "Missing integration", target: "Test", health: .unavailable, detail: "Not measured"))
        #expect(tracker.observe(missing).isEmpty)
    }
    _ = tracker.observe(observation(150, health: .good))
    #expect(tracker.observe(observation(180, health: .good)).first?.duration == 150)
}

@Test func anEmptyHealthyAssessmentCannotEstablishRecovery() {
    var tracker = confirmedIncident()
    for time in [90.0, 120] {
        var empty = observation(time, health: .good); empty.probes = []
        #expect(tracker.observe(empty).isEmpty)
    }
    #expect(tracker.incident?.startNoticeQueued == true)
}
