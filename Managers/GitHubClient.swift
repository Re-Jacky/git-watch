import Foundation

enum GitHubClientError: Error, Equatable {
    case unauthorized
    case rateLimited
    case api([String])
}

protocol GitHubTransporting {
    func post(_ query: String, variables: [String: Any], token: String) async throws -> Data
}

final class URLSessionGitHubTransport: GitHubTransporting {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func post(_ query: String, variables: [String: Any], token: String) async throws -> Data {
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

    var isAuthenticated: Bool {
        provider.resolution.token != nil
    }

    init(provider: GitHubAuthProvider, transport: GitHubTransporting = URLSessionGitHubTransport()) {
        self.provider = provider
        self.transport = transport
    }

    func fetchDashboard() async throws -> DashboardSnapshot {
        guard let token = provider.resolution.token else {
            throw GitHubClientError.unauthorized
        }
        let data = try await transport.post(GitHubQueries.dashboard, variables: ["first": 50], token: token)
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

    private func runMutation(_ query: String, variables: [String: Any]) async throws {
        guard let token = provider.resolution.token else {
            throw GitHubClientError.unauthorized
        }
        let data = try await transport.post(query, variables: variables, token: token)
        _ = try Self.assertNoErrors(data)
    }

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

    static func decodeMergeResponse(_ data: Data) throws -> Bool {
        struct Payload: Decodable {
            struct Inner: Decodable { let merged: Bool }
            struct Merge: Decodable { let pullRequest: Inner? }
            let mergePullRequest: Merge
        }
        struct Envelope: Decodable {
            let errors: [GraphQLError]?
            let data: Payload?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        try throwIfErrors(envelope.errors)
        return envelope.data?.mergePullRequest.pullRequest?.merged ?? false
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
        struct Repo: Decodable { let nameWithOwner: String; let viewerPermission: ViewerPermission }
        struct Commits: Decodable {
            struct CommitNode: Decodable {
                struct Commit: Decodable {
                    struct Rollup: Decodable {
                        struct Contexts: Decodable {
                            struct ContextNode: Decodable {
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
        let reviewDecision: LenientReviewDecision?
        let mergeableRaw: String?
        let mergeStateStatus: MergeStateStatus
        let commits: Commits?

        private enum CodingKeys: String, CodingKey {
            case id, number, title, url, createdAt, author, repository, commits
            case reviewDecision
            case mergeableRaw = "mergeable"
            case mergeStateStatus
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
                reviewDecision: node.reviewDecision?.value,
                mergeable: node.mergeableRaw == "MERGEABLE",
                mergeStateStatus: node.mergeStateStatus,
                viewerPermission: node.repository.viewerPermission,
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
