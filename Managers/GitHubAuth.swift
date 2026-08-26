import Combine
import Foundation

enum TokenResolution: Equatable {
    case patOverride(String)
    case ghCLI(String)
    case none

    var token: String? {
        switch self {
        case let .patOverride(token), let .ghCLI(token):
            return token.isEmpty ? nil : token
        case .none:
            return nil
        }
    }
}

protocol GHCLIRunning {
    func authToken() -> String?
}

final class GhCLI: GHCLIRunning {
    private static let candidates = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh"
    ]

    func authToken() -> String? {
        for candidate in Self.candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return runToken(executablePath: candidate)
        }
        return nil
    }

    private func runToken(executablePath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["auth", "token"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (token?.isEmpty == false) ? token : nil
        } catch {
            return nil
        }
    }
}

final class GitHubAuthProvider: ObservableObject {
    @Published private(set) var resolution: TokenResolution = .none

    private let settings: GitHubSettings
    private let ghCLI: GHCLIRunning

    init(settings: GitHubSettings, ghCLI: GHCLIRunning) {
        self.settings = settings
        self.ghCLI = ghCLI
    }

    convenience init(settings: GitHubSettings) {
        self.init(settings: settings, ghCLI: GhCLI())
    }

    func resolve() {
        if settings.personalAccessToken.isEmpty == false {
            resolution = .patOverride(settings.personalAccessToken)
            return
        }
        if let token = ghCLI.authToken() {
            resolution = .ghCLI(token)
            return
        }
        resolution = .none
    }
}
