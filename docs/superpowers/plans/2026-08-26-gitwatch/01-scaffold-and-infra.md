# Task 1: Project scaffold + ported Pulse infrastructure

**Files:**
- Create: `scripts/create_project.rb`, `scripts/add_files.rb`, `App/main.swift`, `App/AppDelegate.swift`, `Views/SettingsView.swift`, `Info.plist`
- Copy from Pulse (`P=/Users/zyao/Desktop/pulse`): `Managers/{ThemeManager,LaunchAtLoginSettings,AppVersionInfo,UpdateManager,UpdateModels,UpdateInstallPlanner,UpdateGitHubClient}.swift`, `Views/Colors.swift`, `gitwatchUpdater/{main.swift,UpdaterAppDelegate.swift,UpdaterInstaller.swift,UpdaterWindowController.swift}`

**Interfaces (produces):**
- 3-target project building clean: `git-watch` (app), `GitWatchUpdater` (helper embedded at `Contents/Helpers/GitWatchUpdater.app`), `git-watchTests`
- `ThemeManager`, `LaunchAtLoginSettings`, `UpdateManager(client:)`, `LiveUpdateClient(repoOwner:repoName:)`, `Color.app*` semantic palette, `VisualEffectView`
- Task 2 will extend `AppDelegate`; Tasks 3+ add environment objects to its two window factories

- [ ] **Step 1: Verify dev tooling**

```bash
ruby -e "require 'xcodeproj'" 2>/dev/null || gem install xcodeproj --user-install
xcodebuild -version
```

Expected: xcodeproj gem loads; Xcode 15+ present. On first launch run `sudo xcodebuild -runFirstLaunch` if prompted.

- [ ] **Step 2: Copy verbatim files from Pulse**

```bash
P=/Users/zyao/Desktop/pulse
mkdir -p App Managers Views scripts gitwatchUpdater .github/workflows
cp $P/pulse/App/main.swift App/main.swift
cp $P/pulse/Views/Colors.swift Views/Colors.swift
cp $P/pulse/Managers/ThemeManager.swift Managers/ThemeManager.swift
cp $P/pulse/Managers/LaunchAtLoginSettings.swift Managers/LaunchAtLoginSettings.swift
cp $P/pulse/Managers/AppVersionInfo.swift Managers/AppVersionInfo.swift
cp $P/pulse/Managers/UpdateModels.swift Managers/UpdateModels.swift
cp $P/pulse/Managers/UpdateInstallPlanner.swift Managers/UpdateInstallPlanner.swift
cp $P/pulseUpdater/main.swift gitwatchUpdater/main.swift
cp $P/pulseUpdater/UpdaterInstaller.swift gitwatchUpdater/UpdaterInstaller.swift
```

In copied `LaunchAtLoginSettings.swift`, replace the error-message string `"Pulse could not be updated…"` with `"GitWatch could not be updated…"`. No other edits.

- [ ] **Step 3: Copy and rename update-pipeline files**

Copy then apply these exact substitutions:

| Source → Destination | Substitutions |
|---|---|
| `pulse/Managers/UpdateManager.swift` → `Managers/UpdateManager.swift` | `Contents/Helpers/PulseUpdater.app` → `Contents/Helpers/GitWatchUpdater.app`; `"Pulse-\(release.version)-updater.zip"` → `"GitWatch-\(release.version)-updater.zip"`; both `Pulse.app` occurrences in `acceptVerifiedStagedUpdate` guard/message → `GitWatch.app` |
| `pulse/Managers/UpdateGitHubClient.swift` → `Managers/UpdateGitHubClient.swift` | User-Agent `Pulse/…` → `GitWatch/…`; `expectedAssetName = "Pulse-\(version)-updater.zip"` → `"GitWatch-\(version)-updater.zip"` |
| `pulseUpdater/UpdaterAppDelegate.swift` → `gitwatchUpdater/UpdaterAppDelegate.swift` | user-visible string `Pulse` → `GitWatch` |
| `pulseUpdater/UpdaterWindowController.swift` → `gitwatchUpdater/UpdaterWindowController.swift` | user-visible string `Pulse` → `GitWatch` |

Verify no stale references remain:

```bash
grep -rn "Pulse" --include="*.swift" . && echo "STALE REFS FOUND" || echo "clean"
```

Expected: `clean`.

- [ ] **Step 4: Create `Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>$(MACOSX_DEPLOYMENT_TARGET)</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
```

- [ ] **Step 5: Write `App/AppDelegate.swift`**

```swift
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
```

Also append this shared helper to the end of `Views/Colors.swift`:

```swift
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
```

- [ ] **Step 6: Write `Views/SettingsView.swift`**

Follow Pulse's `pulse/Views/SettingsView.swift` structure exactly: sidebar layout (188pt width, `sidebarButton(title:systemImage:section:)` helper verbatim), footer version block (`versionInfo.appDisplayVersion` / `systemDisplayVersion`), `.frame(minWidth: 520, minHeight: 280)`, `.id(themeManager.currentTheme)`. Sections enum has exactly two cases: `.general`, `.updates`. Environment objects: `themeManager`, `updateManager`, `launchAtLoginSettings`.

- `generalContent`: copy Pulse's General section but omit everything from `Divider()` + "Keep Awake" onward. Keep: Launch at Login toggle + helper text + error text (rename string `Start Pulse automatically…` → `Start GitWatch automatically when you log in to your Mac.`), Theme header/description/picker.
- `updatesContent`: copy Pulse's `updateContent` verbatim with `Pulse` → `GitWatch` in button titles.

- [ ] **Step 7: Write `scripts/create_project.rb`**

```ruby
require 'xcodeproj'

project_path = 'git-watch.xcodeproj'
FileUtils.rm_rf(project_path)

project = Xcodeproj::Project.new(project_path)
main_group = project.main_group.new_group('git-watch', '.')

%w[App Managers Views].each do |dir|
  g = main_group.new_group(dir, dir)
  Dir.glob("#{dir}/**/*.swift").sort.each do |f|
    g.new_reference(File.basename(f))
  end
end

updater_group = main_group.new_group('gitwatchUpdater', 'gitwatchUpdater')
Dir.glob('gitwatchUpdater/*.swift').sort.each do |f|
  updater_group.new_reference(File.basename(f))
end

app = project.new_target(:application, 'git-watch', :osx, '14.0')
app.product_name = 'GitWatch'
main_group.groups.find { |g| g.name == 'App' }.files.each do |ref|
  app.add_file_references([ref])
end
main_group.groups.find { |g| g.name == 'Managers' }.files.each do |ref|
  app.add_file_references([ref])
end
main_group.groups.find { |g| g.name == 'Views' }.files.each do |ref|
  app.add_file_references([ref])
end
app.build_configurations.each do |cfg|
  cfg.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.rejacky.gitwatch',
    'MARKETING_VERSION' => '0.1.0',
    'CURRENT_PROJECT_VERSION' => '1',
    'SWIFT_VERSION' => '5.9',
    'INFOPLIST_FILE' => 'Info.plist',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'CODE_SIGN_IDENTITY' => '-',
    'CODE_SIGN_STYLE' => 'Automatic',
    'MACOSX_DEPLOYMENT_TARGET' => '14.0',
    'ENABLE_HARDENED_RUNTIME' => 'YES',
    'PRODUCT_NAME' => 'GitWatch'
  )
end

helper = project.new_target(:application, 'GitWatchUpdater', :osx, '14.0')
helper.product_name = 'GitWatchUpdater'
helper.build_configurations.each do |cfg|
  cfg.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.rejacky.GitWatchUpdater',
    'MARKETING_VERSION' => '0.1.0',
    'CURRENT_PROJECT_VERSION' => '1',
    'SWIFT_VERSION' => '5.9',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'INFOPLIST_KEY_LSUIElement' => 'YES',
    'CODE_SIGN_IDENTITY' => '-',
    'MACOSX_DEPLOYMENT_TARGET' => '14.0'
  )
end
updater_group.files.each do |ref|
  helper.add_file_references([ref])
end

embed = app.new_copy_files_build_phase('Embed Helper')
embed.dst_subfolder_spec = '10'
embed.dst_path = '../Helpers'
helper_product_ref = project.products_group.children.find { |p| p.path == 'GitWatchUpdater.app' }
raise 'GitWatchUpdater.app product reference missing' unless helper_product_ref
embed.add_file_reference(helper_product_ref)

tests = project.new_target(:unit_test_bundle, 'git-watchTests', :osx, '14.0')
tests.build_configurations.each do |cfg|
  cfg.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.rejacky.gitwatchTests',
    'SWIFT_VERSION' => '5.9',
    'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/GitWatch.app/Contents/MacOS/GitWatch',
    'BUNDLE_LOADER' => '$(TEST_HOST)',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'MACOSX_DEPLOYMENT_TARGET' => '14.0'
  )
end
tests_group = main_group.new_group('git-watchTests', 'git-watchTests')
tests.add_dependency(app)

project.save
puts "Created #{project_path}"
```

- [ ] **Step 8: Write `scripts/add_files.rb`**

```ruby
#!/usr/bin/env ruby
# Usage: ruby scripts/add_files.rb path/File1.swift [path/File2.swift ...]
require 'xcodeproj'

project_path = 'git-watch.xcodeproj'
abort "#{project_path} not found" unless File.exist?(project_path)
project = Xcodeproj::Project.open(project_path)

app_target = project.targets.find { |t| t.name == 'git-watch' }
test_target = project.targets.find { |t| t.name == 'git-watchTests' }
main_group = project.main_group.children.find { |g| g.display_name == 'git-watch' }

ARGV.each do |file_path|
  abort "#{file_path} does not exist" unless File.exist?(file_path)
  dir = File.dirname(file_path)
  group = dir == '.' ? main_group : main_group.find_subpath(dir, true)
  next if group.files.any? { |f| f.path == File.basename(file_path) }
  ref = group.new_reference(File.basename(file_path))
  target = dir == 'git-watchTests' ? test_target : app_target
  target.source_build_phase.add_file_reference(ref)
end

project.save
puts "Registered: #{ARGV.join(', ')}"
```

Create an empty placeholder so the test target compiles before Task 3 adds real tests:

```bash
mkdir -p git-watchTests
printf 'import XCTest\n\nfinal class SmokeTests: XCTestCase {\n    func testTrue() {\n        XCTAssertTrue(true)\n    }\n}\n' > git-watchTests/SmokeTests.swift
```

- [ ] **Step 9: Generate project and build all targets**

```bash
ruby scripts/create_project.rb
xcodebuild -project git-watch.xcodeproj -scheme git-watch -configuration Debug build
xcodebuild -project git-watch.xcodeproj -scheme GitWatchUpdater -configuration Debug build
xcodebuild test -project git-watch.xcodeproj -scheme git-watch -destination 'platform=macOS'
```

Expected: `BUILD SUCCEEDED` twice and smoke test passes. If a scheme is missing run `xcodebuild -list -project git-watch.xcodeproj` first; schemes are auto-generated per target.

- [ ] **Step 10: Manual smoke test**

```bash
open "$(find ~/Library/Developer/Xcode/DerivedData -name 'GitWatch.app' -path '*/Debug/*' | head -1)"
```

Verify: pull-request icon in menu bar; right-click menu Open / Refresh(disabled) / Settings… / Quit GitWatch; Settings opens showing General (login toggle works, error path shows red hint on failure, theme switcher applies immediately and persists across relaunch) and Updates sections (Check for Updates runs against Re-Jacky/git-watch and reports not-found/failure gracefully). Quit works.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "Scaffold GitWatch project with ported Pulse infrastructure"
```
