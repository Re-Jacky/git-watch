import Foundation
import Combine
import AppKit
import CryptoKit

protocol UpdateClient {
    func fetchLatestRelease() async throws -> AppRelease
}

final class UpdateManager: ObservableObject {
    static let lastSuccessfulCheckKey = "update.lastSuccessfulCheckAt"
    static let pendingLaunchMarkerKey = "update.pendingLaunchMarkerPath"
    static let pendingBackupPathKey = "update.pendingBackupPath"
    static let pendingInstalledPathKey = "update.pendingInstalledPath"

    @Published private(set) var state: UpdateState = .idle
    private var automaticCheckTimer: Timer?

    private let currentVersion: String
    private let client: UpdateClient
    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private let now: () -> Date
    private let urlSession: URLSession
    private let extractArchive: (URL, URL) throws -> Void
    private let installedAppURL: () -> URL
    private let updaterAppURL: () -> URL
    private let launchUpdater: (URL, URL) throws -> Void

    init(
        currentVersion: String = AppVersionInfo().appVersion ?? "0",
        client: UpdateClient,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        urlSession: URLSession = .shared,
        extractArchive: @escaping (URL, URL) throws -> Void = { zipURL, expandedDirectory in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zipURL.path, expandedDirectory.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw UpdateError.extractionFailed(exitCode: process.terminationStatus)
            }
        },
        installedAppURL: @escaping () -> URL = {
            UpdateManager.defaultInstalledAppURL(for: Bundle.main.bundleURL)
        },
        updaterAppURL: @escaping () -> URL = {
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/GitWatchUpdater.app")
        },
        launchUpdater: @escaping (URL, URL) throws -> Void = UpdateManager.launchUpdaterHelper
    ) {
        self.currentVersion = currentVersion
        self.client = client
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.now = now
        self.urlSession = urlSession
        self.extractArchive = extractArchive
        self.installedAppURL = installedAppURL
        self.updaterAppURL = updaterAppURL
        self.launchUpdater = launchUpdater
    }

    func startAutomaticChecks() {
        automaticCheckTimer?.invalidate()
        automaticCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkForUpdates(userInitiated: false)
            }
        }
    }

    @MainActor
    func checkForUpdates(userInitiated: Bool) async {
        let lastSuccessfulCheckAt = userDefaults.object(forKey: Self.lastSuccessfulCheckKey) as? Date
        if userInitiated == false,
           UpdateCheckPolicy.shouldRunAutomaticCheck(now: now(), lastSuccessfulCheckAt: lastSuccessfulCheckAt) == false {
            return
        }

        state = .checking

        do {
            let release = try await client.fetchLatestRelease()
            let checkedAt = now()
            userDefaults.set(checkedAt, forKey: Self.lastSuccessfulCheckKey)

            if AppVersionInfo(versionString: currentVersion).isOlder(than: release.version) {
                state = .updateAvailable(release)
            } else {
                state = .upToDate(lastCheckedAt: checkedAt)
            }
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    @MainActor
    func acceptVerifiedStagedUpdate(release: AppRelease, stagedZipURL: URL, stagedAppURL: URL) throws {
        guard stagedAppURL.lastPathComponent == "GitWatch.app" else {
            throw NSError(domain: "UpdateManager", code: 20, userInfo: [NSLocalizedDescriptionKey: "Expanded archive did not contain GitWatch.app"])
        }
        guard fileManager.fileExists(atPath: stagedAppURL.path) else {
            throw NSError(domain: "UpdateManager", code: 21, userInfo: [NSLocalizedDescriptionKey: "Expanded archive did not contain GitWatch.app"])
        }

        state = .readyToInstall(release, stagedZipURL: stagedZipURL, stagedAppURL: stagedAppURL)
    }

    @MainActor
    func downloadAvailableUpdate(_ release: AppRelease) async {
        state = .downloading(release)

        do {
            let zipURL = fileManager.temporaryDirectory.appendingPathComponent("GitWatch-\(release.version)-updater.zip")
            let (data, response) = try await urlSession.data(from: release.zipAssetURL)

            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw UpdateError.httpError(statusCode: code)
            }

            if fileManager.fileExists(atPath: zipURL.path) {
                try fileManager.removeItem(at: zipURL)
            }
            try data.write(to: zipURL)

            if let expectedChecksum = release.checksum {
                let actualChecksum = try sha256OfFile(at: zipURL)
                guard actualChecksum == expectedChecksum else {
                    throw UpdateError.checksumMismatch(expected: expectedChecksum, actual: actualChecksum)
                }
            }

            let expandedDirectory = fileManager.temporaryDirectory.appendingPathComponent("GitWatch-\(release.version)-expanded")
            try? fileManager.removeItem(at: expandedDirectory)
            try fileManager.createDirectory(at: expandedDirectory, withIntermediateDirectories: true)

            let stagedAppURL = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    do {
                        try self.extractArchive(zipURL, expandedDirectory)
                        continuation.resume(returning: expandedDirectory.appendingPathComponent("GitWatch.app"))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            try acceptVerifiedStagedUpdate(release: release, stagedZipURL: zipURL, stagedAppURL: stagedAppURL)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    @MainActor
    func beginInstall() async throws {
        guard case let .readyToInstall(release, _, stagedAppURL) = state else { return }

        let helperURL = updaterAppURL()
        guard fileManager.fileExists(atPath: helperURL.path) else {
            throw InstallError.missingUpdaterHelper
        }

        let contract = try UpdateInstallPlanner(fileManager: fileManager).makeContract(
            expectedVersion: release.version,
            stagedAppURL: stagedAppURL,
            installedAppURL: installedAppURL()
        )
        let contractURL = try writeInstallContract(contract)
        try launchUpdater(helperURL, contractURL)
        userDefaults.set(contract.relaunchMarkerPath, forKey: Self.pendingLaunchMarkerKey)
        userDefaults.set(contract.backupAppPath, forKey: Self.pendingBackupPathKey)
        userDefaults.set(contract.installedAppPath, forKey: Self.pendingInstalledPathKey)
        state = .launchingInstaller(release)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.userDefaults.synchronize()
            NSApp.terminate(nil)
        }
    }

    @MainActor
    func present(error: Error) {
        state = .failed(message: error.localizedDescription)
    }

    func performPostUpgradeTasks() {
        guard let markerPath = userDefaults.string(forKey: Self.pendingLaunchMarkerKey) else { return }

        let markerURL = URL(fileURLWithPath: markerPath)
        let backupPath = userDefaults.string(forKey: Self.pendingBackupPathKey)
        let installedPath = userDefaults.string(forKey: Self.pendingInstalledPathKey)

        if fileManager.fileExists(atPath: markerURL.path) {
            // Upgrade succeeded — clean up backup and temp files
            try? fileManager.removeItem(at: markerURL.deletingLastPathComponent())
            if let backupPath {
                try? fileManager.removeItem(at: URL(fileURLWithPath: backupPath))
            }

            // Clean up contract files and expanded directories
            let contractsDir = fileManager.temporaryDirectory.appendingPathComponent("pulse-updater")
            try? fileManager.removeItem(at: contractsDir)
            let expandedDirs = (try? fileManager.contentsOfDirectory(atPath: fileManager.temporaryDirectory.path))?
                .filter { $0.hasPrefix("GitWatch-") && $0.hasSuffix("-expanded") }
            for dir in expandedDirs ?? [] {
                try? fileManager.removeItem(at: fileManager.temporaryDirectory.appendingPathComponent(dir))
            }
        } else {
            // No marker — attempt backup restore
            if let backupPath, let installedPath {
                _ = UpdateRecovery.attemptBackupRestore(
                    fileManager: fileManager,
                    backupAppURL: URL(fileURLWithPath: backupPath),
                    installedAppURL: URL(fileURLWithPath: installedPath)
                )
            }
        }

        userDefaults.removeObject(forKey: Self.pendingLaunchMarkerKey)
        userDefaults.removeObject(forKey: Self.pendingBackupPathKey)
        userDefaults.removeObject(forKey: Self.pendingInstalledPathKey)
    }

    func writeLaunchSuccessMarker(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: url)
    }

    @MainActor
    func setStateForTesting(_ newState: UpdateState) {
        state = newState
    }

    private func writeInstallContract(_ contract: UpdateInstallContract) throws -> URL {
        let contractsDirectory = fileManager.temporaryDirectory.appendingPathComponent("pulse-updater", isDirectory: true)
        try fileManager.createDirectory(at: contractsDirectory, withIntermediateDirectories: true)

        let contractURL = contractsDirectory.appendingPathComponent("install-contract-\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(contract)
        try data.write(to: contractURL, options: .atomic)
        return contractURL
    }

    private static func launchUpdaterHelper(appURL: URL, contractURL: URL) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.arguments = [contractURL.path]

        var launchError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            launchError = error
            semaphore.signal()
        }
        semaphore.wait()

        if let launchError {
            throw launchError
        }
    }

    static func defaultInstalledAppURL(for bundleURL: URL) -> URL {
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }

        let contentsURL = bundleURL.deletingLastPathComponent()
        if contentsURL.lastPathComponent == "Contents" {
            return contentsURL.deletingLastPathComponent()
        }

        return bundleURL
    }

    private func sha256OfFile(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    enum UpdateError: LocalizedError {
        case httpError(statusCode: Int)
        case checksumMismatch(expected: String, actual: String)
        case extractionFailed(exitCode: Int32)

        var errorDescription: String? {
            switch self {
            case .httpError(let code):
                return "Download failed with HTTP status \(code)."
            case .checksumMismatch:
                return "Downloaded archive checksum does not match expected value."
            case .extractionFailed(let code):
                return "Archive extraction failed with exit code \(code)."
            }
        }
    }

    enum InstallError: LocalizedError {
        case missingUpdaterHelper

        var errorDescription: String? {
            switch self {
            case .missingUpdaterHelper:
                return "The bundled updater helper is missing."
            }
        }
    }
}
