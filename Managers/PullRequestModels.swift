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
