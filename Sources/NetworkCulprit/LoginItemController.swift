import Foundation
import Observation
import ServiceManagement

/// Registers this signed application with macOS; no separate daemon or agent.
@MainActor @Observable final class LoginItemController {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var errorMessage: String?

    init() { refresh() }

    var isRequested: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }
    var description: String {
        switch status {
        case .enabled: "Enabled — starts quietly in the menu bar at login"
        case .requiresApproval: "Waiting for approval in macOS Login Items"
        case .notRegistered: "Off — open the app manually to start monitoring"
        case .notFound: "macOS could not find this installed application"
        @unknown default: "Unknown macOS login-item status"
        }
    }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        refresh()
        do {
            if enabled && status != .enabled && status != .requiresApproval {
                try SMAppService.mainApp.register()
            } else if !enabled && status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch { errorMessage = "Could not change launch at login: \(error.localizedDescription)" }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
