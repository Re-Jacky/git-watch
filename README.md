# GitWatch

A macOS menu bar app that keeps every pull request that needs you on one screen — yours, ones waiting for your review, and green ones you can merge — with one-click Approve/Merge and an optional fully-automatic mode.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Language](https://img.shields.io/badge/language-Swift-orange)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

---

## Features

- **Menu bar icon with live badge** — count of all open PRs involving you; turns into a **solid blue disc** while Auto mode is active
- **Two-tab panel**:
  - **Mine** — open PRs authored by you with CI dot cluster and review-state chip
  - **Review & Merge** — grouped sections *Waiting for your review* (with author, inline **Approve**) and *Ready for you to merge* (inline **Merge · \<method\>**)
- **Quick actions** — Approve and Merge right from the row; merged/closed PRs disappear automatically; a ✕ dismisses any PR you don't intend to handle (restorable from Settings)
- **Auto Mode** (optional, off by default):
  - Automatically approves every review request — including re-approval when an author pushes changes and a branch protection dismisses your stale review
  - Optionally merges every green PR you have permission to merge using your configured method (scopes configurable; approve-only is the default)
  - Runs after each refresh cycle and immediately when enabled
- **Zero-config auth** — uses your existing `gh` CLI login; optional Personal Access Token override in Settings
- **Efficient** — one combined GraphQL query per refresh (every 5 minutes, on panel open, or manually), not N+1 REST calls
- **Theme switching** — System / Dark / Light, applied to panel and settings window instantly
- **Launch at Login** via SMAppService
- **Self-updating** — checks GitHub Releases hourly, downloads and installs through a bundled helper app

---

## Installation

Download the latest `.dmg` from the [Releases](https://github.com/Re-Jacky/git-watch/releases) page, open it, and drag **GitWatch.app** to the Applications shortcut inside.

> [!IMPORTANT]
> If macOS blocks the app on first launch ("Apple could not verify GitWatch…"), run:
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/GitWatch.app
> ```

### First run

1. A circled pull-request glyph appears in your menu bar — left-click opens the panel, right-click shows Open / Refresh / Auto Mode / Settings / Quit
2. Sign-in is automatic if `gh` is installed and logged in (`gh auth login` otherwise). The token needs `repo` scope for private repos and pull-request write access for approvals/merges
3. The badge counts everything waiting on you; click through the tabs to act

---

## Requirements

| Tool | Version |
|------|---------|
| macOS | 14.0 Sonoma or later |
| Xcode | 15 or later (building only) |
| [gh CLI](https://cli.github.com/) | any recent version (runtime auth; optional if a PAT is entered) |

No package manager, no CocoaPods, no Swift packages required.

---

## How PRs are selected

GitWatch runs two searches per refresh against everything your token can see:

- `is:pr is:open author:@me` → **Mine**
- `is:pr is:open review-requested:@me` → split into **Waiting for your review** (not yet mergeable) and **Ready for you to merge**

A PR is *ready to merge* only when `mergeStateStatus` ∈ {CLEAN, HAS_HOOKS}, you hold WRITE/MAINTAIN/ADMIN permission on the repository, and it reports MERGEABLE. v1 scope note: teammate PRs where you are neither author nor requested reviewer are invisible by design.

---

## Auto Mode

Enable from **Settings → GitHub** or the icon's right-click menu.

| Scope | Default | Behavior |
|-------|---------|----------|
| Approve | **on** | Every review request is approved regardless of CI state; re-approved automatically if an author pushes changes and your stale review gets dismissed |
| Merge | off | Every green PR you can merge is merged with your default method |

Processing happens after every refresh and immediately on enable. Failures surface as inline errors on the affected row and retry next cycle. While active, the menu bar icon renders as a solid blue disc and an info banner appears in the panel.

⚠️ Auto Mode approves unreviewed code and merges real PRs — try it on low-stakes repositories first.

---

## Settings

| Section | What's there |
|---------|--------------|
| **General** | Launch at Login, Theme (System/Dark/Light) |
| **GitHub** | Auto Mode + scopes, Personal Access Token override, default merge method (Merge Commit/Squash/Rebase — falls back to whatever the repository allows), "Show Dismissed PRs" restore |
| **Updates** | Check / download / install releases manually |

Tokens resolve as: **Settings PAT → `gh auth token`**. Like `gh` itself (`hosts.yml`), tokens are stored unencrypted in `UserDefaults` — no Keychain prompts, same trust model as the CLI you already use.

---

## Building

### Option 1: Xcode GUI

Open `git-watch.xcodeproj`, select the `git-watch` scheme, press ⌘R.

### Option 2: Command Line

```bash
xcodebuild -project git-watch.xcodeproj -scheme git-watch -configuration Debug build

xcodebuild test -project git-watch.xcodeproj -scheme git-watch -destination 'platform=macOS'
```

### Option 3: Release artifacts

```bash
bash build-dmg.sh
```

Produces `dist/GitWatch-<version>.dmg` plus `dist/GitWatch-<version>-updater.zip` and prints/writes the zip's `sha256:` checksum that the in-app updater verifies.

### Adding source files

```bash
ruby scripts/add_files.rb path/to/NewFile.swift   # registers into the project (needs the ruby xcodeproj gem)

rm -rf git-watch.xcodeproj && ruby scripts/create_project.rb   # full regeneration (destructive)
```

---

## Releases

1. Bump `MARKETING_VERSION` in `git-watch.xcodeproj/project.pbxproj`
2. Push to `main`

That's it — the Release workflow fires automatically on any push touching `project.pbxproj` (or can be run manually from the Actions tab). It builds the DMG, creates a `v<version>` tag/release (fails if the tag exists), and uploads the DMG + updater zip with checksum notes.

---

## Project Structure

```
git-watch/
├── App/
│   ├── main.swift              # AppKit entry point
│   └── AppDelegate.swift       # Status item, InputPanel, settings window, menus
├── Managers/
│   ├── GitHubAuth.swift        # PAT override → gh CLI token resolution
│   ├── GitHubSettings.swift    # Persisted preferences (UserDefaults)
│   ├── GitHubQueries.swift     # GraphQL dashboard query + mutations
│   ├── GitHubClient.swift      # URLSession GraphQL transport
│   ├── PullRequestModels.swift # Models + grouping classifier
│   ├── PullRequestStore.swift  # Single source of truth: lists, states, actions
│   ├── UpdateManager.swift     # Self-update pipeline (+ helper target)
│   ├── ThemeManager.swift
│   └── LaunchAtLoginSettings.swift
├── Views/
│   ├── PanelView.swift         # Tabs, sections, banners, pinned footer
│   ├── PullRequestRowView.swift
│   ├── SettingsView.swift
│   └── Colors.swift            # Semantic palette
├── MenuBarBadgeView.swift      # Status-item view (outline/blue-disc states)
├── gitwatchUpdater/            # Bundled install helper app
├── git-watchTests/             # 47 XCTests: auth, decoding, classifier, lifecycle
└── scripts/                    # Project generation & maintenance
```

---

## License

MIT
