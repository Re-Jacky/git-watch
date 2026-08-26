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

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .unknown
            return
        }
        let raw = try container.decode(String.self)
        self = MergeStateStatus(rawValue: raw) ?? .unknown
    }
}

enum ViewerPermission: String, Codable {
    case admin = "ADMIN"
    case maintain = "MAINTAIN"
    case write = "WRITE"
    case read = "READ"
    case unknown = "UNKNOWN"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .unknown
            return
        }
        let raw = try container.decode(String.self)
        self = ViewerPermission(rawValue: raw) ?? .unknown
    }
}

enum CheckOutcome: String {
    case success
    case failure
    case pending
}

struct CheckStatusDot: Equatable {
    let outcome: CheckOutcome
}

struct DashboardSnapshot: Equatable {
    let viewerLogin: String
    let authored: [PullRequestSummary]
    let reviewRequested: [PullRequestSummary]
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

struct PRGroupings: Equatable {
    let mine: [PullRequestSummary]
    let waitingMyReview: [PullRequestSummary]
    let readyToMerge: [PullRequestSummary]

    var actionableCount: Int {
        waitingMyReview.count + readyToMerge.count
    }
}

enum PullRequestClassifier {
    static func group(
        authored: [PullRequestSummary],
        reviewRequested: [PullRequestSummary]
    ) -> PRGroupings {
        let sortedMine = authored.sorted { $0.createdAt > $1.createdAt }
        let authoredIDs = Set(authored.map(\.id))
        let nonMine = reviewRequested
            .filter { authoredIDs.contains($0.id) == false }
            .sorted { $0.createdAt > $1.createdAt }
        return PRGroupings(
            mine: sortedMine,
            waitingMyReview: nonMine.filter { $0.canMerge == false },
            readyToMerge: nonMine.filter { $0.canMerge }
        )
    }
}
