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
              "repository": { "nameWithOwner": "Re-Jacky/pulse", "viewerPermission": "WRITE" },
              "reviewDecision": "CHANGES_REQUESTED",
              "mergeable": "CONFLICTING",
              "mergeStateStatus": "DIRTY",
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
              "repository": { "nameWithOwner": "acme/infra", "viewerPermission": "ADMIN" },
              "reviewDecision": "REVIEW_REQUIRED",
              "mergeable": "MERGEABLE",
              "mergeStateStatus": "CLEAN",
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
