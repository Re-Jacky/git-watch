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
