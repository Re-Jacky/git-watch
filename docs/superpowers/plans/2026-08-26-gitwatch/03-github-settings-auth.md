# Task 3: GitHubSettings + token resolution (TDD)

**Files:**
- Create: `Managers/GitHubSettings.swift`, `Managers/GitHubAuth.swift`
- Test: `git-watchTests/GitHubAuthTests.swift`, modify `git-watchTests/TestSupport.swift` (create it here)
- Modify: `Views/SettingsView.swift` (GitHub section)

**Interfaces:**
- Consumes: nothing new
- Produces (final, per master plan): `MergeMethod` enum (`label`, `graphqlName`), `GitHubSettings` (UserDefaults-persisted `personalAccessToken`, `mergeMethod` default `.merge`), `TokenResolution` (`patOverride(String)` / `ghCLI(String)` / `none`, computed `token: String?`), `GHCLIRunning` protocol, `GhCLI` production impl, `GitHubAuthProvider(settings:ghCLI:)` with `@Published resolution` and `resolve()`. Task 4's client consumes `provider.resolution.token`.

- [ ] **Step 1: Write the failing tests**

Create `git-watchTests/TestSupport.swift`:

```swift
import Foundation
@testable import git_watch

final class FakeGHCLI: GHCLIRunning {
    var stubbedToken: String?

    func authToken() -> String? {
        stubbedToken
    }
}

enum UserDefaultsFactory {
    static func make() -> UserDefaults {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
```

Create `git-watchTests/GitHubAuthTests.swift`:

```swift
import XCTest
@testable import git_watch

final class GitHubAuthTestsTests: XCTestCase {
    @MainActor
    func testMergeMethodDefaultsToMergeCommit() {
        let settings = GitHubSettings(userDefaults: UserDefaultsFactory.make())
        XCTAssertEqual(settings.mergeMethod, .merge)
    }

    @MainActor
    func testPersonalAccessTokenPersistsAndRoundTrips() {
        let defaults = UserDefaultsFactory.make()
        let settings = GitHubSettings(userDefaults: defaults)
        settings.personalAccessToken = "ghp_abc123"
        let reloaded = GitHubSettings(userDefaults: defaults)
        XCTAssertEqual(reloaded.personalAccessToken, "ghp_abc123")
    }

    @MainActor
    func testMergeMethodPersistsAndRawValuesMatchGraphQLNames() {
        let defaults = UserDefaultsFactory.make()
        let settings = GitHubSettings(userDefaults: defaults)
        settings.mergeMethod = .squash
        let reloaded = GitHubSettings(userDefaults: defaults)
        XCTAssertEqual(reloaded.mergeMethod, .squash)
        XCTAssertEqual(MergeMethod.merge.graphqlName, "MERGE")
        XCTAssertEqual(MergeMethod.squash.graphqlName, "SQUASH")
        XCTAssertEqual(MergeMethod.rebase.graphqlName, "REBASE")
    }

    func testTokenResolutionPrefersPATOverGHCLI() async {
        let fake = FakeGHCLI()
        fake.stubbedToken = "cli-token"
        let provider = GitHubAuthProvider(
            settings: GitHubSettings(
                personalAccessToken: "pat-token",
                ghCLI: fake,
                userDefaults: UserDefaultsFactory.make()
            )
        )
        await MainActor.run { provider.resolve() }
        let resolution = await MainActor.run { provider.resolution }
        XCTAssertEqual(resolution, .patOverride("pat-token"))
        XCTAssertEqual(resolution.token, "pat-token")
    }

    func testTokenResolutionFallsBackToGHCLI() async {
        let fake = FakeGHCLI()
        fake.stubbedToken = "cli-token"
        let provider = GitHubAuthProvider(
            settings: GitHubSettings(
                ghCLI: fake,
                userDefaults: UserDefaultsFactory.make()
            )
        )
        await MainActor.run { provider.resolve() }
        let resolution = await MainActor.run { provider.resolution }
        XCTAssertEqual(resolution, .ghCLI("cli-token"))
    }

    func testTokenResolutionNoneWhenBothMissing() async {
        let fake = FakeGHCLI()
        fake.stubbedToken = nil
        let provider = GitHubAuthProvider(
            settings: GitHubSettings(ghCLI: fake, userDefaults: UserDefaultsFactory.make())
        )
        await MainActor.run { provider.resolve() }
        let resolution = await MainActor.run { provider.resolution }
        XCTAssertNil(resolution.token)
        XCTAssertEqual(resolution, .none)
    }

    func testGhCLILocatesHomebrewBinaryOrReturnsNil() {
        let cli = GhCLI()
        let token = cli.authToken()
        XCTAssertTrue(token == nil || token?.isEmpty == false)
    }
}
```

Note: `GitHubSettings(personalAccessToken:ghCLI:userDefaults:)` is a designated-test convenience init — the production one is `init(userDefaults:)` only. Both are defined in Step 2.

- [ ] **Step 2: Run tests to verify they fail**

```bash
ruby scripts/add_files.rb git-watchTests/TestSupport.swift git-watchTests/GitHubAuthTests.swift
xcodebuild test -project git-watch.xcodeproj -scheme git-watch -destination 'platform=macOS' -only-testing:git-watchTests/GitHubAuthTestsTests 2>&1 | tail -5
```

Expected: **compile error** — `GitHubSettings` / `GitHubAuthProvider` do not exist.

- [ ] **Step 3: Implement `Managers/GitHubSettings.swift`**

```swift
import Combine
import Foundation

enum MergeMethod: String, CaseIterable, Identifiable {
    case merge
    case squash
    case rebase

    var id: String { rawValue }

    var label: String {
        switch self {
        case .merge: return "Merge Commit"
        case .squash: return "Squash"
        case .rebase: return "Rebase"
        }
    }

    var graphqlName: String {
        switch self {
        case .merge: return "MERGE"
        case .squash: return "SQUASH"
        case .rebase: return "REBASE"
        }
    }
}

final class GitHubSettings: ObservableObject {
    static let patKey = "github.personalAccessToken"
    static let mergeMethodKey = "github.mergeMethod"

    @Published var personalAccessToken: String {
        didSet { userDefaults.set(personalAccessToken, forKey: Self.patKey) }
    }

    @Published var mergeMethod: MergeMethod {
        didSet { userDefaults.set(mergeMethod.rawValue, forKey: Self.mergeMethodKey) }
    }

    private let userDefaults: UserDefaults
    private let ghCLI: GHCLIRunning

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.ghCLI = GhCLI()
        self.personalAccessToken = userDefaults.string(forKey: Self.patKey) ?? ""
        let raw = userDefaults.string(forKey: Self.mergeMethodKey)
        self.mergeMethod = raw.flatMap(MergeMethod.init(rawValue:)) ?? .merge
    }

    init(personalAccessToken: String, ghCLI: GHCLIRunning, userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        self.ghCLI = ghCLI
        self.personalAccessToken = personalAccessToken
        self.mergeMethod = .merge
    }
}
```

The stored-but-unused `ghCLI` on the production path exists so both inits share one type shape; the provider receives its own instance.

- [ ] **Step 4: Implement `Managers/GitHubAuth.swift`**

```swift
import Foundation

enum TokenResolution: Equatable {
    case patOverride(String)
    case ghCLI(String)
    case none

    var token: String? {
        switch self {
        case let .patOverride(token), let .ghCLI(token):
            return token.isEmpty ? nil : token
        case .none:
            return nil
        }
    }
}

protocol GHCLIRunning {
    func authToken() -> String?
}

final class GhCLI: GHCLIRunning {
    private static let candidates = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh"
    ]

    func authToken() -> String? {
        for candidate in Self.candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return runToken(executablePath: candidate)
        }
        return nil
    }

    private func runToken(executablePath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["auth", "token"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (token?.isEmpty == false) ? token : nil
        } catch {
            return nil
        }
    }
}

final class GitHubAuthProvider: ObservableObject {
    @Published private(set) var resolution: TokenResolution = .none

    private let settings: GitHubSettings
    private let ghCLI: GHCLIRunning

    init(settings: GitHubSettings, ghCLI: GHCLIRunning) {
        self.settings = settings
        self.ghCLI = ghCLI
    }

    convenience init(settings: GitHubSettings) {
        self.init(settings: settings, ghCLI: GhCLI())
    }

    func resolve() {
        if settings.personalAccessToken.isEmpty == false {
            resolution = .patOverride(settings.personalAccessToken)
            return
        }
        if let token = ghCLI.authToken() {
            resolution = .ghCLI(token)
            return
        }
        resolution = .none
    }
}
```

Adjust the test-target convenience-init usage if needed so tests compile against these exact signatures.

- [ ] **Step 5: Run tests to verify they pass**

```bash
ruby scripts/add_files.rb Managers/GitHubSettings.swift Managers/GitHubAuth.swift
xcodebuild test -project git-watch.xcodeproj -scheme git-watch -destination 'platform=macOS'
```

Expected: all `GitHubAuthTestsTests` cases pass plus prior smoke test.

- [ ] **Step 6: Add GitHub section to SettingsView**

In `Views/SettingsView.swift`: add `.github` to the sections enum between general and updates; add environment object `var githubSettings: GitHubSettings`; sidebar entry "GitHub" with system image `"person.crop.circle.badge.key"`. Section content:

```swift
    private var githubContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GitHub")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.appPrimaryText)

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
        }
    }

    private var authStatusText: String {
        switch authProvider?.resolution ?? .none {
        case .patOverride:
            return "Using the personal access token from Settings."
        case .ghCLI:
            return "Using the token from the gh CLI."
        case .none:
            return "Not signed in — add a token above or run gh auth login."
        }
    }
```

Hold the provider as `@StateObject private var authProvider: GitHubAuthProvider?` initialized from an injected factory: change `SettingsView` to accept `let authProvider: GitHubAuthProvider` passed through from `AppDelegate.makeSettingsWindow()` (create `GitHubAuthProvider(settings:)` there alongside `GitHubSettings()`, keep both as AppDelegate members, pass into SettingsView constructor). Update `makeSettingsWindow()` root view chain accordingly.

- [ ] **Step 7: Manual verification**

Build, run, open Settings → GitHub: type a PAT → status line flips to "Using the personal access token"; clear it → status shows gh CLI or not-signed-in depending on your machine; merge-method picker persists across relaunch. Full suite green:

```bash
xcodebuild test -project git-watch.xcodeproj -scheme git-watch -destination 'platform=macOS'
```

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Add GitHub settings and token resolution with PAT over gh CLI precedence"
```
