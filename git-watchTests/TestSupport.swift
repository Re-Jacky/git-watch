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

final class FakeTransport: GitHubTransporting {
    var stubbedData: Data?
    var stubbedError: Error?
    private(set) var callCount = 0

    func post(_ query: String, variables: [String: Any], token: String) async throws -> Data {
        callCount += 1
        if let error = stubbedError { throw error }
        return stubbedData ?? Self.emptyDashboard
    }

    static let emptyDashboard = Data(#"""
    {"data":{"viewer":{"login":"tester"},
      "authored":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}},
      "reviewRequested":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}
    """#.utf8)
}

final class GatedTransport: GitHubTransporting {
    private(set) var callCount = 0
    private var parked: [CheckedContinuation<Void, Never>] = []

    var parkedCount: Int { parked.count }

    func post(_ query: String, variables: [String: Any], token: String) async throws -> Data {
        callCount += 1
        await withCheckedContinuation { continuation in
            parked.append(continuation)
        }
        return FakeTransport.emptyDashboard
    }

    func releaseOldest() {
        guard parked.isEmpty == false else { return }
        parked.removeFirst().resume()
    }

    func releaseAll() {
        let all = parked
        parked.removeAll()
        for continuation in all { continuation.resume() }
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
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func make(
        viewerLogin: String = "rejacky",
        authored: [PullRequestSummary] = [],
        reviewRequested: [PullRequestSummary] = []
    ) -> Data {
        func checkNode(_ dot: CheckStatusDot) -> [String: Any] {
            switch dot.outcome {
            case .success:
                return ["__typename": "CheckRun", "conclusion": "SUCCESS", "status": "COMPLETED"]
            case .failure:
                return ["__typename": "CheckRun", "conclusion": "FAILURE", "status": "COMPLETED"]
            case .pending:
                return ["__typename": "CheckRun", "status": "IN_PROGRESS"]
            }
        }
        func node(_ pr: PullRequestSummary) -> [String: Any] {
            var json: [String: Any] = [
                "id": pr.id,
                "number": pr.number,
                "title": pr.title,
                "url": pr.url.absoluteString,
                "createdAt": iso.string(from: pr.createdAt),
                "author": ["login": pr.authorLogin],
                "repository": [
                    "nameWithOwner": pr.repositoryNameWithOwner,
                    "viewerPermission": pr.viewerPermission.rawValue
                ],
                "mergeable": pr.mergeable ? "MERGEABLE" : "CONFLICTING",
                "mergeStateStatus": pr.mergeStateStatus.rawValue
            ]
            if let decision = pr.reviewDecision {
                json["reviewDecision"] = decision.rawValue
            }
            if pr.checks.isEmpty == false {
                json["commits"] = ["nodes": [[
                    "commit": ["statusCheckRollup": ["contexts": [
                        "totalCount": pr.checks.count,
                        "nodes": pr.checks.map(checkNode)
                    ]]]]]
                ]
            }
            return json
        }
        func connection(_ list: [PullRequestSummary]) -> [String: Any] {
            ["nodes": list.map(node), "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]
        }
        let envelope: [String: Any] = [
            "data": [
                "viewer": ["login": viewerLogin],
                "authored": connection(authored),
                "reviewRequested": connection(reviewRequested)
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: envelope)
    }
}
