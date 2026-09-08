import SwiftUI

struct PanelView: View {
    @AppStorage("selectedTab") private var selectedTab = 0
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var store: PullRequestStore
    @EnvironmentObject var githubSettings: GitHubSettings

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

                if githubSettings.autoModeEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color(hex: "58A6FF"))
                        Text(autoModeBannerText)
                            .font(.system(size: 11))
                            .foregroundColor(.appPrimaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "58A6FF").opacity(0.12))
                }

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

    private var autoModeBannerText: String {
        switch (githubSettings.autoApproveEnabled, githubSettings.autoMergeEnabled) {
        case (true, true):
            return "Auto mode is on — new review requests are approved automatically and green PRs you can merge are merged automatically."
        case (true, false):
            return "Auto mode is on — new review requests are approved automatically."
        case (false, true):
            return "Auto mode is on — green PRs you can merge are merged automatically."
        case (false, false):
            return "Auto mode is on, but no actions are selected in Settings — nothing will happen until you enable Approve or Merge."
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

    private func rowActionForMinePR(_ pr: PullRequestSummary) -> PullRequestRowView.RowAction {
        if store.canOfferMergeForMine(for: pr) {
            return .merge(store.settingsMergeMethod)
        }
        return .none
    }

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
                                action: rowActionForMinePR(pr),
                                inFlight: inFlight.contains(pr.id),
                                errorMessage: errors[pr.id],
                                onAction: { Task { await store.merge(pr) } },
                                onDismiss: { store.dismiss(pr) }
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
    @EnvironmentObject var githubSettings: GitHubSettings
    @AppStorage("autoApprovedHistoryCollapsed") private var isHistoryCollapsed = false

    var body: some View {
        Group {
            if waitingMyReview.isEmpty && readyToMerge.isEmpty && (githubSettings.autoModeEnabled == false || store.autoApprovedHistory.isEmpty) {
                EmptyStateView(message: store.status == .refreshing ? "Loading…" : "Nothing is waiting on you")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if waitingMyReview.isEmpty == false {
                            sectionHeader("Waiting for your review · \(waitingMyReview.count)")
                            ForEach(waitingMyReview) { pr in
                                PullRequestRowView(
                                    summary: pr,
                                    action: rowActionForWaitingPR(pr),
                                    inFlight: inFlight.contains(pr.id),
                                    errorMessage: errors[pr.id],
                                    onAction: {
                                        Task {
                                            if store.canOfferMergeInPlace(for: pr) {
                                                await store.merge(pr)
                                            } else {
                                                await store.approve(pr)
                                            }
                                        }
                                    },
                                    onDismiss: { store.dismiss(pr) },
                                    showsAuthor: true,
                                    locallyApproved: store.locallyApprovedIDs.contains(pr.id)
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
                                    onAction: { Task { await store.merge(pr) } },
                                    onDismiss: { store.dismiss(pr) },
                                    showsAuthor: true
                                )
                            }
                        }
                        if githubSettings.autoModeEnabled && store.autoApprovedHistory.isEmpty == false {
                            historySection
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    isHistoryCollapsed.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isHistoryCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.appSecondaryText)
                        Text("Auto-approved · \(store.autoApprovedHistory.count)".uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .foregroundColor(.appSecondaryText)
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                Button("Clear") {
                    store.clearAutoApprovedHistory()
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(.appSecondaryText)
                .help("Clear auto-approved history")
            }
            .padding(.top, 6)
            .padding(.bottom, 2)
            if isHistoryCollapsed == false {
                ForEach(store.autoApprovedHistory) { entry in
                    let canMerge = store.canOfferMergeForHistory(entry)
                    PullRequestRowView(
                        summary: store.historySummary(for: entry),
                        action: canMerge ? .merge(store.settingsMergeMethod) : .none,
                        inFlight: inFlight.contains(entry.id),
                        errorMessage: errors[entry.id],
                        onAction: { Task { await store.mergeHistoryEntry(entry) } },
                        onDismiss: nil,
                        showsAuthor: true,
                        locallyApproved: true,
                        isMerged: store.mergedHistoryIDs.contains(entry.id)
                    )
                    .opacity(0.55)
                }
            }
        }
    }

    private func rowActionForWaitingPR(_ pr: PullRequestSummary) -> PullRequestRowView.RowAction {
        if store.canOfferMergeInPlace(for: pr) {
            return .merge(store.settingsMergeMethod)
        }
        if store.shouldOfferApprove(for: pr) {
            return .approve
        }
        return .none
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
    let isRefreshing: Bool
    let onRefresh: () -> Void

    @EnvironmentObject private var updateManager: UpdateManager

    var body: some View {
        HStack(spacing: 8) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }

            Text(timestampText)
                .font(.system(size: 11))
                .foregroundColor(.appSecondaryText)
                .monospacedDigit()

            Spacer(minLength: 8)

            PanelVersionHeaderView(versionInfo: AppVersionInfo())

            Spacer(minLength: 8)

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

struct PanelVersionHeaderView: View {
    let versionInfo: AppVersionInfo

    @EnvironmentObject var updateManager: UpdateManager

    var body: some View {
        HStack(spacing: 6) {
            if case .downloading = updateManager.state {
            } else {
                Text(versionInfo.headerDisplayVersion)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.appSecondaryText)
                    .lineLimit(1)
                    .monospacedDigit()
            }

            updateStatusView
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("GitWatch \(versionInfo.headerDisplayVersion), \(accessibilityStatus)")
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateManager.state {
        case .checking:
            HStack(spacing: 3) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
                Text("Checking")
                    .font(.system(size: 10))
            }
            .foregroundColor(.appSecondaryText)
        case .downloading:
            HStack(spacing: 3) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
                Text("Downloading")
                    .font(.system(size: 10))
            }
            .foregroundColor(.appSecondaryText)
        case let .updateAvailable(release):
            Button("Update") {
                Task { @MainActor in
                    do {
                        try await updateManager.downloadAvailableUpdate(release)
                    } catch {
                        updateManager.present(error: error)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.accentColor)
            .help("Update to GitWatch \(release.version)")
        case let .readyToInstall(release, _, _):
            Button("Install") {
                Task { @MainActor in
                    do {
                        try await updateManager.beginInstall()
                    } catch {
                        updateManager.present(error: error)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.accentColor)
            .help("Install GitWatch \(release.version)")
        case let .failed(message):
            Button("Retry") {
                Task { @MainActor in
                    await updateManager.checkForUpdates(userInitiated: true)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.red)
            .help(message)
        default:
            EmptyView()
        }
    }

    private var accessibilityStatus: String {
        switch updateManager.state {
        case .checking:
            return "checking for updates"
        case .downloading:
            return "downloading update"
        case let .updateAvailable(release):
            return "update \(release.version) available"
        case let .readyToInstall(release, _, _):
            return "update \(release.version) ready to install"
        case .failed:
            return "update check failed"
        case .upToDate:
            return "up to date"
        default:
            return "update status idle"
        }
    }
}
