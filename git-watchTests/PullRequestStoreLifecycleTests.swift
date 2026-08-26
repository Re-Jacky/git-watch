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

    private func makeStoreWithDefaults(
        defaults: UserDefaults,
        transport: FakeTransport
    ) -> PullRequestStore {
        let ghCLI = FakeGHCLI()
        let resolvedSettings = GitHubSettings(
            personalAccessToken: "pat-token",
            ghCLI: ghCLI,
            userDefaults: UserDefaultsFactory.make()
        )
        let provider = GitHubAuthProvider(settings: resolvedSettings, ghCLI: ghCLI)
        provider.resolve()
        let client = GitHubClient(provider: provider, transport: transport)
        return PullRequestStore(client: client, settings: resolvedSettings, userDefaults: defaults)
    }

    private func makeAutoStore(transport: FakeTransport) -> PullRequestStore {
        let (store, _) = makeInstrumentedAutoStore(transport: transport)
        return store
    }

    private func makeInstrumentedAutoStore(transport: FakeTransport) -> (PullRequestStore, GitHubSettings) {
        let ghCLI = FakeGHCLI()
        let resolvedSettings = GitHubSettings(
            personalAccessToken: "pat-token",
            ghCLI: ghCLI,
            userDefaults: UserDefaultsFactory.make()
        )
        resolvedSettings.autoModeEnabled = true
        let provider = GitHubAuthProvider(settings: resolvedSettings, ghCLI: ghCLI)
        provider.resolve()
        let client = GitHubClient(provider: provider, transport: transport)
        return (PullRequestStore(client: client, settings: resolvedSettings), resolvedSettings)
    }

    func testAutoModeDisabledDoesNotMutateAnything() async {
        let transport = FakeTransport()
        transport.stubbedData = DashboardFixture.make(
            reviewRequested: [
                .placeholder(id: "r1"),
                .placeholder(id: "r2", state: .clean, permission: .write, mergeable: true)
            ]
        )
        let store = makeStore(transport: transport)
        await store.refresh(force: true)
        XCTAssertEqual(transport.mutationCallCount(containing: "addPullRequestReview"), 0)
        XCTAssertEqual(transport.mutationCallCount(containing: "mergePullRequest"), 0)
    }

    func testAutoModeApprovesWaitingAndMergesReadyAfterRefresh() async {
        let transport = FakeTransport()
        transport.stubbedData = DashboardFixture.make(
            reviewRequested: [
                .placeholder(id: "r1"),
                .placeholder(id: "r2", state: .clean, permission: .write, mergeable: true)
            ]
        )
        let store = makeAutoStore(transport: transport)
        await store.refresh(force: true)
        XCTAssertGreaterThanOrEqual(transport.mutationCallCount(containing: "addPullRequestReview"), 1)
        XCTAssertGreaterThanOrEqual(transport.mutationCallCount(containing: "mergePullRequest"), 1)
    }

    func testAutoModeReapprovesAfterStaleDismissalAcrossCycles() async {
        let transport = FakeTransport()
        transport.stubbedData = DashboardFixture.make(
            reviewRequested: [.placeholder(id: "r1")]
        )
        let store = makeAutoStore(transport: transport)
        await store.refresh(force: true)
        XCTAssertEqual(transport.mutationCallCount(containing: "addPullRequestReview"), 1)

        await store.refresh(force: true)
        XCTAssertEqual(transport.mutationCallCount(containing: "addPullRequestReview"), 2)
    }

    func testDisablingAutoModeStopsMutations() async {
        let transport = FakeTransport()
        transport.stubbedData = DashboardFixture.make(
            reviewRequested: [.placeholder(id: "r1")]
        )
        let (store, settings) = makeInstrumentedAutoStore(transport: transport)
        await store.refresh(force: true)
        XCTAssertEqual(transport.mutationCallCount(containing: "addPullRequestReview"), 1)

        await MainActor.run { settings.autoModeEnabled = false }
        await store.refresh(force: true)
        XCTAssertEqual(transport.mutationCallCount(containing: "addPullRequestReview"), 1)
    }

    @MainActor
    func testEnablingAutoModeProcessesImmediately() async {
        let transport = FakeTransport()
        transport.stubbedData = DashboardFixture.make(
            reviewRequested: [.placeholder(id: "r1")]
        )
        let ghCLI = FakeGHCLI()
        let settings = GitHubSettings(
            personalAccessToken: "pat-token",
            ghCLI: ghCLI,
            userDefaults: UserDefaultsFactory.make()
        )
        let provider = GitHubAuthProvider(settings: settings, ghCLI: ghCLI)
        provider.resolve()
        let store = PullRequestStore(client: GitHubClient(provider: provider, transport: transport), settings: settings)

        await store.refresh(force: true)
        XCTAssertEqual(transport.mutationCallCount(containing: "addPullRequestReview"), 0)

        settings.autoModeEnabled = true
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertGreaterThanOrEqual(transport.mutationCallCount(containing: "addPullRequestReview"), 1)
    }

    func testAutoApproveFailureRecordsInlineErrorAndRetriesNextCycle() async {
        let transport = FakeTransport()
        transport.failMutations = true
        transport.stubbedData = DashboardFixture.make(
            reviewRequested: [
                .placeholder(id: "r1"),
                .placeholder(id: "r2", state: .clean, permission: .write, mergeable: true)
            ]
        )
        let store = makeAutoStore(transport: transport)
        await store.refresh(force: true)
        XCTAssertEqual(store.actionErrors["r1"], "mutation rejected")
        XCTAssertEqual(store.actionErrors["r2"], "mutation rejected")

        await store.refresh(force: true)
        XCTAssertEqual(transport.mutationCallCount(containing: "addPullRequestReview"), 2)
    }

    func testTotalCountCombinesAllLivePRs() async {
        let transport = FakeTransport()
        transport.stubbedData = DashboardFixture.make(
            viewerLogin: "rejacky",
            authored: [.placeholder(id: "m1")],
            reviewRequested: [
                .placeholder(id: "r1", state: .clean, permission: .write, mergeable: true),
                .placeholder(id: "r2")
            ]
        )
        let store = makeStore(transport: transport)
        await store.refresh(force: true)
        XCTAssertEqual(store.mine.count, 1)
        XCTAssertEqual(store.waitingMyReview.count, 1)
        XCTAssertEqual(store.readyToMerge.count, 1)
        XCTAssertEqual(store.totalCount, 3)
    }

    func testDismissHidesPREverywhereAndPersistsAcrossInstances() async {
        let defaults = UserDefaultsFactory.make()
        let transport = FakeTransport()
        transport.stubbedData = DashboardFixture.make(
            authored: [.placeholder(id: "m1")],
            reviewRequested: [.placeholder(id: "r1")]
        )
        let store = makeStoreWithDefaults(defaults: defaults, transport: transport)
        await store.refresh(force: true)
        XCTAssertEqual(store.totalCount, 2)

        store.dismiss(.placeholder(id: "m1"))
        XCTAssertTrue(store.mine.isEmpty)
        XCTAssertEqual(store.waitingMyReview.count, 1)
        XCTAssertEqual(store.totalCount, 1)

        let reloaded = makeStoreWithDefaults(defaults: defaults, transport: FakeTransport())
        XCTAssertEqual(reloaded.dismissedIDs, ["m1"])
    }

    func testRestoreAllDismissedShowsItemsImmediatelyWithoutNetwork() async {
        let defaults = UserDefaultsFactory.make()
        let transport = FakeTransport()
        transport.stubbedData = DashboardFixture.make(
            reviewRequested: [.placeholder(id: "r1")]
        )
        let store = makeStoreWithDefaults(defaults: defaults, transport: transport)
        await store.refresh(force: true)
        XCTAssertEqual(transport.callCount, 1)

        store.dismiss(.placeholder(id: "r1"))
        XCTAssertTrue(store.waitingMyReview.isEmpty)

        store.restoreAllDismissed()
        XCTAssertTrue(store.dismissedIDs.isEmpty)
        XCTAssertEqual(store.waitingMyReview.count, 1)
        XCTAssertEqual(store.totalCount, 1)
        XCTAssertEqual(transport.callCount, 1)
    }

    func testDismissedPRStaysHiddenAfterSubsequentRefresh() async {
        let defaults = UserDefaultsFactory.make()
        let transport = FakeTransport()
        transport.stubbedData = DashboardFixture.make(
            reviewRequested: [.placeholder(id: "r1"), .placeholder(id: "r2")]
        )
        let store = makeStoreWithDefaults(defaults: defaults, transport: transport)
        await store.refresh(force: true)
        XCTAssertEqual(store.waitingMyReview.count, 2)

        store.dismiss(.placeholder(id: "r1"))
        await store.refresh(force: true)
        XCTAssertEqual(store.waitingMyReview.count, 1)
        XCTAssertEqual(store.waitingMyReview.first?.id, "r2")
        XCTAssertEqual(store.totalCount, 1)
    }
}

extension PullRequestSummary {
    static func placeholder(
        id: String,
        state: MergeStateStatus,
        permission: ViewerPermission,
        mergeable: Bool
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id, number: 1, title: "t", repositoryNameWithOwner: "o/r",
            url: URL(string: "https://github.com/o/r/pull/1")!, authorLogin: "a",
            createdAt: Date(), reviewDecision: nil, mergeable: mergeable,
            mergeStateStatus: state, viewerPermission: permission, checks: []
        )
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
