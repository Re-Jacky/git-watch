import Combine
import Foundation
import ServiceManagement

protocol LaunchAtLoginService {
    var isEnabled: Bool { get }
    func register() throws
    func unregister() throws
}

struct SMAppServiceLaunchAtLoginService: LaunchAtLoginService {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

final class LaunchAtLoginSettings: ObservableObject {
    static let userDefaultsKey = "general.launchAtLogin"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var errorMessage: String?

    private let service: LaunchAtLoginService
    private let userDefaults: UserDefaults

    init(service: LaunchAtLoginService = SMAppServiceLaunchAtLoginService(), userDefaults: UserDefaults = .standard) {
        self.service = service
        self.userDefaults = userDefaults
        isEnabled = service.isEnabled
        errorMessage = nil
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            isEnabled = enabled
            userDefaults.set(enabled, forKey: Self.userDefaultsKey)
            errorMessage = nil
        } catch {
            let actual = service.isEnabled
            isEnabled = actual
            userDefaults.set(actual, forKey: Self.userDefaultsKey)
            errorMessage = "GitWatch could not be updated in Login Items. Open System Settings > General > Login Items and add GitWatch manually."
        }
    }

    func refresh() {
        isEnabled = service.isEnabled
        errorMessage = nil
    }
}
