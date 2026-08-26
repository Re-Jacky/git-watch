# AGENTS.md — git-watch

macOS 14+ menu bar app in Swift 5.9+ (`LSUIElement = true`, Dock-less). AppKit entrypoint is `App/main.swift` → `AppDelegate`. Targets: `git-watch`, `GitWatchUpdater`, `git-watchTests`. Zero external runtime dependencies.

## Build & Verify

- `xcodebuild -project git-watch.xcodeproj -scheme git-watch -configuration Debug build`
- `xcodebuild test -project git-watch.xcodeproj -scheme git-watch -destination 'platform=macOS'`
- Regenerate project after adding files: edit sources on disk, then `ruby scripts/add_files.rb <paths>` (requires the ruby `xcodeproj` gem); full regen via `ruby scripts/create_project.rb` (destructive — deletes and recreates the project file)
- Release packaging: `bash build-dmg.sh` → `dist/GitWatch-<version>.dmg` + updater zip
- CI: `.github/workflows/release.yml` manual dispatch keyed off `MARKETING_VERSION`

## Architecture That Matters

- `AppDelegate` owns the status item (+ badge controller), the resizable `InputPanel`, the settings window, theme observation, token provider, PR store, and updater wiring
- The panel is not an `NSPopover`; it is a borderless `NSPanel` with rounded corners, outside-click dismissal, temporary `.regular` activation while opening settings
- Tab content stays mounted behind `.opacity` + `.allowsHitTesting`; use the `gitwatchPanelDidOpen` notification for refresh-on-open behavior, never `onAppear`
- Footer is pinned structurally (`VStack` last child) — do not wrap it in scroll content
- `PullRequestStore` is the single source of truth for PR lists, connection status, badge count, and action errors
- Classification lives only in `PullRequestClassifier`: ready-to-merge requires `mergeStateStatus ∈ {CLEAN, HAS_HOOKS}` AND `viewerPermission ∈ {WRITE, MAINTAIN, ADMIN}` AND `mergeable == MERGEABLE`
- v1 scope limit: ready-to-merge candidates come solely from the two dashboard searches (authored / review-requested); teammate PRs you are neither author nor requested reviewer of are invisible by design
- `GitHubClient.isAuthenticated` exists as an internal read-only accessor derived from provider.resolution (added Task 6 for no-token detection without network calls)
- `.gitwatchPanelTabDidChange` posts Int as notification object — observers cast `object as? Int`

## Token Handling

- Resolution order: Settings PAT override → `gh auth token` (homebrew paths first) → none; implemented in `GitHubAuthProvider.resolve()`
- No Keychain; tokens live in UserDefaults (same plaintext posture as gh's hosts.yml)
- HTTP 401 → `.tokenRejected`; 403/429 or "rate limit" message → `.rateLimited`

## Repo-Specific Conventions

- Semantic colors from `Views/Colors.swift`; the only exceptions are the three GitHub status colors (`appStatusSuccess/Failure/Pending`) defined there as hex constants
- Do not add comments to code
- Merge method default is `.merge` (matches github.com); persisted under `github.mergeMethod`
- Refresh interval is a fixed 300 s constant passed to `startAutomaticRefresh` — do not expose it in Settings without updating the spec
