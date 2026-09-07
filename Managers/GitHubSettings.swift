import Combine
import Foundation

enum MergeMethod: String, CaseIterable, Identifiable {
    case merge
    case squash
    case rebase

    var id: String { rawValue }

    var label: String {
        switch self {
        case .merge: return "Merge Commit"
        case .squash: return "Squash"
        case .rebase: return "Rebase"
        }
    }

    var graphqlName: String {
        switch self {
        case .merge: return "MERGE"
        case .squash: return "SQUASH"
        case .rebase: return "REBASE"
        }
    }
}

final class GitHubSettings: ObservableObject {
    static let patKey = "github.personalAccessToken"
    static let mergeMethodKey = "github.mergeMethod"
    static let deleteBranchAfterMergeKey = "github.deleteBranchAfterMerge"
    static let autoModeKey = "github.autoModeEnabled"
    static let autoApproveKey = "github.autoApprove"
    static let autoMergeKey = "github.autoMerge"
    static let whitelistedAuthorsKey = "github.whitelistedAuthors"

    @Published var personalAccessToken: String {
        didSet { userDefaults.set(personalAccessToken, forKey: Self.patKey) }
    }

    @Published var mergeMethod: MergeMethod {
        didSet { userDefaults.set(mergeMethod.rawValue, forKey: Self.mergeMethodKey) }
    }

    @Published var deleteBranchAfterMerge: Bool {
        didSet { userDefaults.set(deleteBranchAfterMerge, forKey: Self.deleteBranchAfterMergeKey) }
    }

    @Published var autoModeEnabled: Bool {
        didSet { userDefaults.set(autoModeEnabled, forKey: Self.autoModeKey) }
    }

    @Published var autoApproveEnabled: Bool {
        didSet { userDefaults.set(autoApproveEnabled, forKey: Self.autoApproveKey) }
    }

    @Published var autoMergeEnabled: Bool {
        didSet { userDefaults.set(autoMergeEnabled, forKey: Self.autoMergeKey) }
    }

    @Published var whitelistedAuthors: String {
        didSet { userDefaults.set(whitelistedAuthors, forKey: Self.whitelistedAuthorsKey) }
    }

    private let userDefaults: UserDefaults
    private let ghCLI: GHCLIRunning

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.ghCLI = GhCLI()
        self.personalAccessToken = userDefaults.string(forKey: Self.patKey) ?? ""
        let raw = userDefaults.string(forKey: Self.mergeMethodKey)
        self.mergeMethod = raw.flatMap(MergeMethod.init(rawValue:)) ?? .merge
        self.deleteBranchAfterMerge = userDefaults.object(forKey: Self.deleteBranchAfterMergeKey) as? Bool ?? true
        self.autoModeEnabled = userDefaults.bool(forKey: Self.autoModeKey)
        self.autoApproveEnabled = userDefaults.object(forKey: Self.autoApproveKey) as? Bool ?? true
        self.autoMergeEnabled = userDefaults.bool(forKey: Self.autoMergeKey)
        self.whitelistedAuthors = userDefaults.string(forKey: Self.whitelistedAuthorsKey) ?? ""
    }

    init(personalAccessToken: String, ghCLI: GHCLIRunning, userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        self.ghCLI = ghCLI
        self.personalAccessToken = personalAccessToken
        self.mergeMethod = .merge
        self.deleteBranchAfterMerge = true
        self.autoModeEnabled = false
        self.autoApproveEnabled = true
        self.autoMergeEnabled = false
        self.whitelistedAuthors = ""
    }
}
