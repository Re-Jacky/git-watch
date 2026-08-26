import Foundation

struct UpdateInstallPlanner {
    let fileManager: FileManager

    func makeContract(expectedVersion: String, stagedAppURL: URL, installedAppURL: URL) throws -> UpdateInstallContract {
        let appBundleName = installedAppURL.lastPathComponent
        let appName = installedAppURL.deletingPathExtension().lastPathComponent
        let appExtension = installedAppURL.pathExtension
        let backupFileName = appExtension.isEmpty ? "\(appName).backup" : "\(appName).backup.\(appExtension)"
        let backupAppURL = installedAppURL.deletingLastPathComponent().appendingPathComponent(backupFileName)
        let markerURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GitWatch/update-success")

        return UpdateInstallContract(
            appBundleName: appBundleName,
            expectedVersion: expectedVersion,
            stagedAppPath: stagedAppURL.path,
            installedAppPath: installedAppURL.path,
            backupAppPath: backupAppURL.path,
            relaunchMarkerPath: markerURL.path,
            runningAppPID: ProcessInfo.processInfo.processIdentifier
        )
    }
}
