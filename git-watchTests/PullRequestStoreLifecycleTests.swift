import XCTest
@testable import git_watch

@MainActor
final class PullRequestStoreLifecycleTests: XCTestCase {
    private func makeProvider(pat: String = "pat-token") -> GitHubAuthProvider {
        let ghCLI = FakeGHCLI()
        return GitHubAuthProvider(
            settings: GitHubSettings(
                personalAccessToken: pat,
                ghCLI: ghCLI,
                userDefaults: UserDefaultsFactory.make()
            ),
            ghCLI: ghCLI
        )
    }

    private func makeStore(
        pat: String = "pat-token",
        transport: FakeTransport,
        scheduler: FakeScheduler = FakeScheduler()
    ) -> PullRequestStore {
        let ghCLI = FakeGHCLI()
        let resolvedSettings = GitHubSettings(
            personalAccessToken: pat,
            ghCLI: ghCLI,
            userDefaults: UserDefaultsFactory.make()
        )
        let provider = GitHubAuthProvider(settings: resolvedSettings, ghCLI: ghCLI)
        provider.resolve()
        let client = GitHubClient(provider: provider, transport: transport)
        return PullRequestStore(client: client, settings: resolvedSettings, scheduler: scheduler)
    }

    func testInitialStatusIdleAndEmptyGroupings() {
        let store = makeStore(transport: FakeTransport())
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
        let ghCLI = FakeGHCLI()
        let settings = GitHubSettings(
            personalAccessToken: "", ghCLI: ghCLI, userDefaults: UserDefaultsFactory.make()
        )
        let provider = GitHubAuthProvider(settings: settings, ghCLI: ghCLI)
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
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(scheduler.scheduledInterval, 300)
        scheduler.fire()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.status, .live)
        XCTAssertGreaterThanOrEqual(transport.callCount, 1)
        store.stopAutomaticRefresh()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(scheduler.invalidated)
    }

    func testConcurrentRefreshesDedupeToOneNetworkCall() async {
        let transport = FakeTransport()
        transport.stubbedData = DashboardFixture.make()
        let store = makeStore(transport: transport)
        async let a: Void = store.refresh(force: false)
        async let b: Void = store.refresh(force: false)
        _ = await (a, b)
        XCTAssertEqual(transport.callCount, 1)
    }

    func testForceRefreshDuringInFlightPreservesSlotRegistration() async {
        let gated = GatedTransport()
        let ghCLI = FakeGHCLI()
        let settings = GitHubSettings(
            personalAccessToken: "pat-token", ghCLI: ghCLI, userDefaults: UserDefaultsFactory.make()
        )
        let provider = GitHubAuthProvider(settings: settings, ghCLI: ghCLI)
        provider.resolve()
        let store = PullRequestStore(client: GitHubClient(provider: provider, transport: gated), settings: settings)
        let a = Task { await store.refresh(force: true) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(gated.callCount, 1)
        XCTAssertEqual(gated.parkedCount, 1)
        let b = Task { await store.refresh(force: true) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(gated.callCount, 2)
        XCTAssertEqual(gated.parkedCount, 2)
        gated.releaseOldest()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let j = Task { await store.refresh(force: false) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(gated.callCount, 2)
        XCTAssertEqual(gated.parkedCount, 1)
        gated.releaseAll()
        await (a.value, b.value, j.value)
        XCTAssertEqual(store.status, .live)
    }

    func testFailedApproveRetainsInlineErrorWithoutForcedRefresh() async {
        let transport = FakeTransport()
        transport.stubbedData = DashboardFixture.make()
        let store = makeStore(transport: transport)
        await store.refresh(force: true)
        XCTAssertEqual(store.status, .live)
        XCTAssertEqual(transport.callCount, 1)
        let refreshedAtBeforeAction = store.lastRefreshedAt
        XCTAssertNotNil(refreshedAtBeforeAction)

        let pr = PullRequestSummary(
            id: "pr9", number: 9, title: "t", repositoryNameWithOwner: "o/r",
            url: URL(string: "https://github.com/o/r/pull/9")!, authorLogin: "a",
            createdAt: Date(), reviewDecision: nil, mergeable: true,
            mergeStateStatus: .blocked, viewerPermission: .read, checks: []
        )
        transport.stubbedError = GitHubClientError.api(["Pull Request is not mergeable"])
        await store.approve(pr)
        XCTAssertTrue(store.inFlightActionIDs.isEmpty)

        transport.stubbedError = nil
        XCTAssertEqual(store.actionErrors["pr9"], "Pull Request is not mergeable")
        XCTAssertEqual(store.lastRefreshedAt, refreshedAtBeforeAction)
        XCTAssertEqual(store.status, .live)
        XCTAssertEqual(transport.callCount, 2)
    }

    func testSuccessfulApproveClearsErrorsViaRefresh() async {
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
        transport.stubbedError = GitHubClientError.api(["blocked"])
        await store.approve(pr)
        XCTAssertEqual(store.actionErrors["pr9"], "blocked")
        XCTAssertEqual(transport.callCount, 2)
        let timestampAfterFailedAction = store.lastRefreshedAt

        transport.stubbedError = nil
        await store.approve(pr)
        XCTAssertTrue(store.actionErrors.isEmpty)
        XCTAssertNotEqual(store.lastRefreshedAt, timestampAfterFailedAction)
        XCTAssertEqual(store.status, .live)
        XCTAssertEqual(transport.callCount, 4)
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
