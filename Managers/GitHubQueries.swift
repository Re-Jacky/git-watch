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
      repository { nameWithOwner viewerPermission }
      reviewDecision
      mergeable
      mergeStateStatus
      headRefName
      headRepository { nameWithOwner }
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

    static let historyStates = """
    query HistoryStates($ids: [ID!]!) {
      nodes(ids: $ids) {
        ... on PullRequest { id merged }
      }
    }
    """
}
