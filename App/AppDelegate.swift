import AppKit
import Combine
import SwiftUI

enum SettingsWindowMetrics {
    static let defaultWidth: CGFloat = 780
    static let defaultHeight: CGFloat = 540
    static let minWidth: CGFloat = 520
    static let minHeight: CGFloat = 280
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: NSPanel?
    private var settingsWindow: NSWindow?
    private var hasPresentedSettingsWindow = false
    private var cancellables = Set<AnyCancellable>()
    private let themeManager = ThemeManager()
    private let launchAtLoginSettings = LaunchAtLoginSettings()
    private lazy var updateManager = UpdateManager(client: LiveUpdateClient(repoOwner: "Re-Jacky", repoName: "git-watch"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupThemeObservation()
        setupStatusItem()
        launchAtLoginSettings.refresh()

        Task { @MainActor [weak self] in
            await self?.updateManager.checkForUpdates(userInitiated: true)
            self?.updateManager.startAutomaticChecks()
        }
        updateManager.performPostUpgradeTasks()
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "git.pullrequest", accessibilityDescription: "GitWatch")
        button.image?.isTemplate = true
        button.action = #selector(handleClick)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    @objc func togglePanel() {
    }

    func openPanelIfPossible() {
    }

    private func setupThemeObservation() {
        themeManager.$currentTheme
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyCurrentTheme()
            }
            .store(in: &cancellables)
    }

    private func applyCurrentTheme() {
        settingsWindow?.appearance = themeManager.currentTheme.nsAppearance
        settingsWindow?.contentViewController?.view.appearance = themeManager.currentTheme.nsAppearance
        settingsWindow?.contentView?.needsDisplay = true
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open", action: #selector(togglePanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let refreshItem = NSMenuItem(title: "Refresh", action: nil, keyEquivalent: "")
        menu.addItem(refreshItem)
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit GitWatch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.title = "GitWatch"
        appMenuItem.submenu = appMenu
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        let closeItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = [.command]
        windowMenu.addItem(closeItem)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func showSettings() {
        launchAtLoginSettings.refresh()
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        window.appearance = themeManager.currentTheme.nsAppearance
        window.contentViewController?.view.appearance = themeManager.currentTheme.nsAppearance
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isVisible {
            if hasPresentedSettingsWindow == false {
                window.setFrame(
                    NSRect(x: window.frame.origin.x, y: window.frame.origin.y, width: SettingsWindowMetrics.defaultWidth, height: SettingsWindowMetrics.defaultHeight),
                    display: false
                )
            }
            window.center()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.arrangeInFront(nil)
        hasPresentedSettingsWindow = true
    }

    func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsWindowMetrics.defaultWidth, height: SettingsWindowMetrics.defaultHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: SettingsWindowMetrics.minWidth, height: SettingsWindowMetrics.minHeight)
        window.appearance = themeManager.currentTheme.nsAppearance
        window.isExcludedFromWindowsMenu = false
        window.delegate = self

        let controller = NSHostingController(
            rootView: SettingsView()
                .environmentObject(themeManager)
                .environmentObject(updateManager)
                .environmentObject(launchAtLoginSettings)
        )
        controller.view.appearance = themeManager.currentTheme.nsAppearance
        window.contentViewController = controller
        return window
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        if panel?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
