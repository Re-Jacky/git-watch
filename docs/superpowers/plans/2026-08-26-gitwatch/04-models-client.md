# Task 4: GraphQL models, queries, client, mutations (TDD)

**Files:**
- Create: `Managers/PullRequestModels.swift`, `Managers/GitHubQueries.swift`, `Managers/GitHubClient.swift`
- Test: `git-watchTests/PullRequestModelDecodingTests.swift`

**Interfaces:**
- Consumes: `GitHubAuthProvider` (Task 3)
- Produces (final per master plan): `PullRequestSummary` (all fields incl. `checks: [CheckStatusDot]`), `ReviewDecision`/`MergeStateStatus`/`ViewerPermission`/`CheckOutcome` enums with exact rawValues matching GitHub's GraphQL enum strings, `DashboardSnapshot`, `GitHubTransporting`, `URLSessionGitHubTransport`, `GitHubClientError`, `GitHubClient(provider:transport:)` with `fetchDashboard()`, `approve(pullRequestID:)`, `merge(pullRequestID:method:)`. Task 5 consumes `PullRequestSummary`; Task 6 consumes `GitHubClient`.

- [ ] **Step 1: Write the failing decoding tests**

Create `git-watchTests/PullRequestModelDecodingTests.swift`:

```swift
import XCTest
@testable import git_watch

final class PullRequestModelDecodingTests: XCTestCase {
    private let dashboardFixture = """
    {
      "data": {
        "viewer": { "login": "rejacky" },
        "authored": {
          "nodes": [
            {
              "id": "PRR_1", "number": 142, "title": "Fix memory leak in monitor loop",
              "url": "https://github.com/Re-Jacky/pulse/pull/142",
              "createdAt": "2026-08-26T09:15:00Z",
              "author": { "login": "rejacky" },
              "repository": { "nameWithOwner": "Re-Jacky/pulse" },
              "reviewDecision": "CHANGES_REQUESTED",
              "mergeable": "CONFLICTING",
              "mergeStateStatus": "DIRTY",
              "viewerPermission": "WRITE",
              "commits": { "nodes": [ { "commit": { "statusCheckRollup": { "contexts": {
                "totalCount": 2,
                "nodes": [
                  { "__typename": "CheckRun", "conclusion": "SUCCESS", "status": "COMPLETED" },
                  { "__typename": "CheckRun", "conclusion": null, "status": "IN_PROGRESS" }
                ]
              } } } } ] }
            }
          ],
          "pageInfo": { "hasNextPage": false, "endCursor": null }
        },
        "reviewRequested": {
          "nodes": [
            {
              "id": "PRR_2", "number": 203, "title": "Rotate staging TLS certificates",
              "url": "https://github.com/acme/infra/pull/203",
              "createdAt": "2026-08-26T08:00:00Z",
              "author": { "login": "teammate" },
              "repository": { "nameWithOwner": "acme/infra" },
              "reviewDecision": "REVIEW_REQUIRED",
              "mergeable": "MERGEABLE",
              "mergeStateStatus": "CLEAN",
              "viewerPermission": "ADMIN",
              "commits": { "nodes": [ { "commit": { "statusCheckRollup": { "contexts": {
                "totalCount": 1,
                "nodes": [ { "__typename": "CheckRun", "conclusion": "FAILURE", "status": "COMPLETED" } ]
              } } } } ] }
            }
          ],
          "pageInfo": { "hasNextPage": false, "endCursor": null }
        }
      }
    }
    """

    func testDashboardDecodesViewerLoginAndBothLists() throws {
        let snapshot = try GitHubClient.decodeDashboardResponse(Data(dashboardFixture.utf8))
        XCTAssertEqual(snapshot.viewerLogin, "rejacky")
        XCTAssertEqual(snapshot.authored.count, 1)
        XCTAssertEqual(snapshot.reviewRequested.count, 1)
        XCTAssertEqual(snapshot.authored[0].repositoryNameWithOwner, "Re-Jacky/pulse")
        XCTAssertEqual(snapshot.authored[0].reviewDecision, .changesRequested)
        XCTAssertEqual(snapshot.authored[0].checks.count, 2)
        XCTAssertEqual(snapshot.authored[0].checks.map(\.outcome), [.success, .pending])
        XCTAssertEqual(snapshot.reviewRequested[0].checks.first?.outcome, .failure)
        XCTAssertEqual(snapshot.reviewRequested[0].mergeStateStatus, .clean)
        XCTAssertEqual(snapshot.reviewRequested[0].viewerPermission, .admin)
    }

    func testGraphQLTopLevelErrorsSurfaceAsAPIError() {
        let body = #"{"errors":[{"message":"Bad credentials"},{"message":"Something else"}]}"#
        XCTAssertThrowsError(try GitHubClient.decodeDashboardResponse(Data(body.utf8))) { error in
            guard case let GitHubClientError.api(messages) = error else {
                return XCTFail("expected .api error, got \(error)")
            }
            XCTAssertEqual(messages, ["Bad credentials", "Something else"])
        }
    }

    func testRateLimitMessageMapsToRateLimited() {
        let body = #"{"errors":[{"message":"API rate limit exceeded for installation."}]}"#
        XCTAssertThrowsError(try GitHubClient.decodeDashboardResponse(Data(body.utf8))) { error in
            XCTAssertEqual(error as? GitHubClientError, .rateLimited)
        }
    }

    func testMutationMergePayloadParsesMergedFlag() throws {
        let body = #"{"data":{"mergePullRequest":{"pullRequest":{"merged":true}}}}"#
        XCTAssertTrue(try GitHubClient.decodeMergeResponse(Data(body.utf8)))
    }

    func testMergeMethodGraphqlNamesAreStable() {
        XCTAssertEqual(MergeMethod.merge.graphqlName, "MERGE")
        XCTAssertEqual(MergeMethod.squash.graphqlName, "SQUASH")
        XCTAssertEqual(MergeMethod.rebase.graphqlName, "REBASE")
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
ruby scripts/add_files.rb git-watchTests/PullRequestModelDecodingTests.swift
xcodebuild test -project git-watch.xcodeproj -scheme git-watch -destination 'platform=macOS' -only-testing:git-watchTests/PullRequestModelDecodingTests 2>&1 | tail -5
```

Expected: compile error — types missing.

- [ ] **Step 3: Implement `Managers/PullRequestModels.swift`**

```swift
import Foundation

enum ReviewDecision: String, Codable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

enum MergeStateStatus: String, Codable {
    case clean = "CLEAN"
    case dirty = "DIRTY"
    case blocked = "BLOCKED"
    case behind = "BEHIND"
    case unstable = "UNSTABLE"
    case hasHooks = "HAS_HOOKS"
    case draft = "DRAFT"
    case unknown = "UNKNOWN"
}

enum ViewerPermission: String, Codable {
    case admin = "ADMIN"
    case maintain = "MAINTAIN"
    case write = "WRITE"
    case read = "READ"
    case unknown = "UNKNOWN"
}

enum CheckOutcome: String {
    case success
    case failure
    case pending
}

struct CheckStatusDot: Equatable {
    let outcome: CheckOutcome
}

struct PullRequestSummary: Identifiable, Equatable {
    let id: String
    let number: Int
    let title: String
    let repositoryNameWithOwner: String
    let url: URL
    let authorLogin: String
    let createdAt: Date
    let reviewDecision: ReviewDecision?
    let mergeable: Bool
    let mergeStateStatus: MergeStateStatus
    let viewerPermission: ViewerPermission
    let checks: [CheckStatusDot]

    var canMerge: Bool {
        let stateOK = mergeStateStatus == .clean || mergeStateStatus == .hasHooks
        let permissionOK = viewerPermission == .write || viewerPermission == .maintain || viewerPermission == .admin
        return stateOK && permissionOK && mergeable
    }
}
```

- [ ] **Step 4: Implement `Managers/GitHubQueries.swift`**

```swift
import Foundation

enum GitHubQueries {
    static let endpoint = URL(string: "https://api.github.com/graphql")!

    static let dashboard = """
    query Dashboard($first: Int!) {
      viewer { login }
      authored: search(query: "is:pr is:open archived:false author:@me", type: ISSUE, first: $first) {
        nodes { ... on PullRequest { ...PullRequestFields } }
        pageInfo { hasNextPage endCursor }
      }
      reviewRequested: search(query: "is:pr is:open archived:false review-requested:@me", type: ISSUE, first: $first) {
        nodes { ... on PullRequest { ...PullRequestFields } }
        pageInfo { hasNextPage endCursor }
      }
    }
    fragment PullRequestFields on PullRequest {
      id
      number
      title
      url
      createdAt
      author { login }
      repository { nameWithOwner }
      reviewDecision
      mergeable
      mergeStateStatus
      viewerPermission
      commits(last: 1) {
        nodes {
          commit {
            statusCheckRollup {
              contexts(first: 50) {
                totalCount
                nodes {
                  __typename
                  ... on CheckRun { conclusion status }
                  ... on StatusContext { state }
                }
              }
            }
          }
        }
      }
    }
    """

    static let approve = """
    mutation Approve($pullRequestId: ID!) {
      addPullRequestReview(input: { pullRequestId: $pullRequestId, event: APPROVE }) {
        pullRequestReview { id }
      }
    }
    """

    static let merge = """
    mutation Merge($pullRequestId: ID!, $method: PullRequestMergeMethod!) {
      mergePullRequest(input: { pullRequestId: $pullRequestId, mergeMethod: $method }) {
        pullRequest { merged }
      }
    }
    """
}
```

- [ ] **Step 5: Implement `Managers/GitHubClient.swift`**

```swift
import Foundation

enum GitHubClientError: Error, Equatable {
    case unauthorized
    case rateLimited
    case api([String])
}

protocol GitHubTransporting {
    func post(_ query: String, variables: [String: String], token: String) async throws -> Data
}

final class URLSessionGitHubTransport: GitHubTransporting {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func post(_ query: String, variables: [String: String], token: String) async throws -> Data {
        var request = URLRequest(url: GitHubQueries.endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("GitWatch/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")", forHTTPHeaderField: "User-Agent")

        let payload: [String: Any] = ["query": query, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200...299:
                    break
                case 401:
                    throw GitHubClientError.unauthorized
                case 403, 429:
                    throw GitHubClientError.rateLimited
                default:
                    throw GitHubClientError.api(["HTTP \(http.statusCode)"])
                }
            }
            return data
        } catch let error as GitHubClientError {
            throw error
        } catch let urlError as URLError {
            if urlError.code == .cancelled || urlError.code == .badServerResponse {
                throw urlError
            }
            throw URLError(urlError.code)
        }
    }
}

final class GitHubClient {
    private let provider: GitHubAuthProvider
    private let transport: GitHubTransporting

    init(provider: GitHubAuthProvider, transport: GitHubTransporting = URLSessionGitHubTransport()) {
        self.provider = provider
        self.transport = transport
    }

    func fetchDashboard() async throws -> DashboardSnapshot {
        guard let token = provider.resolution.token else {
            throw GitHubClientError.unauthorized
        }
        let data = try await transport.post(GitHubQueries.dashboard, variables: ["first": "50"], token: token)
        return try Self.decodeDashboardResponse(data)
    }

    func approve(pullRequestID: String) async throws {
        try await runMutation(GitHubQueries.approve, variables: ["pullRequestId": pullRequestID])
    }

    func merge(pullRequestID: String, method: MergeMethod) async throws {
        try await runMutation(
            GitHubQueries.merge,
            variables: ["pullRequestId": pullRequestID, "method": method.graphqlName]
        )
    }

    private func runMutation(_ query: String, variables: [String: String]) async throws {
        guard let token = provider.resolution.token else {
            throw GitHubClientError.unauthorized
        }
        let data = try await transport.post(query, variables: variables, token: token)
        _ = try Self.assertNoErrors(data)
    }

    static func decodeDashboardResponse(_ data: Data) throws -> DashboardSnapshot {
        let envelope = try JSONDecoder().decode(DashboardEnvelope.self, from: data)
        try throwIfErrors(envelope.errors)
        guard let dataDict = envelope.data else {
            throw GitHubClientError.api(["Empty response"])
        }
        return dataDict.snapshot()
    }

    static func decodeMergeResponse(_ data: Data) throws -> Bool {
        struct Payload: Decodable {
            struct Inner: Decodable { let merged: Bool }
            let mergePullRequest: Inner
        }
        struct Envelope: Decodable {
            let errors: [GraphQLError]?
            let data: Payload?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        try throwIfErrors(envelope.errors)
        return envelope.data?.mergePullRequest.merged ?? false
    }

    private static func assertNoErrors(_ data: Data) throws -> Data {
        struct Envelope: Decodable { let errors: [GraphQLError]? }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        try throwIfErrors(envelope.errors)
        return data
    }

    private static func throwIfErrors(_ errors: [GraphQLError]?) throws {
        guard let messages = errors?.map(\.message), messages.isEmpty == false else { return }
        if messages.contains(where: { $0.lowercased().contains("rate limit") }) {
            throw GitHubClientError.rateLimited
        }
        throw GitHubClientError.api(messages)
    }
}

struct GraphQLError: Decodable {
    let message: String
}

private struct DashboardEnvelope: Decodable {
    let errors: [GraphQLError]?
    let data: DashboardData?
}

private struct DashboardData: Decodable {
    struct Viewer: Decodable { let login: String }
    struct SearchConnection: Decodable {
        let nodes: [PullRequestNode]
    }
    let viewer: Viewer
    let authored: SearchConnection
    let reviewRequested: SearchConnection

    struct PullRequestNode: Decodable {
        struct Author: Decodable { let login: String }
        struct Repo: Decodable { let nameWithOwner: String }
        struct Commits: Decodable {
            struct CommitNode: Decodable {
                struct Commit: Decodable {
                    struct Rollup: Decodable {
                        struct Contexts: Decodable {
                            struct ContextNode: Decodable {
                                struct CodingDataBase: Decodable {}
                                let typename: String
                                let conclusion: String?
                                let status: String?
                                let state: String?

                                private enum CodingKeys: String, CodingKey {
                                    case typename = "__typename"
                                    case conclusion, status, state
                                }
                            }
                            let totalCount: Int
                            let nodes: [ContextNode]
                        }
                        let contexts: Contexts
                    }
                    let statusCheckRollup: Rollup?
                }
                let commit: Commit
            }
            let nodes: [CommitNode]
        }

        let id: String
        let number: Int
        let title: String
        let url: URL
        let createdAt: Date
        let author: Author
        let repository: Repo
        let reviewDecision: ReviewDecision?
        let mergeableRaw: String?
        let mergeStateStatus: MergeStateStatus
        let viewerPermission: ViewerPermission
        let commits: Commits?

        private enum CodingKeys: String, CodingKey {
            case id, number, title, url, createdAt, author, repository, commits
            case reviewDecision
            case mergeableRaw = "mergeable"
            case mergeStateStatus, viewerPermission
        }
    }

    func snapshot() -> DashboardSnapshot {
        func summarize(_ node: PullRequestNode) -> PullRequestSummary {
            var checks: [CheckStatusDot] = []
            for context in node.commits?.nodes.first?.commit.statusCheckRollup?.contexts.nodes ?? [] {
                let outcome: CheckOutcome
                switch context.typename {
                case "CheckRun":
                    switch (context.status, context.conclusion) {
                    case ("COMPLETED", "SUCCESS"):
                        outcome = .success
                    case ("COMPLETED", .some(let conclusion)) where conclusion != "SUCCESS":
                        outcome = .failure
                    default:
                        outcome = .pending
                    }
                case "StatusContext":
                    switch context.state {
                    case "SUCCESS": outcome = .success
                    case "FAILURE", "ERROR": outcome = .failure
                    default: outcome = .pending
                    }
                default:
                    outcome = .pending
                }
                checks.append(CheckStatusDot(outcome: outcome))
            }
            return PullRequestSummary(
                id: node.id,
                number: node.number,
                title: node.title,
                repositoryNameWithOwner: node.repository.nameWithOwner,
                url: node.url,
                authorLogin: node.author.login,
                createdAt: node.createdAt,
                reviewDecision: node.reviewDecision,
                mergeable: node.mergeableRaw == "MERGEABLE",
                mergeStateStatus: node.mergeStateStatus,
                viewerPermission: node.viewerPermission,
                checks: checks
            )
        }

        return DashboardSnapshot(
            viewerLogin: viewer.login,
            authored: authored.nodes.map(summarize),
            reviewRequested: reviewRequested.nodes.map(summarize)
        )
    }
}
```

The final file ends after `snapshot()`. Configure date decoding inside `decodeDashboardResponse` by replacing the plain decode line with a configured decoder:

```swift
    static func decodeDashboardResponse(_ data: Data) throws -> DashboardSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = Self.isoFractional.date(from: raw) ?? Self.isoSeconds.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unparseable date \(raw)")
        }
        let envelope = try decoder.decode(DashboardEnvelope.self, from: data)
        try throwIfErrors(envelope.errors)
        guard let dataDict = envelope.data else {
            throw GitHubClientError.api(["Empty response"])
        }
        return dataDict.snapshot()
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoSeconds = ISO8601DateFormatter()
```

- [ ] **Step 6: Run tests until green**

```bash
ruby scripts/add_files.rb Managers/PullRequestModels.swift Managers/GitHubQueries.swift Managers/GitHubClient.swift
xcodebuild test -project git-watch.xcodeproj -scheme git-watch -destination 'platform=macOS'
```

Expected: full suite green including all five new decoding tests.

- [ ] **Step 7: Live smoke test (manual)**

Temporarily add to the app target a tiny debug hook (e.g., call from AppDelegate on launch behind `#if DEBUG`):

```swift
#if DEBUG
        Task { @MainActor [weak self] in
            guard let self else { return }
            let settings = GitHubSettings()
            let provider = GitHubAuthProvider(settings: settings)
            provider.resolve()
            let client = GitHubClient(provider: provider)
            do {
                let snapshot = try await client.fetchDashboard()
                print("[GitWatch] viewer=\(snapshot.viewerLogin) authored=\(snapshot.authored.count) review=\(snapshot.reviewRequested.count)")
            } catch {
                print("[GitWatch] dashboard failed: \(error)")
            }
        }
#endif
```

Run the Debug app; confirm either a printed count line or an actionable error (`unauthorized` means your gh CLI lacks scopes — run `gh auth status`). Remove this block after verification.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Add GraphQL models, queries, and client with approve/merge mutations"
```
