# Task 7: Wire UI to store — rows, sections, badge, actions

**Files:**
- Create: `Views/PullRequestRowView.swift`, `MenuBarBadgeView.swift`
- Modify: `Views/PanelView.swift`, `App/AppDelegate.swift`

**Interfaces:**
- Consumes: `PullRequestStore` published members (Task 6), `GitHubSettings` (Task 3)
- Produces: complete user-facing panel per spec Section 2 (variant A sections, pinned footer, badge); AppDelegate context-menu Refresh becomes live; refresh-on-open via `.gitwatchPanelDidOpen`; SettingsView gains nothing further (GitHub section landed in Task 3)

- [ ] **Step 1: Write `Views/PullRequestRowView.swift`**

```swift
import SwiftUI

struct PullRequestRowView: View {
    let summary: PullRequestSummary
    let action: RowAction
    let inFlight: Bool
    let errorMessage: String?
    let onAction: () -> Void

    enum RowAction {
        case none
        case approve
        case merge(MergeMethod)

        var title: String {
            switch self {
            case .none: return ""
            case .approve: return "Approve"
            case let .merge(method): return "Merge · \(method.label)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(repositoryLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.appSecondaryText)
                Text("· \(ageText)")
                    .font(.system(size: 11))
                    .foregroundColor(.appTertiaryText)
                Spacer(minLength: 0)
            }

            Text(summary.title)
                .font(.system(size: 12))
                .foregroundColor(.appPrimaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 8) {
                if summary.checks.isEmpty == false {
                    HStack(spacing: 3) {
                        ForEach(Array(summary.checks.enumerated()), id: \.offset) { _, dot in
                            Circle()
                                .fill(dotColor(dot.outcome))
                                .frame(width: 7, height: 7)
                        }
                    }
                    .help(checksHelpText)
                }

                if let chip = reviewChipText {
                    Text(chip.text)
                        .font(.system(size: 10))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1.5)
                        .background(chip.color.opacity(0.15))
                        .foregroundColor(chip.color)
                        .clipShape(Capsule())
                }

                Spacer(minLength: 0)

                if action != .none {
                    Button(action: onAction) {
                        Group {
                            if inFlight {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.6)
                            } else {
                                Text(action.title)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .frame(minWidth: actionTitleWidth)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(inFlight)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .background(Color.appFieldBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.open(summary.url)
        }
    }

    private var repositoryLabel: String {
        let parts = summary.repositoryNameWithOwner.split(separator: "/")
        let repo = parts.last.map(String.init) ?? summary.repositoryNameWithOwner
        return "\(repo)#\(summary.number)"
    }

    private var ageText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: summary.createdAt, relativeTo: Date())
    }

    private var actionTitleWidth: CGFloat? {
        switch action {
        case .none: return nil
        default: return 92
        }
    }

    private func dotColor(_ outcome: CheckOutcome) -> Color {
        switch outcome {
        case .success: return Color(hex: "3FB950")
        case .failure: return Color(hex: "F85149")
        case .pending: return Color(hex: "D29922")
        }
    }

    private var checksHelpText: String {
        let success = summary.checks.filter { $0.outcome == .success }.count
        let failure = summary.checks.filter { $0.outcome == .failure }.count
        let pending = summary.checks.filter { $0.outcome == .pending }.count
        return "\(success) passed · \(failure) failed · \(pending) pending"
    }

    private var reviewChipText: (text: String, color: Color)? {
        switch summary.reviewDecision {
        case .approved:
            return ("Approved", Color(hex: "3FB950"))
        case .changesRequested:
            return ("Changes requested", Color(hex: "F85149"))
        case .reviewRequired:
            return ("Pending review", Color(hex: "D29922"))
        case nil:
            return nil
        }
    }
}
```

Note: the two hex colors are GitHub status colors used identically in both appearances; they are intentional exceptions to the semantic-only rule and live here as named constants — move them to `Colors.swift` as `static var appStatusSuccess/appStatusFailure/appStatusPending` to keep the convention.

- [ ] **Step 2: Rewrite the tab content in `Views/PanelView.swift`**

Replace the placeholder list structs with store-driven versions:

```swift
struct PanelView: View {
    @AppStorage("selectedTab") private var selectedTab = 0
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var store: PullRequestStore

    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground, blendingMode: .withinWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("Mine \(tabCount(store.mine.count))").tag(0)
                    Text("Review & Merge \(tabCount(store.actionableCount))").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                Divider()
                    .background(Color.appDivider)

                ZStack {
                    MineListView(items: store.mine, errors: store.actionErrors, inFlight: store.inFlightActionIDs, store: store)
                        .opacity(selectedTab == 0 ? 1 : 0)
                        .allowsHitTesting(selectedTab == 0)

                    ReviewMergeListView(waitingMyReview: store.waitingMyReview, readyToMerge: store.readyToMerge,
                                        errors: store.actionErrors, inFlight: store.inFlightActionIDs, store: store)
                        .opacity(selectedTab == 1 ? 1 : 0)
                        .allowsHitTesting(selectedTab == 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                PanelFooterView(
                    lastRefreshedAt: store.lastRefreshedAt,
                    viewerLogin: store.viewerLogin,
                    isRefreshing: store.status == .refreshing,
                    onRefresh: { Task { await store.refresh(force: true) } }
                )
            }
        }
        .id(themeManager.currentTheme)
        .overlay(alignment: .top) { statusBanner }
        .onChange(of: selectedTab) { _ in
            NotificationCenter.default.post(name: .gitwatchPanelTabDidChange, object: selectedTab)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gitwatchPanelDidOpen)) { _ in
            Task { await store.refresh(force: false) }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let banner = bannerMessage {
            Text(banner)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.85))
                .clipShape(Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top))
        }
    }

    private var bannerMessage: String? {
        switch store.status {
        case .noToken:
            return "No GitHub token — add one in Settings or run gh auth login."
        case .tokenRejected:
            return "Token rejected — check Settings or run gh auth login."
        case .rateLimited:
            return "Rate limited by GitHub — retrying soon."
        case .offline:
            return "You appear to be offline."
        case let .failed(message):
            return message
        default:
            return nil
        }
    }

    private func tabCount(_ count: Int) -> String {
        count == 0 ? "" : " \(count)"
    }
}

private struct MineListView: View {
    let items: [PullRequestSummary]
    let errors: [String: String]
    let inFlight: Set<String>
    let store: PullRequestStore

    var body: some View {
        Group {
            if items.isEmpty && store.status != .refreshing {
                EmptyStateView(message: "No open PRs authored by you")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(items) { pr in
                            PullRequestRowView(
                                summary: pr,
                                action: .none,
                                inFlight: false,
                                errorMessage: errors[pr.id],
                                onAction: {}
                            )
                        }
                    }
                    .padding(10)
                }
            }
        }
    }
}

private struct ReviewMergeListView: View {
    let waitingMyReview: [PullRequestSummary]
    let readyToMerge: [PullRequestSummary]
    let errors: [String: String]
    let inFlight: Set<String>
    let store: PullRequestStore

    var body: some View {
        Group {
            if waitingMyReview.isEmpty && readyToMerge.isEmpty {
                EmptyStateView(message: store.status == .refreshing ? "Loading…" : "Nothing is waiting on you")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if waitingMyReview.isEmpty == false {
                            sectionHeader("Waiting for your review · \(waitingMyReview.count)")
                            ForEach(waitingMyReview) { pr in
                                PullRequestRowView(
                                    summary: pr,
                                    action: .approve,
                                    inFlight: inFlight.contains(pr.id),
                                    errorMessage: errors[pr.id],
                                    onAction: { Task { await store.approve(pr) } }
                                )
                            }
                        }
                        if readyToMerge.isEmpty == false {
                            sectionHeader("Ready for you to merge · \(readyToMerge.count)")
                            ForEach(readyToMerge) { pr in
                                PullRequestRowView(
                                    summary: pr,
                                    action: .merge(store.settingsMergeMethod),
                                    inFlight: inFlight.contains(pr.id),
                                    errorMessage: errors[pr.id],
                                    onAction: { Task { await store.merge(pr) } }
                                )
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundColor(.appSecondaryText)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}
```

Expose the merge method to views without a second environment dependency by adding to `PullRequestStore`:

```swift
    var settingsMergeMethod: MergeMethod {
        settings.mergeMethod
    }
```

Update `PanelFooterView` to accept `isRefreshing: Bool` and show a small `ProgressView` next to the timestamp while refreshing.

- [ ] **Step 3: Write `MenuBarBadgeView.swift`**

```swift
import AppKit
import SwiftUI

final class MenuBarBadgeController {
    private let statusItem: NSStatusItem
    private let hostingView: NSHostingView<MenuBarBadgeView>

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        self.hostingView = NSHostingView(rootView: MenuBarBadgeView(count: 0))
        guard let button = statusItem.button else { return }
        button.subviews.forEach { $0.removeFromSuperview() }
        hostingView.frame = button.bounds
        hostingView.autoresizingMask = [.width, .height]
        button.addSubview(hostingView)
    }

    func update(count: Int) {
        hostingView.rootView = MenuBarBadgeView(count: count)
        statusItem.length = hostingView.fittingSize.width
        if let button = statusItem.button {
            hostingView.frame = button.bounds
        }
    }
}

struct MenuBarBadgeView: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "git.pullrequest")
                .font(.system(size: 13, weight: .regular))
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
            }
        }
        .foregroundColor(.primary)
    }
}
```

In `AppDelegate`: replace the plain-image setup from Task 1 with badge ownership —

```swift
    private var githubSettings: GitHubSettings!
    private var authProvider: GitHubAuthProvider!
    private var pullRequestStore: PullRequestStore!
    private var badgeController: MenuBarBadgeController?
```

Initialize in `applicationDidFinishLaunching` before panel creation:

```swift
        githubSettings = GitHubSettings()
        authProvider = GitHubAuthProvider(settings: githubSettings)
        authProvider.resolve()
        let client = GitHubClient(provider: authProvider)
        pullRequestStore = PullRequestStore(client: client, settings: githubSettings)
```

Remove the `#if DEBUG` hook from Task 4 Step 7 if still present. Replace `setupStatusItem()`'s image assignment with:

```swift
        badgeController = MenuBarBadgeController(statusItem: statusItem)
        badgeController?.update(count: 0)
```

Keep click handling identical (`handleClick` targets stay). Observe counts:

```swift
        Publishers.CombineLatest(pullRequestStore.$waitingMyReview, pullRequestStore.$readyToMerge)
            .map { $0.count + $1.count }
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                self?.badgeController?.update(count: count)
            }
            .store(in: &cancellables)
```

Start automatic refresh after store creation:

```swift
        pullRequestStore.startAutomaticRefresh(interval: 300)
```

Wire the context menu Refresh item to a real action:

```swift
    @objc private func refreshNow() {
        openPanelIfPossible()
        Task { @MainActor [weak self] in
            await self?.pullRequestStore.refresh(force: true)
        }
    }
```

Set the item's `action: #selector(refreshNow)` / `target: self`. Also pass `.environmentObject(pullRequestStore)` into `PanelView()` inside `makePanel()`. Keep `openPanelIfPossible()` calling `openPanel()` only when not already visible.

- [ ] **Step 4: Register sources, build, test**

```bash
ruby scripts/add_files.rb Views/PullRequestRowView.swift MenuBarBadgeView.swift
xcodebuild -project git-watch.xcodeproj -scheme git-watch -configuration Debug build
xcodebuild test -project git-watch.xcodeproj -scheme git-watch -destination 'platform=macOS'
```

Expected: build succeeds; full suite stays green.

- [ ] **Step 5: Manual verification against spec Section 2**

Run the Debug app with your real gh login. Verify:
1. Badge shows total of review-requested + ready-to-merge PRs; hidden when zero
2. Mine tab lists your authored open PRs with CI dots/chips; clicking opens browser at the PR
3. Review & Merge shows two labeled sections; Approve appears only on waiting rows; Merge · <method> only on ready rows
4. Tapping Approve on a real PR approves it on GitHub (verify in browser), spinner shows during flight, row leaves the list after auto-refresh
5. Merge a disposable green PR end-to-end; wrong-method repos fall back gracefully (error text surfaces inline if rejected)
6. Footer timestamp updates; Refresh button works; banner appears when offline (disable Wi-Fi briefly)
7. No token state: temporarily clear PAT + rename gh binary path env → banner instructs setup; badge hides

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Wire panel UI to PullRequestStore with approve/merge actions and menu bar badge"
```
