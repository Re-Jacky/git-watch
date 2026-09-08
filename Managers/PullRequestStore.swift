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

struct AutoApprovedEntry: Identifiable, Equatable, Codable {
    let id: String
    let number: Int
    let title: String
    let repositoryNameWithOwner: String
    let url: URL
    let authorLogin: String
    let createdAt: Date
    let approvedAt: Date
}

@MainActor
final class PullRequestStore: ObservableObject {
    static let dismissedIDsKey = "github.dismissedPRIds"
    static let autoApprovedHistoryKey = "github.autoApprovedHistory"
    static let autoApprovedHistoryLimit = 100

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
    @Published private(set) var autoApprovedHistory: [AutoApprovedEntry] = []
    @Published private(set) var mergedHistoryIDs: Set<String> = []
    @Published private(set) var historyStatuses: [String: HistoryPRStatus] = [:]

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

    func canOfferMergeForMine(for summary: PullRequestSummary) -> Bool {
        guard summary.reviewDecision == .approved || summary.reviewDecision == nil else { return false }
        return summary.canMerge
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
        self.autoApprovedHistory = Self.loadAutoApprovedHistory(from: userDefaults)
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
        await refreshHistoryStates()
        await processAutoActions()
    }

    private func refreshHistoryStates() async {
        guard status == .live, let client else {
            return
        }
        let ids = autoApprovedHistory.map(\.id)
        guard ids.isEmpty == false else {
            mergedHistoryIDs = []
            historyStatuses = [:]
            return
        }
        do {
            let states = try await client.fetchHistoryStates(ids: ids)
            let known = states.filter { ids.contains($0.key) }
            historyStatuses = known
            mergedHistoryIDs = Set(known.filter { $0.value.merged }.map(\.key))
        } catch {
            return
        }
    }

    func historySummary(for entry: AutoApprovedEntry) -> PullRequestSummary {
        let status = historyStatuses[entry.id]
        return PullRequestSummary(
            id: entry.id,
            number: entry.number,
            title: entry.title,
            repositoryNameWithOwner: entry.repositoryNameWithOwner,
            url: entry.url,
            authorLogin: entry.authorLogin,
            createdAt: entry.createdAt,
            reviewDecision: status?.reviewDecision ?? .approved,
            mergeable: status?.mergeable ?? false,
            mergeStateStatus: status?.mergeStateStatus ?? .unknown,
            viewerPermission: status?.viewerPermission ?? .unknown,
            checks: []
        )
    }

    func canOfferMergeForHistory(_ entry: AutoApprovedEntry) -> Bool {
        guard let status = historyStatuses[entry.id], status.merged == false else { return false }
        guard status.reviewDecision == .approved || status.reviewDecision == nil else { return false }
        return status.canMerge
    }

    func mergeHistoryEntry(_ entry: AutoApprovedEntry) async {
        let status = historyStatuses[entry.id]
        let headRepo = status?.headRepositoryNameWithOwner
        let headRepoOrFallback = (headRepo?.isEmpty == false ? headRepo : nil) ?? entry.repositoryNameWithOwner
        await merge(
            PullRequestSummary(
                id: entry.id,
                number: entry.number,
                title: entry.title,
                repositoryNameWithOwner: entry.repositoryNameWithOwner,
                url: entry.url,
                authorLogin: entry.authorLogin,
                createdAt: entry.createdAt,
                reviewDecision: status?.reviewDecision,
                mergeable: status?.mergeable ?? false,
                mergeStateStatus: status?.mergeStateStatus ?? .unknown,
                viewerPermission: status?.viewerPermission ?? .unknown,
                checks: [],
                headRefName: status?.headRefName ?? "",
                headRepositoryNameWithOwner: headRepoOrFallback
            )
        )
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
                await approve(pr, isAuto: true)
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

    func approve(_ summary: PullRequestSummary, isAuto: Bool = false) async {
        let succeeded = await runAction(summary) { try await $0.approve(pullRequestID: summary.id) }
        if succeeded {
            locallyApprovedIDs.insert(summary.id)
            if isAuto {
                recordAutoApproved(summary)
            }
            scheduleCatchUpRefresh()
        }
    }

    func clearAutoApprovedHistory() {
        guard autoApprovedHistory.isEmpty == false else { return }
        autoApprovedHistory.removeAll()
        userDefaults.removeObject(forKey: Self.autoApprovedHistoryKey)
    }

    private func recordAutoApproved(_ summary: PullRequestSummary) {
        guard summary.repositoryNameWithOwner != "o/r" else { return }
        let entry = AutoApprovedEntry(
            id: summary.id,
            number: summary.number,
            title: summary.title,
            repositoryNameWithOwner: summary.repositoryNameWithOwner,
            url: summary.url,
            authorLogin: summary.authorLogin,
            createdAt: summary.createdAt,
            approvedAt: now()
        )
        autoApprovedHistory.removeAll { $0.id == entry.id }
        autoApprovedHistory.insert(entry, at: 0)
        if autoApprovedHistory.count > Self.autoApprovedHistoryLimit {
            autoApprovedHistory = Array(autoApprovedHistory.prefix(Self.autoApprovedHistoryLimit))
        }
        Self.saveAutoApprovedHistory(autoApprovedHistory, to: userDefaults)
    }

    private static func loadAutoApprovedHistory(from userDefaults: UserDefaults) -> [AutoApprovedEntry] {
        guard let data = userDefaults.data(forKey: autoApprovedHistoryKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = (try? decoder.decode([AutoApprovedEntry].self, from: data)) ?? []
        let filtered = decoded.filter { $0.repositoryNameWithOwner != "o/r" }
        if filtered.count != decoded.count {
            saveAutoApprovedHistory(filtered, to: userDefaults)
        }
        return filtered
    }

    private static func saveAutoApprovedHistory(_ history: [AutoApprovedEntry], to userDefaults: UserDefaults) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(history) {
            userDefaults.set(data, forKey: autoApprovedHistoryKey)
        }
    }

    func merge(_ summary: PullRequestSummary) async {
        let succeeded = await runAction(summary) { client in
            try await client.merge(pullRequestID: summary.id, method: self.settings.mergeMethod)
        }
        guard succeeded, settings.deleteBranchAfterMerge else { return }
        await deleteHeadBranch(for: summary)
    }

    private func deleteHeadBranch(for summary: PullRequestSummary) async {
        guard let client, summary.headRefName.isEmpty == false else { return }
        let repo = summary.headRepositoryNameWithOwner.isEmpty ? summary.repositoryNameWithOwner : summary.headRepositoryNameWithOwner
        let parts = repo.split(separator: "/")
        guard parts.count == 2 else { return }
        do {
            try await client.deleteHeadBranch(owner: String(parts[0]), repo: String(parts[1]), branch: summary.headRefName)
        } catch let error as GitHubClientError {
            switch error {
            case .unauthorized:
                actionErrors[summary.id] = "Merged, but branch delete was not authorized — check your token."
            case .rateLimited:
                actionErrors[summary.id] = "Merged, but branch delete was rate limited. Try again shortly."
            case .api(let messages):
                actionErrors[summary.id] = "Merged, but branch delete failed: \(messages.joined(separator: "; "))"
            }
        } catch {
            actionErrors[summary.id] = "Merged, but branch delete failed: \(error.localizedDescription)"
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
