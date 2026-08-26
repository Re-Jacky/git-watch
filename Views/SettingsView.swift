import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var updateManager: UpdateManager
    @EnvironmentObject var launchAtLoginSettings: LaunchAtLoginSettings
    @EnvironmentObject var githubSettings: GitHubSettings
    @EnvironmentObject var pullRequestStore: PullRequestStore
    @ObservedObject var authProvider: GitHubAuthProvider
    @State private var selectedSection: Section = .general
    private let versionInfo = AppVersionInfo()

    private enum Section: Hashable {
        case general
        case github
        case updates
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Settings")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.appSecondaryText)

                sidebarButton(title: "General", systemImage: "gearshape", section: .general)
                sidebarButton(title: "GitHub", systemImage: "key", section: .github)
                sidebarButton(title: "Updates", systemImage: "arrow.triangle.2.circlepath", section: .updates)

                Spacer()
            }
            .padding(16)
            .frame(width: 188, alignment: .topLeading)
            .background(Color.appSidebarBackground)

            Divider()

            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        Group {
                            switch selectedSection {
                            case .general:
                                generalContent
                            case .github:
                                githubContent
                            case .updates:
                                updatesContent
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                VStack(spacing: 10) {
                    Divider()

                    VStack(spacing: 4) {
                        Text(versionInfo.appDisplayVersion)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.appPrimaryText)
                            .multilineTextAlignment(.center)

                        Text(versionInfo.systemDisplayVersion)
                            .font(.system(size: 12))
                            .foregroundColor(.appSecondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 520, minHeight: 280)
        .id(themeManager.currentTheme)
        .onAppear { authProvider.resolve() }
        .onChange(of: githubSettings.personalAccessToken) { _, _ in
            authProvider.resolve()
        }
    }

    private var githubContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GitHub")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            VStack(alignment: .leading, spacing: 6) {
                Text("Auto Mode")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.appPrimaryText)

                Toggle("Enable Auto Mode", isOn: $githubSettings.autoModeEnabled)
                    .toggleStyle(.switch)

                Text("While enabled, every PR waiting for your review is approved automatically — including re-approval after an author pushes changes and your stale review is dismissed — and any green PR you have permission to merge is merged immediately using your default merge method. The menu bar icon turns blue while Auto mode is active.")
                    .font(.system(size: 13))
                    .foregroundColor(.appSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Personal Access Token")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.appPrimaryText)

                Text("Optional override. Leave empty to use your gh CLI login (gh auth token). The token needs repo read access and pull request write access.")
                    .font(.system(size: 13))
                    .foregroundColor(.appSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                SecureField("ghp_…", text: $githubSettings.personalAccessToken)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)

                Text(authStatusText)
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Default Merge Method")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.appPrimaryText)

                Text("Used by the Merge button when the repository allows it. Falls back to whatever method the repository permits.")
                    .font(.system(size: 13))
                    .foregroundColor(.appSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Method", selection: $githubSettings.mergeMethod) {
                    ForEach(MergeMethod.allCases) { method in
                        Text(method.label).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .labelsHidden()
            }

            if pullRequestStore.dismissedIDs.isEmpty == false {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Dismissed Pull Requests")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.appPrimaryText)

                    Text("\(pullRequestStore.dismissedIDs.count) PR(s) are hidden because you dismissed them. Restoring brings them back on the next refresh.")
                        .font(.system(size: 13))
                        .foregroundColor(.appSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Show Dismissed PRs (\(pullRequestStore.dismissedIDs.count))") {
                        pullRequestStore.restoreAllDismissed()
                    }
                }
            }
        }
    }

    private var authStatusText: String {
        switch authProvider.resolution {
        case .patOverride:
            return "Using the personal access token from Settings."
        case .ghCLI:
            return "Using the token from the gh CLI."
        case .none:
            return "Not signed in — add a token above or run gh auth login."
        }
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("General")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                    .toggleStyle(.switch)

                Text("Start GitWatch automatically when you log in to your Mac.")
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage = launchAtLoginSettings.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            }

            Divider()

            Text("Theme")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            Text("Choose whether GitWatch follows the system appearance or always uses a specific theme.")
                .font(.system(size: 13))
                .foregroundColor(.appSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Theme", selection: $themeManager.currentTheme) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Text(theme.label).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
        }
    }

    private var updatesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Updates")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.appPrimaryText)

            Text(versionInfo.appDisplayVersion)
                .font(.system(size: 13))
                .foregroundColor(.appSecondaryText)

            switch updateManager.state {
            case .checking:
                ProgressView("Checking for updates...")
            case .downloading:
                ProgressView("Downloading update...")
            case let .updateAvailable(release):
                Button("Download GitWatch \(release.version)") {
                    Task { @MainActor in
                        do {
                            try await updateManager.downloadAvailableUpdate(release)
                        } catch {
                            updateManager.present(error: error)
                        }
                    }
                }
            case let .readyToInstall(release, _, _):
                Button("Install GitWatch \(release.version)") {
                    Task { @MainActor in
                        do {
                            try await updateManager.beginInstall()
                        } catch {
                            updateManager.present(error: error)
                        }
                    }
                }
            case let .failed(message):
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            default:
                Button("Check for Updates...") {
                    Task { @MainActor in
                        await updateManager.checkForUpdates(userInitiated: true)
                    }
                }
            }
        }
    }

    private func sidebarButton(title: String, systemImage: String, section: Section) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .frame(width: 14)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .foregroundColor(.appPrimaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedSection == section ? Color.accentColor.opacity(0.14) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: {
                launchAtLoginSettings.isEnabled
            },
            set: {
                launchAtLoginSettings.setEnabled($0)
            }
        )
    }
}
