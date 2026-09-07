import XCTest
@testable import git_watch

final class GitHubAuthTestsTests: XCTestCase {
    @MainActor
    func testMergeMethodDefaultsToMergeCommit() {
        let settings = GitHubSettings(userDefaults: UserDefaultsFactory.make())
        XCTAssertEqual(settings.mergeMethod, .merge)
    }

    @MainActor
    func testPersonalAccessTokenPersistsAndRoundTrips() {
        let defaults = UserDefaultsFactory.make()
        let settings = GitHubSettings(userDefaults: defaults)
        settings.personalAccessToken = "ghp_abc123"
        let reloaded = GitHubSettings(userDefaults: defaults)
        XCTAssertEqual(reloaded.personalAccessToken, "ghp_abc123")
    }

    @MainActor
    func testDeleteBranchAfterMergeDefaultsToChecked() {
        let settings = GitHubSettings(userDefaults: UserDefaultsFactory.make())
        XCTAssertTrue(settings.deleteBranchAfterMerge)
    }

    @MainActor
    func testDeleteBranchAfterMergePersists() {
        let defaults = UserDefaultsFactory.make()
        let settings = GitHubSettings(userDefaults: defaults)
        settings.deleteBranchAfterMerge = false
        let reloaded = GitHubSettings(userDefaults: defaults)
        XCTAssertFalse(reloaded.deleteBranchAfterMerge)
    }

    @MainActor
    func testMergeMethodPersistsAndRawValuesMatchGraphQLNames() {
        let defaults = UserDefaultsFactory.make()
        let settings = GitHubSettings(userDefaults: defaults)
        settings.mergeMethod = .squash
        let reloaded = GitHubSettings(userDefaults: defaults)
        XCTAssertEqual(reloaded.mergeMethod, .squash)
        XCTAssertEqual(MergeMethod.merge.graphqlName, "MERGE")
        XCTAssertEqual(MergeMethod.squash.graphqlName, "SQUASH")
        XCTAssertEqual(MergeMethod.rebase.graphqlName, "REBASE")
    }

    func testTokenResolutionPrefersPATOverGHCLI() async {
        let fake = FakeGHCLI()
        fake.stubbedToken = "cli-token"
        let provider = GitHubAuthProvider(
            settings: GitHubSettings(
                personalAccessToken: "pat-token",
                ghCLI: fake,
                userDefaults: UserDefaultsFactory.make()
            ),
            ghCLI: fake
        )
        await MainActor.run { provider.resolve() }
        let resolution = await MainActor.run { provider.resolution }
        XCTAssertEqual(resolution, .patOverride("pat-token"))
        XCTAssertEqual(resolution.token, "pat-token")
    }

    func testTokenResolutionFallsBackToGHCLI() async {
        let fake = FakeGHCLI()
        fake.stubbedToken = "cli-token"
        let provider = GitHubAuthProvider(
            settings: GitHubSettings(
                personalAccessToken: "",
                ghCLI: fake,
                userDefaults: UserDefaultsFactory.make()
            ),
            ghCLI: fake
        )
        await MainActor.run { provider.resolve() }
        let resolution = await MainActor.run { provider.resolution }
        XCTAssertEqual(resolution, .ghCLI("cli-token"))
    }

    func testTokenResolutionNoneWhenBothMissing() async {
        let fake = FakeGHCLI()
        fake.stubbedToken = nil
        let provider = GitHubAuthProvider(
            settings: GitHubSettings(
                personalAccessToken: "",
                ghCLI: fake,
                userDefaults: UserDefaultsFactory.make()
            ),
            ghCLI: fake
        )
        await MainActor.run { provider.resolve() }
        let resolution = await MainActor.run { provider.resolution }
        XCTAssertNil(resolution.token)
        XCTAssertEqual(resolution, .none)
    }

    func testGhCLILocatesHomebrewBinaryOrReturnsNil() {
        let cli = GhCLI()
        let token = cli.authToken()
        XCTAssertTrue(token == nil || token?.isEmpty == false)
    }
}
