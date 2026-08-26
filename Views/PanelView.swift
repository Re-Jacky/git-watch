import SwiftUI

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
