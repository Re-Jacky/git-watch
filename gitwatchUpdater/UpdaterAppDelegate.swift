import AppKit

final class UpdaterAppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: UpdaterWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let windowController = UpdaterWindowController()
        self.windowController = windowController
        windowController.showWindow(nil)

        Task { @MainActor in
            do {
                let contractURL = try Self.contractURLFromArguments()
                try UpdaterInstaller(fileManager: .default, workspace: .shared).install(from: contractURL)
                NSApp.terminate(nil)
            } catch {
                windowController.present(status: error.localizedDescription)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private static func contractURLFromArguments() throws -> URL {
        guard CommandLine.arguments.count > 1 else {
            throw UpdaterInstaller.InstallError.invalidContract("Missing install contract path.")
        }

        return URL(fileURLWithPath: CommandLine.arguments[1])
    }
}
