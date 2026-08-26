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
        if let existing = refreshTask {
            guard force else {
                await existing.value
                return
            }
            existing.cancel()
            refreshTask = nil
        }
        let task = Task { [weak self] in
            _ = await self?.performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
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
        let groupings = PullRequestClassifier.group(authored: snapshot.authored, reviewRequested: snapshot.reviewRequested)
        mine = groupings.mine
        waitingMyReview = groupings.waitingMyReview
        readyToMerge = groupings.readyToMerge
        viewerLogin = snapshot.viewerLogin
        lastRefreshedAt = date
        actionErrors.removeAll()
    }

    func approve(_ summary: PullRequestSummary) async {
        await runAction(summary) { try await $0.approve(pullRequestID: summary.id) }
    }

    func merge(_ summary: PullRequestSummary) async {
        let method = settings.mergeMethod
        await runAction(summary) { try await $0.merge(pullRequestID: summary.id, method: method) }
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
