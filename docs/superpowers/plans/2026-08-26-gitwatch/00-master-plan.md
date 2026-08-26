# GitWatch Implementation Plan — Master

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Execute task files **in numeric order**; each task ends with a commit.

**Goal:** Build GitWatch, a macOS menu bar app that lists all your open GitHub PRs (authored / awaiting-your-review / ready-for-you-to-merge) with one-click Approve and Merge actions.

**Architecture:** AppKit accessory app (`LSUIElement`) with SwiftUI content, mirroring `/Users/zyao/Desktop/pulse` infrastructure file-for-file: custom borderless `InputPanel`, `ThemeManager` (System/Dark/Light), `LaunchAtLoginSettings` (SMAppService), `UpdateManager` + bundled helper app + DMG packaging + CI release workflow. New data layer: one combined GitHub GraphQL query per refresh feeding an observable `PullRequestStore`; GraphQL mutations for approve/merge.

**Tech Stack:** Swift 5.9+, macOS 14+, AppKit + SwiftUI, URLSession only (zero external runtime dependencies), XCTest, Ruby `xcodeproj` gem for project-file maintenance (dev-time only, Pulse convention).

**Spec:** `docs/superpowers/specs/2026-08-26-gitwatch-design.md` — read before starting any task. This plan argues from that spec.

**Pulse source root:** `/Users/zyao/Desktop/pulse`

## Global Constraints (apply to every task)

- macOS deployment target **14.0**; Swift **5.9**
- Zero external runtime dependencies — Apple frameworks only
- No Keychain anywhere; all settings persist in `UserDefaults.standard`
- Bundle IDs: app `com.rejacky.gitwatch`, helper `com.rejacky.GitWatchUpdater`, tests `com.rejacky.gitwatchTests`
- Update/release repo slug: `Re-Jacky/git-watch`
- `LSUIElement = true` on app target; helper is also a background (`LSUIElement`) app
- Versioning via `MARKETING_VERSION` in `git-watch.xcodeproj/project.pbxproj`
- Semantic colors from `Views/Colors.swift` only — no hard-coded light/dark values in views
- Merge-method default `.merge` (GitHub's default); squash/rebase selectable in Settings
- Refresh cadence fixed at **300 s** (not user-configurable in v1)
- Only open PRs are ever displayed; merged/closed dropped at classification time
- Badge counts review + merge actionable totals only
- Panel: default 420×520, min 340×460; footer structurally pinned
- Two tabs: **Mine** / **Review & Merge** (grouped sections, variant A)
- Do not add code comments; keep one responsibility per file
- Register new Swift sources with `ruby scripts/add_files.rb <paths…>` (created in Task 1)
- Build: `xcodebuild -project git-watch.xcodeproj -scheme git-watch -configuration Debug build`
- Test: `xcodebuild test -project git-watch.xcodeproj -scheme git-watch -destination 'platform=macOS'`

## Task Files (execution order)

| # | File | Deliverable |
|---|------|-------------|
| 1 | [01-scaffold-and-infra.md](01-scaffold-and-infra.md) | Building 3-target project with ported Pulse infra (theme, login, updater, settings window) |
| 2 | [02-panel-shell.md](02-panel-shell.md) | InputPanel opens from menu bar: tabs, pinned footer, empty states |
| 3 | [03-github-settings-auth.md](03-github-settings-auth.md) | PAT/gh-CLI token resolution + GitHub settings section (tested) |
| 4 | [04-models-client.md](04-models-client.md) | GraphQL models, queries, transport client, approve/merge mutations (fixture-tested) |
| 5 | [05-classifier.md](05-classifier.md) | PRGroupings classification logic (matrix-tested) |
| 6 | [06-store-lifecycle.md](06-store-lifecycle.md) | PullRequestStore: refresh cadence, dedupe, connection states, actions (tested) |
| 7 | [07-ui-wiring.md](07-ui-wiring.md) | Real rows/sections/footer/badge wired to store; action buttons with spinners + inline errors |
| 8 | [08-release-infra.md](08-release-infra.md) | build-dmg.sh, release.yml, AGENTS.md, version 1.0.0 |

## Shared Type Contracts (defined in tasks, referenced later)

These signatures are final — later tasks must match them exactly:

```swift
// Task 3 — GitHubSettings.swift
enum MergeMethod: String, CaseIterable, Identifiable {
    case merge, squash, rebase
    var id: String { rawValue }
    var label: String          // "Merge Commit", "Squash", "Rebase"
    var graphqlName: String    // "MERGE", "SQUASH", "REBASE"
}
final class GitHubSettings: ObservableObject {
    @Published var personalAccessToken: String   // persisted on set
    @Published var mergeMethod: MergeMethod      // default .merge, persisted
}

// Task 3 — GitHubAuth.swift
enum TokenResolution: Equatable {
    case patOverride(String), ghCLI(String), none
    var token: String?
}
protocol GHCLIRunning { func authToken() -> String? }   // nil = missing/not logged in
final class GitHubAuthProvider: ObservableObject {
    init(settings: GitHubSettings, ghCLI: GHCLIRunning = GhCLI())
    @Published private(set) var resolution: TokenResolution
    func resolve()   // synchronous, cheap; order: PAT override → gh CLI → .none
}

// Task 4 — PullRequestModels.swift / GitHubClient.swift
struct DashboardSnapshot: Equatable { let viewerLogin: String; let authored: [PullRequestSummary]; let reviewRequested: [PullRequestSummary] }
enum GitHubClientError: Error, Equatable {
    case unauthorized            // HTTP 401 → token rejected
    case rateLimited             // HTTP 403/429 or "rate limit" message
    case api([String])           // GraphQL errors[].message
}
protocol GitHubTransporting {
    func post(_ query: String, variables: [String: String], token: String) async throws -> Data
}
final class URLSessionGitHubTransport: GitHubTransporting { }        // POST https://api.github.com/graphql
final class GitHubClient {
    init(provider: GitHubAuthProvider, transport: GitHubTransporting = URLSessionGitHubTransport())
    func fetchDashboard() async throws -> DashboardSnapshot
    func approve(pullRequestID: String) async throws                  // addPullRequestReview APPROVE
    func merge(pullRequestID: String, method: MergeMethod) async throws // mergePullRequest
}

// Task 5 — classification (inside PullRequestModels.swift)
struct PRGroupings: Equatable {
    let mine: [PullRequestSummary]
    let waitingMyReview: [PullRequestSummary]
    let readyToMerge: [PullRequestSummary]
}
enum PullRequestClassifier {
    static func group(authored: [PullRequestSummary], reviewRequested: [PullRequestSummary]) -> PRGroupings
}
extension PullRequestSummary {
    var canMerge: Bool   // mergeState ∈ {clean, hasHooks} && permission ∈ {write, maintain, admin}
}

// Task 6 — PullRequestStore.swift
enum ConnectionStatus: Equatable { case idle, refreshing, live, noToken, tokenRejected, rateLimited, offline, failed(String) }
@MainActor final class PullRequestStore: ObservableObject {
    init(client: GitHubClient?, settings: GitHubSettings, now: @escaping () -> Date = Date.init,
         scheduler: RefreshScheduling = TimerRefreshScheduler())
    @Published private(set) var mine: [PullRequestSummary]
    @Published private(set) var waitingMyReview: [PullRequestSummary]
    @Published private(set) var readyToMerge: [PullRequestSummary]
    @Published private(set) var viewerLogin: String?
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var status: ConnectionStatus
    @Published private(set) var actionErrors: [String: String]   // PR id → message
    @Published private(set) var inFlightActionIDs: Set<String>
    var actionableCount: Int                                     // waitingMyReview + readyToMerge
    func refresh(force: Bool) async
    func startAutomaticRefresh(interval: TimeInterval)           // production passes 300
    func stopAutomaticRefresh()
    func approve(_ summary: PullRequestSummary) async
    func merge(_ summary: PullRequestSummary) async
}
protocol RefreshScheduling: AnyObject {
    func schedule(every interval: TimeInterval, handler: @escaping () -> Void)
    func invalidate()
}
final class TimerRefreshScheduler: RefreshScheduling { }
```
