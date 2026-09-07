# AGENTS.md — git-watch

macOS 14+ menu bar app in Swift 5.9+ (`LSUIElement = true`, Dock-less). AppKit entrypoint is `App/main.swift` → `AppDelegate`. Targets: `git-watch`, `GitWatchUpdater`, `git-watchTests`. Zero external runtime dependencies.

## Build & Verify

- `xcodebuild -project git-watch.xcodeproj -scheme git-watch -configuration Debug build`
- `xcodebuild test -project git-watch.xcodeproj -scheme git-watch -destination 'platform=macOS'`
- Regenerate project after adding files: edit sources on disk, then `ruby scripts/add_files.rb <paths>` (requires the ruby `xcodeproj` gem); full regen via `ruby scripts/create_project.rb` (destructive — deletes and recreates the project file, but preserves `MARKETING_VERSION` from the existing project)
- Release packaging: `bash build-dmg.sh` → `dist/GitWatch-<version>.dmg` + updater zip; the updater zip checksum is emitted as a `sha256:` stdout line (+ `.sha256` sidecar) that CI appends to release notes and the update client parses.
- CI: `.github/workflows/release.yml` — triggers automatically on push to `main` touching `project.pbxproj` (or the workflow itself), plus manual dispatch; publishes from `MARKETING_VERSION` and fails if the tag already exists

## Architecture That Matters

- `AppDelegate` owns the status item (+ badge controller), the resizable `InputPanel`, the settings window, theme observation, token provider, PR store, and updater wiring
- The panel is not an `NSPopover`; it is a borderless `NSPanel` with rounded corners, outside-click dismissal, temporary `.regular` activation while opening settings
- Tab content stays mounted behind `.opacity` + `.allowsHitTesting`; use the `gitwatchPanelDidOpen` notification for refresh-on-open behavior, never `onAppear`
- Footer is pinned structurally (`VStack` last child) — do not wrap it in scroll content
- `PullRequestStore` is the single source of truth for PR lists, connection status, badge count, and action errors
- Badge counts `totalCount` (all live PRs: mine + review + merge); dismissed PRs (persisted under `github.dismissedPRIds`) are filtered at publish time and excluded from every list and count; Settings → GitHub restores them
- Classification lives only in `PullRequestClassifier`: ready-to-merge requires `viewerPermission ∈ {WRITE, MAINTAIN, ADMIN}` AND `mergeable == MERGEABLE` (GitHub's authoritative mergeable flag); `mergeStateStatus` is display-only and never gates actions, matching github.com across repos with different checklists
- Mine tab offers Merge in place via `PullRequestStore.canOfferMergeForMine` (`summary.canMerge`, no approval gate since authors can't approve own PRs); Review tab still uses `canOfferMergeInPlace` (approved + `canMerge`) and `shouldOfferApprove`
- v1 scope limit: PRs come solely from the two dashboard searches (authored / review-requested); teammate PRs you are neither author nor requested reviewer of are invisible by design
- `GitHubClient.isAuthenticated` exists as an internal read-only accessor derived from provider.resolution (added Task 6 for no-token detection without network calls)
- `.gitwatchPanelTabDidChange` posts Int as notification object — observers cast `object as? Int`

## Token Handling

- Resolution order: Settings PAT override → `gh auth token` (homebrew paths first) → none; implemented in `GitHubAuthProvider.resolve()`
- No Keychain; tokens live in UserDefaults (same plaintext posture as gh's hosts.yml)
- HTTP 401 → `.tokenRejected`; 403/429 or "rate limit" message → `.rateLimited`

## Repo-Specific Conventions

- Semantic colors from `Views/Colors.swift`; the only exceptions are the four GitHub status colors (`appStatusSuccess/Failure/Pending/Merged`, the last matching github.com's merged purple `8957E5`) defined there as hex constants
- Do not add comments to code
- Merge method default is `.merge` (matches github.com); persisted under `github.mergeMethod`
- Delete head branch after merge defaults to on (checked); persisted under `github.deleteBranchAfterMerge`; `PullRequestStore.merge` runs it as a best-effort REST `DELETE /repos/{owner}/{repo}/git/refs/heads/{branch}` after a successful merge (manual + auto), using `headRefName` / head repo from the dashboard query — merge still counts if delete fails, the error is shown inline
- Refresh interval is a fixed 300 s constant passed to `startAutomaticRefresh` — do not expose it in Settings without updating the spec
- Auto Mode (`github.autoModeEnabled` master switch; scopes `github.autoApprove` default true, `github.autoMerge` default false): store processes approve (waiting bucket, any CI state, re-approving after stale dismissals) and merge (ready bucket) per enabled scope at the tail of every `refresh(force:)` and immediately on enable via the settings sink; `isAutoProcessing` guards re-entry — do not call `processAutoActions()` from inside `performRefresh()`
- Auto-approved history rows show a `Merged` chip once GitHub reports the PR merged: `PullRequestStore.mergedHistoryIDs` (in-memory, intersected with history IDs) refreshes via the `HistoryStates` `nodes(ids:)` query on every live `refresh(force:)`; failures keep the previous set and an empty history skips the call
