import AppKit
import Foundation

struct UpdaterInstaller {
    let fileManager: FileManager
    let workspace: NSWorkspace

    func install(from contractURL: URL) throws {
        let data = try Data(contentsOf: contractURL)
        let contract = try JSONDecoder().decode(UpdateInstallContract.self, from: data)

        let stagedAppURL = URL(fileURLWithPath: contract.stagedAppPath)
        let installedAppURL = URL(fileURLWithPath: contract.installedAppPath)
        let backupAppURL = URL(fileURLWithPath: contract.backupAppPath)
        let markerURL = URL(fileURLWithPath: contract.relaunchMarkerPath)

        guard fileManager.fileExists(atPath: stagedAppURL.path) else {
            throw InstallError.invalidContract("Staged app is missing.")
        }

        do {
            try AppBundleVersionReader.validateExpectedVersion(at: stagedAppURL, expectedVersion: contract.expectedVersion)
        } catch {
            throw InstallError.invalidContract(error.localizedDescription)
        }

        waitForProcessToExit(pid: contract.runningAppPID)

        if fileManager.fileExists(atPath: backupAppURL.path) {
            try fileManager.removeItem(at: backupAppURL)
        }

        if fileManager.fileExists(atPath: installedAppURL.path) {
            try fileManager.moveItem(at: installedAppURL, to: backupAppURL)
        }

        do {
            try fileManager.moveItem(at: stagedAppURL, to: installedAppURL)
        } catch {
            if fileManager.fileExists(atPath: backupAppURL.path), fileManager.fileExists(atPath: installedAppURL.path) == false {
                try? fileManager.moveItem(at: backupAppURL, to: installedAppURL)
            }
            throw error
        }

        try fileManager.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: markerURL, options: .atomic)

        var relaunchError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        workspace.openApplication(at: installedAppURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            relaunchError = error
            semaphore.signal()
        }
        semaphore.wait()

        if let error = relaunchError {
            try? fileManager.removeItem(at: markerURL)
            _ = UpdateRecovery.attemptBackupRestore(fileManager: fileManager, backupAppURL: backupAppURL, installedAppURL: installedAppURL)
            workspace.openApplication(at: installedAppURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            throw InstallError.relaunchFailed(error.localizedDescription)
        }
    }

    private func waitForProcessToExit(pid: Int32) {
        let deadline = DispatchTime.now() + .seconds(10)
        while DispatchTime.now() < deadline {
            if kill(pid, 0) != 0 {
                return
            }
            usleep(200_000)
        }
    }

    enum InstallError: LocalizedError {
        case invalidContract(String)
        case relaunchFailed(String)

        var errorDescription: String? {
            switch self {
            case let .invalidContract(message):
                return message
            case let .relaunchFailed(message):
                return message
            }
        }
    }
}
