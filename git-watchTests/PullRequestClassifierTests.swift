import XCTest
@testable import git_watch

final class PullRequestClassifierTests: XCTestCase {
    private func summary(
        id: String,
        daysAgo: Int = 1,
        state: MergeStateStatus = .blocked,
        permission: ViewerPermission = .read,
        mergeable: Bool = false,
        reviewDecision: ReviewDecision? = nil
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            number: 1,
            title: "t",
            repositoryNameWithOwner: "o/r",
            url: URL(string: "https://github.com/o/r/pull/1")!,
            authorLogin: "someone",
            createdAt: Date(timeIntervalSinceNow: -Double(daysAgo) * 86400),
            reviewDecision: reviewDecision,
            mergeable: mergeable,
            mergeStateStatus: state,
            viewerPermission: permission,
            checks: []
        )
    }

    func testAuthoredPRsAlwaysLandInMine() {
        let green = summary(id: "a", state: .clean, permission: .write, mergeable: true)
        let groupings = PullRequestClassifier.group(authored: [green], reviewRequested: [green])
        XCTAssertEqual(groupings.mine.map(\.id), ["a"])
        XCTAssertTrue(groupings.waitingMyReview.isEmpty)
        XCTAssertTrue(groupings.readyToMerge.isEmpty)
    }

    func testGreenNonMineWithWritePermissionIsReadyToMerge() {
        let green = summary(id: "b", state: .clean, permission: .write, mergeable: true)
        let groupings = PullRequestClassifier.group(authored: [], reviewRequested: [green])
        XCTAssertTrue(groupings.mine.isEmpty)
        XCTAssertTrue(groupings.waitingMyReview.isEmpty)
        XCTAssertEqual(groupings.readyToMerge.map(\.id), ["b"])
    }

    func testHasHooksCountsAsMergable() {
        let hooks = summary(id: "c", state: .hasHooks, permission: .admin, mergeable: true)
        let result = PullRequestClassifier.group(authored: [], reviewRequested: [hooks])
        XCTAssertEqual(result.readyToMerge.count, 1)
    }

    func testUnmergeableStaysInWaitingRegardlessOfState() {
        let blocked = summary(id: "d", daysAgo: 1, state: .blocked, permission: .write, mergeable: false)
        let behind = summary(id: "e", daysAgo: 2, state: .behind, permission: .maintain, mergeable: false)
        let result = PullRequestClassifier.group(authored: [], reviewRequested: [blocked, behind])
        XCTAssertEqual(result.waitingMyReview.map(\.id), ["d", "e"])
        XCTAssertTrue(result.readyToMerge.isEmpty)
    }

    func testMergeablePRReadyRegardlessOfMergeStateStatus() {
        let unstable = summary(id: "u", state: .unstable, permission: .maintain, mergeable: true)
        let blocked = summary(id: "b2", state: .blocked, permission: .write, mergeable: true)
        let behind = summary(id: "b3", state: .behind, permission: .admin, mergeable: true)
        let result = PullRequestClassifier.group(authored: [], reviewRequested: [unstable, blocked, behind])
        XCTAssertEqual(Set(result.readyToMerge.map(\.id)), ["u", "b2", "b3"])
        XCTAssertTrue(result.waitingMyReview.isEmpty)
    }

    func testReadOnlyPermissionNeverReadyToMerge() {
        let green = summary(id: "f", state: .clean, permission: .read, mergeable: true)
        let unknown = summary(id: "g", state: .clean, permission: .unknown, mergeable: true)
        let result = PullRequestClassifier.group(authored: [], reviewRequested: [green, unknown])
        XCTAssertEqual(result.waitingMyReview.count, 2)
        XCTAssertTrue(result.readyToMerge.isEmpty)
    }

    func testConflictingPRNotReadyEvenWithPermission() {
        let dirty = summary(id: "h", state: .clean, permission: .admin, mergeable: false)
        let result = PullRequestClassifier.group(authored: [], reviewRequested: [dirty])
        XCTAssertEqual(result.waitingMyReview.count, 1)
    }

    func testOverlappingIDsDeduplicateAgainstMine() {
        let mine = summary(id: "x", state: .clean, permission: .write, mergeable: true)
        let other = summary(id: "y", state: .blocked, permission: .read)
        let result = PullRequestClassifier.group(authored: [mine], reviewRequested: [mine, other])
        XCTAssertEqual(result.mine.map(\.id), ["x"])
        XCTAssertEqual(result.waitingMyReview.map(\.id), ["y"])
        XCTAssertTrue(result.readyToMerge.isEmpty)
    }

    func testAllListsSortedNewestFirst() {
        let old = summary(id: "old", daysAgo: 5)
        let mid = summary(id: "mid", daysAgo: 2)
        let new = summary(id: "new", daysAgo: 0)
        let result = PullRequestClassifier.group(
            authored: [old, new, mid].shuffled(),
            reviewRequested: []
        )
        XCTAssertEqual(result.mine.map(\.id), ["new", "mid", "old"])
    }

    func testPendingReviewMergeableStaysInWaiting() {
        let pending = summary(id: "p", state: .clean, permission: .write, mergeable: true, reviewDecision: .reviewRequired)
        let result = PullRequestClassifier.group(authored: [], reviewRequested: [pending])
        XCTAssertEqual(result.waitingMyReview.map(\.id), ["p"])
        XCTAssertTrue(result.readyToMerge.isEmpty)
    }

    func testChangesRequestedMergeableStaysInWaiting() {
        let changes = summary(id: "c", state: .clean, permission: .write, mergeable: true, reviewDecision: .changesRequested)
        let result = PullRequestClassifier.group(authored: [], reviewRequested: [changes])
        XCTAssertEqual(result.waitingMyReview.map(\.id), ["c"])
        XCTAssertTrue(result.readyToMerge.isEmpty)
    }

    func testApprovedMergeableIsReadyToMerge() {
        let approved = summary(id: "a", state: .clean, permission: .write, mergeable: true, reviewDecision: .approved)
        let result = PullRequestClassifier.group(authored: [], reviewRequested: [approved])
        XCTAssertEqual(result.readyToMerge.map(\.id), ["a"])
        XCTAssertTrue(result.waitingMyReview.isEmpty)
    }

    func testNoReviewDecisionMergeableIsReadyToMerge() {
        let none = summary(id: "n", state: .clean, permission: .write, mergeable: true, reviewDecision: nil)
        let result = PullRequestClassifier.group(authored: [], reviewRequested: [none])
        XCTAssertEqual(result.readyToMerge.map(\.id), ["n"])
        XCTAssertTrue(result.waitingMyReview.isEmpty)
    }
}
