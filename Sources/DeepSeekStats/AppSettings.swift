import Foundation
import ServiceManagement

@MainActor
final class AppSettings {
    static let supportedRefreshIntervals = [1, 5, 15, 30]

    private let defaults: UserDefaults
    private let refreshIntervalKey = "refresh_interval_minutes"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var refreshIntervalMinutes: Int {
        get {
            let value = defaults.integer(forKey: refreshIntervalKey)
            return Self.supportedRefreshIntervals.contains(value) ? value : 5
        }
        set {
            defaults.set(Self.supportedRefreshIntervals.contains(newValue) ? newValue : 5,
                         forKey: refreshIntervalKey)
        }
    }
}

@MainActor
final class LoginItemManager {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
