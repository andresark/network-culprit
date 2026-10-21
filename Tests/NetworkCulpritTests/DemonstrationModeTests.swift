import Foundation
import Testing
@testable import NetworkCulprit

@Test @MainActor func demonstrationDoesNotOpenLiveHistoryOrStartMonitoring() async {
    let savedSettings = UserDefaults.standard.data(forKey: "networkDiagnosticSettings")
    let savedNotifications = UserDefaults.standard.data(forKey: "networkIncidentNotificationPreferences")
    let store = DiagnosticStore(demonstration: true)
    #expect(store.database == nil)
    #expect(store.totalRecords == 36)
    #expect(store.latest?.finding.layer == .dns)
    store.settings.intervalSeconds = 60
    store.configureSampling(); store.run(speedTest: true)
    store.loginItem.setEnabled(true)
    await store.incidentNotifications.setEnabled(true)
    await store.incidentNotifications.sendTestNotification()
    #expect(!store.isRunning)
    #expect(UserDefaults.standard.data(forKey: "networkDiagnosticSettings") == savedSettings)
    #expect(UserDefaults.standard.data(forKey: "networkIncidentNotificationPreferences") == savedNotifications)
    #expect(!FileManager.default.fileExists(atPath: store.dataDirectory.path))
    store.showDemonstration(.healthy)
    #expect(store.latest?.finding.health == .good)
    store.showDemonstration(.staleIPv6)
    #expect(store.latest?.finding.layer == .ipv6)
}
