import Foundation
@testable import git_watch

final class FakeGHCLI: GHCLIRunning {
    var stubbedToken: String?

    func authToken() -> String? {
        stubbedToken
    }
}

enum UserDefaultsFactory {
    static func make() -> UserDefaults {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
