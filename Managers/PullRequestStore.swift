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
    static let dismissedIDsKey = "github.dismissedPRIds"

    @Published private(set) var mine: [PullRequestSummary] = []
    @Published private(set) var waitingMyReview: [PullRequestSummary] = []
    @Published private(set) var readyToMerge: [PullRequestSummary] = []
    @Published private(set) var viewerLogin: String?
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var status: ConnectionStatus = .idle
    @Published private(set) var actionErrors: [String: String] = [:]
    @Published private(set) var inFlightActionIDs: Set<String> = []
    @Published private(set) var dismissedIDs: Set<String> = []
    @Published private(set) var locallyApprovedIDs: Set<String> = []

    var actionableCount: Int {
        waitingMyReview.count + readyToMerge.count
    }

    var totalCount: Int {
        mine.count + waitingMyReview.count + readyToMerge.count
    }

    func shouldOfferApprove(for summary: PullRequestSummary) -> Bool {
        locallyApprovedIDs.contains(summary.id) == false
            && summary.reviewDecision != .approved
    }

    func canOfferMergeInPlace(for summary: PullRequestSummary) -> Bool {
        (locallyApprovedIDs.contains(summary.id) || summary.reviewDecision == .approved)
            && summary.canMerge
    }

    var settingsMergeMethod: MergeMethod {
        settings.mergeMethod
    }

    private var latestGroupings = PRGroupings(mine: [], waitingMyReview: [], readyToMerge: [])
    private let client: GitHubClient?
    private let settings: GitHubSettings
    private let userDefaults: UserDefaults
    private let now: () -> Date
    private let scheduler: RefreshScheduling
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var isAutoProcessing = false
    private var autoModeCancellable: AnyCancellable?
    private var catchUpTask: Task<Void, Never>?

    init(
        client: GitHubClient?,
        settings: GitHubSettings,
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        scheduler: RefreshScheduling = TimerRefreshScheduler()
    ) {
        self.client = client
        self.settings = settings
        self.userDefaults = userDefaults
        self.now = now
        self.scheduler = scheduler
        self.dismissedIDs = Set(userDefaults.stringArray(forKey: Self.dismissedIDsKey) ?? [])
        autoModeCancellable = settings.$autoModeEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard enabled else { return }
                Task { @MainActor [weak self] in
                    await self?.processAutoActions()
                }
            }
    }

    deinit {
        scheduler.invalidate()
        refreshTask?.cancel()
        catchUpTask?.cancel()
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
        if let existing = refreshTask {
            guard force else {
                await existing.value
                return
            }
            existing.cancel()
            refreshTask = nil
            refreshGeneration += 1
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        let task = Task { [weak self] in
            _ = await self?.performRefresh()
        }
        refreshTask = task
        await task.value
        if refreshGeneration == generation {
            refreshTask = nil
        }
        await processAutoActions()
    }

    func processAutoActions() async {
        guard settings.autoModeEnabled, isAutoProcessing == false else { return }
        guard client != nil else { return }
        isAutoProcessing = true
        defer { isAutoProcessing = false }

        let allowedLogins = Self.parseWhitelist(settings.whitelistedAuthors)
        let filterByWhitelist = { (pr: PullRequestSummary) -> Bool in
            allowedLogins.isEmpty || allowedLogins.contains(pr.authorLogin.lowercased())
        }

        if settings.autoApproveEnabled {
            let waitingSnapshot = waitingMyReview.filter(filterByWhitelist)
            for pr in waitingSnapshot where inFlightActionIDs.contains(pr.id) == false {
                await approve(pr)
            }
        }

        guard settings.autoModeEnabled, settings.autoMergeEnabled else { return }

        let readySnapshot = readyToMerge.filter(filterByWhitelist)
        for pr in readySnapshot where inFlightActionIDs.contains(pr.id) == false {
            await merge(pr)
        }
    }

    static func parseWhitelist(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }

    private func performRefresh() async {
        guard let client, client.isAuthenticated else {
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
        } catch is URLError {
            status = .offline
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func apply(snapshot: DashboardSnapshot, at date: Date) {
        latestGroupings = PullRequestClassifier.group(authored: snapshot.authored, reviewRequested: snapshot.reviewRequested)
        republish()
        let visibleIDs = Set(
            latestGroupings.mine.map(\.id)
                + latestGroupings.waitingMyReview.map(\.id)
                + latestGroupings.readyToMerge.map(\.id)
        )
        locallyApprovedIDs = locallyApprovedIDs.intersection(visibleIDs)
        viewerLogin = snapshot.viewerLogin
        lastRefreshedAt = date
        actionErrors.removeAll()
    }

    private func republish() {
        mine = latestGroupings.mine.filter { dismissedIDs.contains($0.id) == false }
        waitingMyReview = latestGroupings.waitingMyReview.filter { dismissedIDs.contains($0.id) == false }
        readyToMerge = latestGroupings.readyToMerge.filter { dismissedIDs.contains($0.id) == false }
    }

    func dismiss(_ summary: PullRequestSummary) {
        dismissedIDs.insert(summary.id)
        userDefaults.set(Array(dismissedIDs), forKey: Self.dismissedIDsKey)
        actionErrors[summary.id] = nil
        inFlightActionIDs.remove(summary.id)
        republish()
    }

    func restoreAllDismissed() {
        guard dismissedIDs.isEmpty == false else { return }
        dismissedIDs.removeAll()
        userDefaults.removeObject(forKey: Self.dismissedIDsKey)
        republish()
    }

    func approve(_ summary: PullRequestSummary) async {
        let succeeded = await runAction(summary) { try await $0.approve(pullRequestID: summary.id) }
        if succeeded {
            locallyApprovedIDs.insert(summary.id)
            scheduleCatchUpRefresh()
        }
    }

    func merge(_ summary: PullRequestSummary) async {
        _ = await runAction(summary) { client in
            try await client.merge(pullRequestID: summary.id, method: self.settings.mergeMethod)
        }
    }

    private func scheduleCatchUpRefresh() {
        catchUpTask?.cancel()
        catchUpTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard Task.isCancelled == false else { return }
            await self?.refresh(force: false)
        }
    }

    private func runAction(
        _ summary: PullRequestSummary,
        operation: @escaping (GitHubClient) async throws -> Void
    ) async -> Bool {
        guard let client else { return false }
        actionErrors[summary.id] = nil
        inFlightActionIDs.insert(summary.id)
        defer { inFlightActionIDs.remove(summary.id) }
        do {
            try await operation(client)
            await performRefresh()
            return true
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
        return false
    }
}
