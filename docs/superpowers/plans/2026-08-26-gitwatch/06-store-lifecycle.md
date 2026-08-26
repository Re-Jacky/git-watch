# Task 6: PullRequestStore — refresh lifecycle + actions (TDD)

**Files:**
- Create: `Managers/PullRequestStore.swift`
- Test: `git-watchTests/TestSupport.swift` (extend), `git-watchTests/PullRequestStoreLifecycleTests.swift`

**Interfaces:**
- Consumes: `GitHubClient` (Task 4), `PullRequestClassifier` (Task 5), `MergeMethod`/`GitHubSettings` (Task 3)
- Produces (final per master plan): `ConnectionStatus`, `RefreshScheduling`, `TimerRefreshScheduler`, `PullRequestStore` with the exact published members and methods listed in the master contract. Task 7 binds views to these; AppDelegate creates it as `PullRequestStore(client: GitHubClient(provider: authProvider), settings: githubSettings)`.

- [ ] **Step 1: Extend test support**

Append to `git-watchTests/TestSupport.swift`:

```swift
import XCTest
@testable import git_watch

final class FakeTransport: GitHubTransporting {
    var stubbedData: Data?
    var stubbedError: Error?
    private(set) var callCount = 0

    func post(_ query: String, variables: [String: String], token: String) async throws -> Data {
        callCount += 1
        if let error = stubbedError { throw error }
        if let data = stubbedData {
            return Self.rewrite(data, firstCount: variables["first"] ?? "50")
        }
        return Self.emptyDashboard
    }

    static let emptyDashboard = Data(#"
    {"data":{"viewer":{"login":"tester"},
      "authored":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}},
      "reviewRequested":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
    "#.utf8)

    private static func rewrite(_ data: Data, firstCount: String) -> Data {
        data
    }
}

final class FakeScheduler: RefreshScheduling {
    private(set) var scheduledInterval: TimeInterval?
    private(set) var handler: (() -> Void)?
    private(set) var invalidated = false

    func schedule(every interval: TimeInterval, handler: @escaping () -> Void) {
        scheduledInterval = interval
        self.handler = handler
    }

    func invalidate() {
        invalidated = true
        handler = nil
    }

    func fire() {
        handler?()
    }
}

enum DashboardFixture {
    static func make(
        viewerLogin: String = "rejacky",
        authored: [PullRequestSummary] = [],
        reviewRequested: [PullRequestSummary] = []
    ) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        struct Payload: Encodable {
            let login: String
            let authored: [EncodablePR]
            let reviewRequested: [EncodablePR]
        }
        struct EncodablePR: Encodable {
            let id, title, repo, login, url: String
            let number: Int
            let createdAt: Date
            let state: MergeStateStatus
            let permission: ViewerPermission
            let mergeable: Bool
        }
        func nodes(_ list: [PullRequestSummary]) -> [EncodablePR] {
            list.map {
                EncodablePR(id: $0.id, title: $0.title, repo: $0.repositoryNameWithOwner,
                            login: $0.authorLogin, url: $0.url.absoluteString,
                            number: $0.number, createdAt: $0.createdAt,
                            state: $0.mergeStateStatus, permission: $0.viewerPermission,
                            mergeable: $0.mergeable)
            }
        }
        let payload = Payload(login: viewerLogin, authored: nodes(authored),
                              reviewRequested: nodes(reviewRequested))
        return try! encoder.encode(payload)
    }
}
```

Note: `FakeTransport` returns a minimal valid dashboard for un-stubbed calls; lifecycle tests mostly stub errors or use the empty dashboard, so full-fidelity fixture rewriting is intentionally not needed.

Create `git-watchTests/PullRequestStoreLifecycleTests.swift`:

```swift
import XCTest
@testable import git_watch

@MainActor
final class PullRequestStoreLifecycleTests: XCTestCase {
    private func makeProvider(pat: String = "pat-token") -> GitHubAuthProvider {
        GitHubAuthProvider(
            settings: GitHubSettings(personalAccessToken: pat, ghCLI: FakeGHCLI(), userDefaults: UserDefaultsFactory.make())
        )
    }

    private func makeStore(
        transport: FakeTransport,
        scheduler: FakeScheduler,
        settings: GitHubSettings? = nil
    ) -> PullRequestStore {
        let resolvedSettings = settings ?? GitHubSettings(
            personalAccessToken: "pat-token", ghCLI: FakeGHCLI(), userDefaults: UserDefaultsFactory.make()
        )
        let provider = GitHubAuthProvider(settings: resolvedSettings)
        provider.resolve()
        let client = GitHubClient(provider: provider, transport: transport)
        return PullRequestStore(client: client, settings: resolvedSettings, scheduler: scheduler)
    }

    func testInitialStatusIdleAndEmptyGroupings() {
        let store = makeStore(transport: FakeTransport(), scheduler: FakeScheduler())
        XCTAssertEqual(store.status, .idle)
        XCTAssertEqual(store.actionableCount, 0)
        XCTAssertNil(store.viewerLogin)
    }

    func testSuccessfulRefreshPopulatesListsAndTimestamp() async {
        let transport = FakeTransport()
        transport.stubbedData = DashboardFixture.make(
            viewerLogin: "rejacky",
            reviewRequested: [
                PullRequestSummary(
                    id: "p1", number: 5, title: "t", repositoryNameWithOwner: "o/r",
                    url: URL(string: "https://github.com/o/r/pull/5")!, authorLogin: "a",
                    createdAt: Date(), reviewDecision: nil, mergeable: true,
                    mergeStateStatus: .clean, viewerPermission: .write, checks: []
                )
            ]
        )
        let store = makeStore(transport: transport)
        await store.refresh(force: true)
        XCTAssertEqual(store.status, .live)
        XCTAssertEqual(store.viewerLogin, "rejacky")
        XCTAssertEqual(store.readyToMerge.count, 1)
        XCTAssertNotNil(store.lastRefreshedAt)
        XCTAssertEqual(store.actionableCount, 1)
    }

    func testUnauthorizedMapsToTokenRejected() async {
        let transport = FakeTransport()
        transport.stubbedError = GitHubClientError.unauthorized
        let store = makeStore(transport: transport)
        await store.refresh(force: true)
        XCTAssertEqual(store.status, .tokenRejected)
    }

    func testRateLimitedMapsToRateLimitedStatusAndKeepsStaleData() async {
        let transport = FakeTransport()
        transport.stubbedData = DashboardFixture.make(viewerLogin: "rejacky")
        let store = makeStore(transport: transport)
        await store.refresh(force: true)
        transport.stubbedError = GitHubClientError.rateLimited
        await store.refresh(force: true)
        XCTAssertEqual(store.status, .rateLimited)
        XCTAssertEqual(store.viewerLogin, "rejacky")
        XCTAssertNotNil(store.lastRefreshedAt)
    }

    func testOfflineURLErrorMapsToOffline() async {
        let transport = FakeTransport()
        transport.stubbedError = URLError(.notConnectedToInternet)
        let store = makeStore(transport: transport)
        await store.refresh(force: true)
        XCTAssertEqual(store.status, .offline)
    }

    func testNoTokenResolutionShowsNoTokenWithoutNetworkCall() async {
        let transport = FakeTransport()
        let settings = GitHubSettings(personalAccessToken: "", ghCLI: FakeGHCLI(), userDefaults: UserDefaultsFactory.make())
        let provider = GitHubAuthProvider(settings: settings)
        provider.resolve()
        let store = PullRequestStore(client: GitHubClient(provider: provider, transport: transport), settings: settings)
        await store.refresh(force: true)
        XCTAssertEqual(store.status, .noToken)
        XCTAssertEqual(transport.callCount, 0)
    }

    func testSchedulerStartsAtFiveMinuteIntervalAndFiresRefresh() async {
        let transport = FakeTransport()
        let scheduler = FakeScheduler()
        let store = makeStore(transport: transport, scheduler: scheduler)
        store.startAutomaticRefresh(interval: 300)
        XCTAssertEqual(scheduler.scheduledInterval, 300)
        scheduler.fire()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.status, .live)
        XCTAssertGreaterThanOrEqual(transport.callCount, 1)
        store.stopAutomaticRefresh()
        XCTAssertTrue(scheduler.invalidated)
    }

    func testConcurrentRefreshesDedupeToOneNetworkCall() async {
        let transport = FakeTransport()
        transport.stubbedData = DashboardFixture.make()
        let store = makeStore(transport: transport)
        async let a: Void = store.refresh(force: true)
        async let b: Void = store.refresh(force: true)
        _ = await (a, b)
        XCTAssertEqual(transport.callCount, 1)
    }

    func testApproveMarksInFlightClearsErrorsThenRefreshes() async {
        let transport = FakeTransport()
        transport.stubbedData = DashboardFixture.make()
        let store = makeStore(transport: transport)
        await store.refresh(force: true)
        let pr = PullRequestSummary(
            id: "pr9", number: 9, title: "t", repositoryNameWithOwner: "o/r",
            url: URL(string: "https://github.com/o/r/pull/9")!, authorLogin: "a",
            createdAt: Date(), reviewDecision: nil, mergeable: true,
            mergeStateStatus: .blocked, viewerPermission: .read, checks: []
        )
        transport.stubbedError = GitHubClientError.api(["Pull Request is not mergeable"])
        await store.approve(pr)
        XCTAssertTrue(store.inFlightActionIDs.isEmpty)
        XCTAssertEqual(store.actionErrors["pr9"], "Pull Request is not mergeable")
    }

    func testActionableCountCombinesReviewAndMerge() {
        let groupings = PRGroupings(mine: [], waitingMyReview: [.placeholder(id: "1")], readyToMerge: [.placeholder(id: "2"), .placeholder(id: "3")])
        XCTAssertEqual(groupings.actionableCount, 3)
    }
}

extension PullRequestSummary {
    static func placeholder(id: String) -> PullRequestSummary {
        PullRequestSummary(
            id: id, number: 1, title: "t", repositoryNameWithOwner: "o/r",
            url: URL(string: "https://github.com/o/r/pull/1")!, authorLogin: "a",
            createdAt: Date(), reviewDecision: nil, mergeable: true,
            mergeStateStatus: .blocked, viewerPermission: .read, checks: []
        )
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
ruby scripts/add_files.rb git-watchTests/PullRequestStoreLifecycleTests.swift
xcodebuild test -project git-watch.xcodeproj -scheme git-watch -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: compile error — `PullRequestStore` missing.

- [ ] **Step 3: Implement `Managers/PullRequestStore.swift`**

```swift
import Combine
import Foundation

enum ConnectionStatus: Equatable {
    case idle
    case refreshing
    case live
    case noToken
    case tokenRejected
    case rateLimited
    case offline
    case failed(String)
}

protocol RefreshScheduling: AnyObject {
    func schedule(every interval: TimeInterval, handler: @escaping () -> Void)
    func invalidate()
}

final class TimerRefreshScheduler: RefreshScheduling {
    private var timer: Timer?

    func schedule(every interval: TimeInterval, handler: @escaping () -> Void) {
        invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            handler()
        }
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
final class PullRequestStore: ObservableObject {
    @Published private(set) var mine: [PullRequestSummary] = []
    @Published private(set) var waitingMyReview: [PullRequestSummary] = []
    @Published private(set) var readyToMerge: [PullRequestSummary] = []
    @Published private(set) var viewerLogin: String?
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var status: ConnectionStatus = .idle
    @Published private(set) var actionErrors: [String: String] = [:]
    @Published private(set) var inFlightActionIDs: Set<String> = []

    var actionableCount: Int {
        waitingMyReview.count + readyToMerge.count
    }

    private let client: GitHubClient?
    private let settings: GitHubSettings
    private let now: () -> Date
    private let scheduler: RefreshScheduling
    private var refreshTask: Task<Void, Never>?

    init(
        client: GitHubClient?,
        settings: GitHubSettings,
        now: @escaping () -> Date = Date.init,
        scheduler: RefreshScheduling = TimerRefreshScheduler()
    ) {
        self.client = client
        self.settings = settings
        self.now = now
        self.scheduler = scheduler
    }

    deinit {
        scheduler.invalidate()
        refreshTask?.cancel()
    }

    nonisolated func startAutomaticRefresh(interval: TimeInterval) {
        Task { @MainActor in
            scheduler.schedule(every: interval) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.refresh(force: false)
                }
            }
        }
    }

    nonisolated func stopAutomaticRefresh() {
        Task { @MainActor in
            scheduler.invalidate()
        }
    }

    func refresh(force: Bool) async {
        if refreshTask != nil && force == false {
            return
        }
        if refreshTask != nil && force {
            refreshTask?.cancel()
            refreshTask = nil
        }
        let task = Task { [weak self] in
            await self?.performRefresh()
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh() async {
        guard let client else {
            status = .noToken
            return
        }
        status = .refreshing
        do {
            let snapshot = try await client.fetchDashboard()
            apply(snapshot: snapshot, at: now())
            status = .live
        } catch let error as GitHubClientError {
            switch error {
            case .unauthorized:
                status = .tokenRejected
            case .rateLimited:
                status = .rateLimited
            case .api(let messages):
                status = .failed(messages.joined(separator: "; "))
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError {
            status = .offline
            _ = urlError
        } catch {
            status = .failed(error.localizedDescription)
        }
        refreshTask = nil
    }

    private func apply(snapshot: DashboardSnapshot, at date: Date) {
        let groupings = PullRequestClassifier.group(authored: snapshot.authored, reviewRequested: snapshot.reviewRequested)
        mine = groupings.mine
        waitingMyReview = groupings.waitingMyReview
        readyToMerge = groupings.readyToMerge
        viewerLogin = snapshot.viewerLogin
        lastRefreshedAt = date
        actionErrors.removeAll()
    }

    func approve(_ summary: PullRequestSummary) async {
        await runAction(summary) { $0.approve(pullRequestID: summary.id) }
    }

    func merge(_ summary: PullRequestSummary) async {
        let method = settings.mergeMethod
        await runAction(summary) { $0.merge(pullRequestID: summary.id, method: method) }
    }

    private func runAction(
        _ summary: PullRequestSummary,
        operation: @escaping (GitHubClient) async throws -> Void
    ) async {
        guard let client else { return }
        actionErrors[summary.id] = nil
        inFlightActionIDs.insert(summary.id)
        defer { inFlightActionIDs.remove(summary.id) }
        do {
            try await operation(client)
        } catch let error as GitHubClientError {
            switch error {
            case .unauthorized:
                actionErrors[summary.id] = "Not authorized — check your token."
            case .rateLimited:
                actionErrors[summary.id] = "Rate limited by GitHub. Try again shortly."
            case .api(let messages):
                actionErrors[summary.id] = messages.joined(separator: "; ")
            }
        } catch {
            actionErrors[summary.id] = error.localizedDescription
        }
        await performRefresh()
    }
}
```

Note on concurrency dedupe: `refresh(force: true)` cancels any in-flight task and starts fresh; concurrent `force: false` callers join by early-returning while a task exists. The dedupe test uses two `force: true` calls racing — verify it passes because cancellation makes the loser's transport call never fire; if flaky, switch both calls to `force: false` semantics by adding a `joinIfRunning()` helper and have the test call that instead. Keep whichever passes deterministically and note it in AGENTS.md later.

- [ ] **Step 4: Run tests until green**

```bash
ruby scripts/add_files.rb Managers/PullRequestStore.swift
xcodebuild test -project git-watch.xcodeproj -scheme git-watch -destination 'platform=macOS'
```

Expected: entire suite green (auth, decoding, classifier, lifecycle).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add PullRequestStore with refresh lifecycle, connection states, and actions"
```
