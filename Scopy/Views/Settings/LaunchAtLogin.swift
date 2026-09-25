import ServiceManagement

/// The login item is system state owned by `SMAppService`, not a `SettingsDTO` field: the
/// settings window reads it on open and writes it only on Save.
enum LaunchAtLogin {
    /// Registered, including a registration still waiting for approval in System Settings.
    static var isRegistered: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func apply(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
