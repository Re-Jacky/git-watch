# Task 2: Panel shell — InputPanel, tabs, pinned footer

**Files:**
- Modify: `App/AppDelegate.swift`
- Create: `Views/PanelView.swift`

**Interfaces (produces):**
- `AppDelegate` owns a pre-built `InputPanel` (custom `NSPanel` subclass) with Pulse's full lifecycle: pre-build at launch, position under status item, activation-policy juggling, outside-click dismissal, theme application
- `PanelView`: two-tab root (`Mine` / `Review & Merge`) with `.opacity` + `.allowsHitTesting` tab switching (Pulse convention), pinned footer, per-tab empty states
- `Notification.Name.gitwatchPanelDidOpen`, `.gitwatchPanelTabDidChange` — later tasks hook refresh-on-open and layout changes
- Environment objects injected into panel: whatever exists so far (`themeManager`; store arrives in Task 6)

- [ ] **Step 1: Add panel metrics + notifications to `AppDelegate.swift`**

Add above the AppDelegate class:

```swift
enum PanelMetrics {
    static let selectedTabDefaultsKey = "selectedTab"
    static let defaultWidth: CGFloat = 420
    static let defaultHeight: CGFloat = 520
    static let minWidth: CGFloat = 340
    static let minHeight: CGFloat = 460
}

extension Notification.Name {
    static let gitwatchPanelDidOpen = Notification.Name("gitwatchPanelDidOpen")
    static let gitwatchPanelTabDidChange = Notification.Name("gitwatchPanelTabDidChange")
}

final class InputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func zoom(_ sender: Any?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let current = frame
        let target = NSRect(
            x: current.origin.x,
            y: screen.visibleFrame.maxY - current.height * 2,
            width: current.width * 1.5,
            height: current.height * 2
        )
        let isZoomed = abs(frame.width - target.width) < 2 && abs(frame.height - target.height) < 2
        if isZoomed {
            setFrame(
                NSRect(
                    x: current.origin.x,
                    y: screen.visibleFrame.maxY - PanelMetrics.defaultHeight,
                    width: PanelMetrics.defaultWidth,
                    height: PanelMetrics.defaultHeight
                ),
                display: true,
                animate: true
            )
        } else {
            setFrame(target, display: true, animate: true)
        }
    }
}
```

- [ ] **Step 2: Replace panel lifecycle in `AppDelegate`**

Replace the empty `togglePanel()` / `openPanelIfPossible()` stubs and add these members (modeled on Pulse `pulse/App/AppDelegate.swift` lines 39–72, 230–283):

```swift
    private var eventMonitor: Any?

    @objc private func togglePanel() {
        if let panel, panel.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        let p: InputPanel
        if let existing = panel {
            p = existing
        } else {
            p = makePanel()
            panel = p
        }

        if let button = statusItem.button,
           let screen = button.window?.screen ?? NSScreen.main {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = button.window?.convertToScreen(buttonRect) ?? .zero
            let x = screenRect.midX - p.frame.width / 2
            let y = screenRect.minY - p.frame.height - 4
            let clamped = max(screen.visibleFrame.minX, min(x, screen.visibleFrame.maxX - p.frame.width))
            p.setFrameOrigin(NSPoint(x: clamped, y: y))
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            if self?.settingsWindow?.isVisible != true {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        NotificationCenter.default.post(name: .gitwatchPanelDidOpen, object: nil)

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func closePanel() {
        panel?.orderOut(nil)
        if settingsWindow?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }

    private func makePanel() -> InputPanel {
        let p = InputPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.defaultWidth, height: PanelMetrics.defaultHeight),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.isMovableByWindowBackground = false
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.minSize = NSSize(width: PanelMetrics.minWidth, height: PanelMetrics.minHeight)
        p.appearance = themeManager.currentTheme.nsAppearance
        p.backgroundColor = .clear
        p.isOpaque = false

        let vc = NSHostingController(
            rootView: PanelView()
                .environmentObject(themeManager)
        )
        vc.view.appearance = themeManager.currentTheme.nsAppearance
        p.contentViewController = vc

        if let contentView = p.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 12
            contentView.layer?.masksToBounds = true
        }
        return p
    }
```

Also in `applicationDidFinishLaunching`, add `panel = makePanel()` after `setupStatusItem()` (Pulse pre-builds for instant first open), and update `applyCurrentTheme()` to include:

```swift
        panel?.appearance = themeManager.currentTheme.nsAppearance
        panel?.contentViewController?.view.appearance = themeManager.currentTheme.nsAppearance
        panel?.contentView?.needsDisplay = true
```

Update the context menu's Open item title logic to match Pulse (`"Close"` when visible):

```swift
        let openTitle = (panel?.isVisible == true) ? "Close" : "Open"
        let openItem = NSMenuItem(title: openTitle, action: #selector(togglePanel), keyEquivalent: "")
```

And wire the Refresh item target now that a refresh path will exist (leave `action: nil` until Task 7; it stays disabled).

Finally update `windowWillClose` policy check to also consider the panel (shown above).

- [ ] **Step 3: Write `Views/PanelView.swift`**

```swift
import SwiftUI

struct PanelView: View {
    @AppStorage("selectedTab") private var selectedTab = 0
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground, blendingMode: .withinWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("Mine").tag(0)
                    Text("Review & Merge").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                Divider()
                    .background(Color.appDivider)

                ZStack {
                    MineListView(items: [])
                        .opacity(selectedTab == 0 ? 1 : 0)
                        .allowsHitTesting(selectedTab == 0)

                    ReviewMergeListView(waitingMyReview: [], readyToMerge: [])
                        .opacity(selectedTab == 1 ? 1 : 0)
                        .allowsHitTesting(selectedTab == 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                PanelFooterView(lastRefreshedAt: nil, viewerLogin: nil, onRefresh: {})
            }
        }
        .id(themeManager.currentTheme)
        .onChange(of: selectedTab) { _ in
            NotificationCenter.default.post(name: .gitwatchPanelTabDidChange, object: selectedTab)
        }
    }
}

private struct MineListView: View {
    let items: [String]

    var body: some View {
        if items.isEmpty {
            EmptyStateView(message: "No open PRs authored by you")
        } else {
            List(items, id: \.self) { Text($0) }
        }
    }
}

private struct ReviewMergeListView: View {
    let waitingMyReview: [String]
    let readyToMerge: [String]

    var body: some View {
        if waitingMyReview.isEmpty && readyToMerge.isEmpty {
            EmptyStateView(message: "Nothing is waiting on you")
        } else {
            List {}
        }
    }
}

struct EmptyStateView: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 28))
                .foregroundColor(.appSecondaryText)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.appSecondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PanelFooterView: View {
    let lastRefreshedAt: Date?
    let viewerLogin: String?
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(timestampText)
                .font(.system(size: 11))
                .foregroundColor(.appSecondaryText)
                .monospacedDigit()

            Spacer(minLength: 0)

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Refresh now")

            if let viewerLogin {
                Text("@\(viewerLogin)")
                    .font(.system(size: 11))
                    .foregroundColor(.appSecondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.appSidebarBackground)
    }

    private var timestampText: String {
        guard let lastRefreshedAt else { return "Not refreshed yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Updated \(formatter.localizedString(for: lastRefreshedAt, relativeTo: Date()))"
    }
}
```

Note the footer sits as the last `VStack` child with no `Spacer` before it — combined with the middle content's `maxHeight: .infinity`, the footer is structurally pinned to the bottom edge at any window size (spec requirement). The list area scrolls once real rows land in Task 7.

- [ ] **Step 4: Register sources and build**

```bash
ruby scripts/add_files.rb Views/PanelView.swift
xcodebuild -project git-watch.xcodeproj -scheme git-watch -configuration Debug build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Manual verification checklist**

Run the Debug app. Verify each item:
1. Left-click icon → frosted-glass rounded panel appears under the icon, no Dock icon appears
2. Two segmented tabs render; switching persists across panel close/reopen and app relaunch (`@AppStorage`)
3. Both tabs show their empty-state message ("No open PRs authored by you" / "Nothing is waiting on you")
4. Footer shows "Not refreshed yet" pinned flush to the bottom edge
5. Resize to minimum — tabs, one empty state, and footer all remain visible; footer never moves off-screen
6. Click anywhere outside → panel dismisses
7. Green zoom button doubles the size; clicking again restores 420×520
8. Theme switch in Settings applies to the open panel immediately (System/Dark/Light)
9. Right-click menu title flips Open/Close depending on visibility
10. Quit works with panel open or closed

Fix anything that fails before committing.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add InputPanel shell with two tabs, pinned footer, and empty states"
```
