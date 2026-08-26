# GitWatch — Design Specification

**Date:** 2026-08-26
**Status:** Draft — sections added as approved during brainstorming
**Source inspiration:** `/Users/zyao/Desktop/pulse` (infrastructure reused 1:1)

---

## Overview

GitWatch is a macOS menu bar application that surfaces a developer's pending GitHub pull requests and enables one-click approve/merge actions. It reuses Pulse's complete app infrastructure — status item, resizable frosted-glass panel, theme system, settings window, launch-at-login, auto-update pipeline, DMG packaging, and CI release workflow — with an entirely different purpose: GitHub PR monitoring instead of system monitoring.

### Requirements (agreed during brainstorming)

1. Display all my open PRs across every accessible repository ("All my PRs everywhere").
2. Show live PR status: CI checks, review decision, mergeability.
3. Two display tabs: **Mine** (authored by me) and **Review & Merge** — the latter groups **Waiting for your review** (review requested from me) and **Ready for you to merge** (green PRs I have permission to merge) into labeled sections.
4. Quick actions: inline **Approve** button on review rows, inline **Merge** button on merge rows (separate buttons, not combined).
5. Only **live** PRs are shown — merged or closed PRs never appear in any list.
5. Authentication: **gh CLI token primary**, manual PAT fallback entered in Settings.
6. Refresh: every 5 minutes automatically, on panel open, and via manual refresh button.
7. Menu bar badge showing count of actionable PRs (Review + Merge).

---

## Section 1: Architecture & Components *(approved)*

**Identity:** App name **GitWatch**, menu bar accessory (`LSUIElement=true`), macOS 14+, Swift 5.9+, zero external dependencies (Apple frameworks only). Targets: `git-watch` (app), `gitwatchUpdater` (update helper), `git-watchTests`.

### Directory layout (mirrors Pulse)

```
git-watch/
├── App/
│   ├── main.swift                    # AppKit entry point
│   └── AppDelegate.swift             # Status item, InputPanel, settings window, context menu
├── Managers/
│   ├── ThemeManager.swift            # copied verbatim (System/Dark/Light)
│   ├── LaunchAtLoginSettings.swift   # copied verbatim (SMAppService)
│   ├── AppVersionInfo.swift          # copied verbatim
│   ├── UpdateManager.swift           # copied, helper path renamed to GitWatchUpdater.app
│   ├── UpdateModels.swift            # copied
│   ├── UpdateInstallPlanner.swift    # copied
│   ├── UpdateGitHubClient.swift      # copied, repo constants changed
│   ├── GitHubSettings.swift          # NEW: ObservableObject — personalAccessToken, mergeMethod;
│   │                                 #      persisted via UserDefaults (Pulse convention, no Keychain)
│   ├── GitHubAuth.swift              # NEW: token resolution — PAT from GitHubSettings → fallback `gh auth token`
│   ├── GitHubClient.swift            # NEW: URLSession GraphQL transport (protocol-injected for tests)
│   ├── GitHubQueries.swift           # NEW: GraphQL query/mutation strings
│   ├── PullRequestModels.swift       # NEW: Codable response types + view models
│   └── PullRequestStore.swift        # NEW: ObservableObject — 3 buckets, 5-min timer, badge count
├── Views/
│   ├── Colors.swift                  # semantic palette (Pulse pattern)
│   ├── PanelView.swift               # root: frosted glass, tab switcher (Mine / Review / Merge)
│   ├── PullRequestRowView.swift      # row: status indicators, action buttons
│   └── SettingsView.swift            # sidebar window: General / GitHub / Updates
├── gitwatchUpdater/                  # updater helper app (Pulse's pulseUpdater, renamed)
├── git-watchTests/
├── Info.plist                        # LSUIElement=true
├── scripts/build-dmg.sh              # hdiutil packaging (adapted from Pulse)
└── .github/workflows/release.yml     # MARKETING_VERSION-driven release (adapted from Pulse)
```

### AppDelegate shape

Identical responsibilities to Pulse's `AppDelegate`: owns the `NSStatusItem`, the pre-built custom `InputPanel` (borderless `NSPanel`, rounded corners, outside-click dismissal via global event monitor, activation-policy juggling between `.regular`/`.accessory`, theme applied to panel + windows), left-click toggles the panel, right-click shows context menu (Open/Close, Settings…, Quit).

### Data flow

1. On launch: resolve token (`GitHubSettings.personalAccessToken` → fallback `gh auth token`) → run **one combined GraphQL query** containing three aliased searches (`author:@me`, `review-requested:@me`) plus per-PR inline fields: `viewerPermission`, `mergeStateStatus`, `reviewDecision`, `statusCheckRollup`, `mergeable`.
2. `PullRequestStore` classifies results into **Mine**, **Waiting for your review**, and **Ready for you to merge** groupings (merged/closed PRs are dropped).
3. Badge count = review + merge actionable totals, rendered next to the menu bar icon.
4. Timer refresh every 5 minutes; refresh on panel open; manual refresh button in panel footer.
5. Actions:
   - **Approve** → GraphQL mutation `addPullRequestReview(event: APPROVE)`
   - **Merge** → GraphQL mutation `mergePullRequest(mergeMethod:)` with the merge method chosen in Settings (default: **merge commit**, matching GitHub's own UI; squash and rebase selectable; the app falls back to whatever method the repo allows)
   - Both trigger a store refresh after completion.

### Settings storage

All settings persist in `UserDefaults.standard` exactly as Pulse does (theme, launch-at-login, selected tab, PAT, merge method). No Keychain usage anywhere. This matches the security posture of `gh` itself, which stores its token in plaintext at `~/.config/gh/hosts.yml`.

---

## Section 2: UI Behavior *(approved)*

### Menu bar icon

SF Symbol `git.pullrequest` (template image). When actionable PR count > 0, the count renders beside the icon (e.g., `⇅ 3`). Left-click toggles the panel; right-click context menu: **Open/Close, Refresh, Settings…, Quit GitWatch**.

### Panel (Pulse InputPanel pattern)

Default 420×520, min 340×460, resizable, rounded corners, frosted glass (`NSVisualEffectView`), dismiss on outside click. Layout validated via visual-companion mockup session (`final-ui-mockup-v2.html`).

- **Header:** two-tab switcher **Mine** / **Review & Merge** with per-tab counts; selected tab persisted via `@AppStorage("selectedTab")`
- **Live only:** merged or closed PRs never appear; lists contain open PRs exclusively
- **Rows:** `repo#number`, title (2-line truncation), CI dot cluster (green/red/pending), review-state chip (`Approved` / `Changes requested` / `Pending`), relative age; clicking a row opens the PR URL in browser
- **Review & Merge tab layout (variant A):** two labeled sections — **"Waiting for your review"** rows carry an inline **Approve** button; **"Ready for you to merge"** rows carry an inline **Merge** button labeled with the configured method
- **Mine tab:** status display only, no action buttons
- **Footer — structurally pinned:** `VStack { header; list; Spacer(minLength: 0); footer }` keeps the footer at the bottom edge regardless of row count and while resizing; the list scrolls beneath it. Footer shows last-updated timestamp, manual refresh button, authenticated login (from `viewer { login }` in the same query)
- **Empty states:** Mine → "No open PRs authored by you"; Review & Merge → "Nothing is waiting on you"
- Action buttons disable with a spinner while their mutation is in flight; completion triggers a store refresh

## Section 3: Error Handling *(approved)*

| Case | Behavior |
|------|----------|
| No token found (no gh CLI, no PAT) | Panel shows setup instructions; badge hidden |
| Token rejected (HTTP 401) | Banner: "Token rejected — check Settings or run `gh auth login`" |
| Rate limited / offline | Banner shown + keep stale data with last-updated timestamp; automatic refresh backs off |
| Merge rejected (GraphQL `userErrors`, e.g. "Base branch was modified") | Inline error on the affected row; row remains until next refresh reflects new state |

## Section 4: Testing *(approved)*

XCTest target mirroring Pulse's test conventions: protocol-injected GraphQL transport, fixture JSON files, fake clock for timer tests.

Coverage:
- Bucket classification matrix (`mergeStateStatus` × `viewerPermission`)
- Token resolution order (PAT from GitHubSettings → gh CLI → nil)
- GraphQL response decoding against fixtures
- Store refresh lifecycle (5-min cadence, concurrent-refresh dedupe)
- Mutation error mapping (GraphQL `userErrors` → user-facing messages)
- Badge count derivation (Review + Merge totals)

## Section 5: Release Infra *(approved)*

- Versioning driven by `MARKETING_VERSION` in `git-watch.xcodeproj/project.pbxproj`
- `scripts/build-dmg.sh`: Release build → `dist/GitWatch-<version>.dmg` + `dist/GitWatch-<version>-updater.zip` (hdiutil only, no Homebrew)
- Updater helper bundled at `Contents/Helpers/GitWatchUpdater.app`
- `.github/workflows/release.yml`: manual dispatch — builds DMG, creates GitHub Release tagged `v<version>`, uploads both artifacts; fails if tag already exists

### Configuration values

| Value | Value |
|-------|-------|
| Repo slug | `Re-Jacky/git-watch` |
| Bundle identifier | `com.rejacky.gitwatch` |

---

## Self-Review Record

- Placeholder scan: clean — no TBD/TODO remaining.
- Consistency: tab/group names (Mine, Waiting for your review, Ready for you to merge) consistent across Overview, Section 1 data flow, and Section 2 UI; merge-method default (merge commit) consistent in Sections 1 and 2.
- Scope: single implementation plan sized.
- Ambiguity: refresh = 5 min fixed (not configurable in v1); badge counts review + merge actionable totals only; merged/closed PRs are never displayed.
- UI validated with the user via visual-companion mockups (v2): two tabs, grouped sections (variant A), pinned footer.

---

## Changelog

### 2026-08-26 — UI refinements (post-v1.0.0 feedback)

1. Menu bar glyph wrapped in a circular outline for visibility.
2. Panel header gains version label + update-status control (Pulse `ProductVersionHeaderView` pattern) overlaid on the tab row.
3. Settings GitHub sidebar icon changed to `key` — the previous symbol does not resolve on this OS build.
4. Menu bar badge counts **all live PRs involving you** (`totalCount` = Mine + Waiting-for-your-review + Ready-to-merge). Per-tab labels keep their own counts.
5. Per-PR **dismiss** (✕ on each row): hides the PR from every list and from all counts, persisted under `github.dismissedPRIds`; Settings → GitHub offers "Show Dismissed PRs (\(n))" to restore.

### 2026-08-26 — Auto Mode

Optional full automation toggle (`github.autoModeEnabled`, default off; Settings → GitHub or right-click menu "Auto Mode"):
- **Approve**: every PR in Waiting-for-your-review is approved automatically, regardless of CI state, including re-approval after an author pushes changes and a stale-review dismissal flips the PR back to review-required. Failed attempts surface as the row's inline error and retry on the next 5-minute cycle.
- **Merge**: every Ready-for-you-to-merge PR (already requires CLEAN/HAS_HOOKS + write permission + mergeable) is merged with the configured default method.
- Processing runs after every refresh cycle and immediately when toggled on. While active: menu bar badge renders as a solid accent-blue disc with knocked-out glyph and blue count; panel shows an info banner under the tabs describing the behavior.

### 2026-08-26 — Auto Mode scopes

Auto mode gains per-action scopes: `github.autoApprove` (default **on**) and `github.autoMerge` (default off), shown as checkboxes under the Auto Mode toggle in Settings → GitHub (visible only while the master toggle is on). The store's approve/merge phases each gate on their scope flag. The panel banner text adapts to the selected scopes; a warning appears in Settings when Auto is on with no scopes selected.

### 2026-08-26 — Post-approve row behavior

Approving a PR marks it locally approved (`locallyApprovedIDs`, in-memory): the Approve button disappears immediately (chip shows "Approved"), GitHub search-index lag notwithstanding. If the PR's data then satisfies merge conditions, the waiting row offers **Merge** in place; once GitHub reports it ready it moves to the Ready section normally. A delayed catch-up refresh (~4 s) after each successful approve compensates for search indexing lag. Flags clear when the PR leaves the dashboard or a fresh snapshot authoritatively reports state.
