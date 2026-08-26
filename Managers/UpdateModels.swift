import Foundation

struct AppRelease: Equatable {
    let version: String
    let notesURL: URL?
    let zipAssetURL: URL
    let checksum: String?
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(lastCheckedAt: Date)
    case updateAvailable(AppRelease)
    case downloading(AppRelease)
    case readyToInstall(AppRelease, stagedZipURL: URL, stagedAppURL: URL)
    case launchingInstaller(AppRelease)
    case failed(message: String)
}

enum UpdateCheckPolicy {
    static func shouldRunAutomaticCheck(now: Date, lastSuccessfulCheckAt: Date?) -> Bool {
        guard let lastSuccessfulCheckAt else { return true }
        return now.timeIntervalSince(lastSuccessfulCheckAt) >= 24 * 60 * 60
    }
}

struct UpdateInstallContract: Codable, Equatable {
    let appBundleName: String
    let expectedVersion: String
    let stagedAppPath: String
    let installedAppPath: String
    let backupAppPath: String
    let relaunchMarkerPath: String
    let runningAppPID: Int32
}

enum UpdateRecovery {
    static func attemptBackupRestore(fileManager: FileManager, backupAppURL: URL, installedAppURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: backupAppURL.path) else { return false }
        try? fileManager.removeItem(at: installedAppURL)
        do {
            try fileManager.moveItem(at: backupAppURL, to: installedAppURL)
            return true
        } catch {
            return false
        }
    }
}

enum AppBundleVersionReader {
    static func marketingVersion(at bundleURL: URL) throws -> String {
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: infoPlistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)

        guard let dictionary = plist as? [String: Any],
              let version = dictionary["CFBundleShortVersionString"] as? String,
              version.isEmpty == false else {
            throw NSError(domain: "AppBundleVersionReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "The staged app is missing a marketing version."])
        }

        return version
    }

    static func validateExpectedVersion(at bundleURL: URL, expectedVersion: String) throws {
        let version = try marketingVersion(at: bundleURL)
        guard version == expectedVersion else {
            throw NSError(domain: "AppBundleVersionReader", code: 2, userInfo: [NSLocalizedDescriptionKey: "The staged app version does not match the expected update version."])
        }
    }
}
