# Task 5: PR classification into groupings (TDD)

**Files:**
- Modify: `Managers/PullRequestModels.swift` (append classifier)
- Test: `git-watchTests/PullRequestClassifierTests.swift`

**Interfaces:**
- Consumes: `PullRequestSummary.canMerge` (Task 4)
- Produces (final per master plan): `PRGroupings` struct, `PullRequestClassifier.group(authored:reviewRequested:)`. Task 6's store calls exactly `PullRequestClassifier.group(authored:snapshot.authored, reviewRequested:snapshot.reviewRequested)`.

**Classification rules (from spec):**
- `mine` = everything from the authored search
- non-mine = reviewRequested entries whose id is not in authored ids
- `readyToMerge` = non-mine where `canMerge == true`
- `waitingMyReview` = non-mine where `canMerge == false`
- All lists sorted by `createdAt`, newest first; merged/closed can never appear because both searches filter `is:open`

- [ ] **Step 1: Write the failing tests**

Create `git-watchTests/PullRequestClassifierTests.swift`:

```swift
import XCTest
@testable import git_watch

final class PullRequestClassifierTests: XCTestCase {
    private func summary(
        id: String,
        daysAgo: Int = 1,
        state: MergeStateStatus = .blocked,
        permission: ViewerPermission = .read,
        mergeable: Bool = false
    ) -> PullRequestSummary {
        PullRequestSummary(
            id: id,
            number: 1,
            title: "t",
            repositoryNameWithOwner: "o/r",
            url: URL(string: "https://github.com/o/r/pull/1")!,
            authorLogin: "someone",
            createdAt: Date(timeIntervalSinceNow: -Double(daysAgo) * 86400),
            reviewDecision: nil,
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

    func testBlockedOrBehindStaysInWaiting() {
        let blocked = summary(id: "d", state: .blocked, permission: .write, mergeable: true)
        let behind = summary(id: "e", state: .behind, permission: .maintain, mergeable: true)
        let result = PullRequestClassifier.group(authored: [], reviewRequested: [blocked, behind])
        XCTAssertEqual(result.waitingMyReview.map(\.id), ["d", "e"])
        XCTAssertTrue(result.readyToMerge.isEmpty)
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
}
```

- [ ] **Step 2: Run to verify failure**

```bash
ruby scripts/add_files.rb git-watchTests/PullRequestClassifierTests.swift
xcodebuild test -project git-watch.xcodeproj -scheme git-watch -destination 'platform=macOS' -only-testing:git-watchTests/PullRequestClassifierTests 2>&1 | tail -5
```

Expected: compile error — `PRGroupings` / `PullRequestClassifier` missing.

- [ ] **Step 3: Implement — append to `Managers/PullRequestModels.swift`**

```swift
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
```

- [ ] **Step 4: Run tests until green**

```bash
xcodebuild test -project git-watch.xcodeproj -scheme git-watch -destination 'platform=macOS'
```

Expected: full suite green including all eight classification tests.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add PR grouping classifier with merge-readiness rules"
```
