# Task 8: Release infrastructure + repo conventions doc

**Files:**
- Create: `build-dmg.sh` (repo root), `.github/workflows/release.yml`, `AGENTS.md`
- Modify: `git-watch.xcodeproj/project.pbxproj` (MARKETING_VERSION → 1.0.0)

**Interfaces:**
- Consumes: complete app from Tasks 1–7; `scripts/create_project.rb` regeneration flow
- Produces: one-command DMG packaging, manual-dispatch GitHub release workflow, conventions doc for future agents

- [ ] **Step 1: Write `build-dmg.sh`**

Adapted from `/Users/zyao/Desktop/pulse/scripts/build-dmg.sh` with three renames:

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="GitWatch"
SCHEME="git-watch"
PROJECT="git-watch.xcodeproj"
VERSION=$(grep -m1 'MARKETING_VERSION' "${PROJECT}/project.pbxproj" | sed 's/.*= *//;s/;//')
CONFIG="Release"
DIST_DIR="dist"
STAGING_DIR="/tmp/${APP_NAME}-dmg-staging"
DERIVED_DATA_DIR="/tmp/${APP_NAME}-dmg-derived-data"

echo "==> Building ${APP_NAME} (${CONFIG})..."
rm -rf "${DERIVED_DATA_DIR}"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIG}" \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  build

APP_PATH="${DERIVED_DATA_DIR}/Build/Products/${CONFIG}/${APP_NAME}.app"

if [ ! -d "${APP_PATH}" ]; then
  echo "ERROR: Could not find built .app" >&2
  exit 1
fi

mkdir -p "${DIST_DIR}"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

cp -R "${APP_PATH}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

ZIP_OUT="${DIST_DIR}/${APP_NAME}-${VERSION}-updater.zip"

echo "==> Creating updater ZIP..."
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_OUT}"

DMG_TMP="/tmp/${APP_NAME}-tmp.dmg"
DMG_OUT="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"

echo "==> Creating DMG..."
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_TMP}"

mv "${DMG_TMP}" "${DMG_OUT}"
rm -rf "${STAGING_DIR}"
rm -rf "${DERIVED_DATA_DIR}"

echo "==> Done: ${ZIP_OUT} ${DMG_OUT}"
```

Verify the embedded helper made it into the built app before packaging succeeds conceptually:

```bash
chmod +x build-dmg.sh
bash build-dmg.sh
ls dist/
unzip -l dist/GitWatch-*-updater.zip | grep Helpers/GitWatchUpdater.app
```

Expected: `GitWatch-<version>.dmg` and `GitWatch-<version>-updater.zip` in `dist/`, helper present inside the zip at `Contents/Helpers/GitWatchUpdater.app`. If the helper is missing from the bundle, re-run `ruby scripts/create_project.rb` (the embed phase is generated there) and rebuild.

- [ ] **Step 2: Write `.github/workflows/release.yml`**

Copy `/Users/zyao/Desktop/pulse/.github/workflows/release.yml` verbatim, then apply these substitutions:
- Every `pulse.xcodeproj` → `git-watch.xcodeproj`
- Every `Pulse.app` → `GitWatch.app`; every `pulse` scheme reference → `git-watch`
- Asset names `Pulse-<version>.dmg` / `Pulse-<version>-updater.zip` → `GitWatch-…`
- Build step command `bash scripts/build-dmg.sh` stays identical
- Keep trigger semantics: manual dispatch reading `MARKETING_VERSION` from `project.pbxproj`, failing when tag `v<version>` already exists

If Pulse's workflow hardcodes a runner image or Xcode version, keep those values unchanged.

- [ ] **Step 3: Bump version to 1.0.0**

```bash
sed -i '' 's/MARKETING_VERSION = 0\.1\.0;/MARKETING_VERSION = 1.0.0;/' git-watch.xcodeproj/project.pbxproj
grep -m1 'MARKETING_VERSION' git-watch.xcodeproj/project.pbxproj
xcodebuild -project git-watch.xcodeproj -scheme git-watch -configuration Debug build
```

Expected: `MARKETING_VERSION = 1.0.0;` and clean build.

- [ ] **Step 4: Write `AGENTS.md`**

```markdown
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

## Token Handling

- Resolution order: Settings PAT override → `gh auth token` (homebrew paths first) → none; implemented in `GitHubAuthProvider.resolve()`
- No Keychain; tokens live in UserDefaults (same plaintext posture as gh's hosts.yml)
- HTTP 401 → `.tokenRejected`; 403/429 or "rate limit" message → `.rateLimited`

## Repo-Specific Conventions

- Semantic colors from `Views/Colors.swift`; the only exceptions are the three GitHub status colors (`appStatusSuccess/Failure/Pending`) defined there as hex constants
- Do not add comments to code
- Merge method default is `.merge` (matches github.com); persisted under `github.mergeMethod`
- Refresh interval is a fixed 300 s constant passed to `startAutomaticRefresh` — do not expose it in Settings without updating the spec
```

- [ ] **Step 5: Full verification sweep**

```bash
xcodebuild -project git-watch.xcodeproj -scheme git-watch -configuration Debug build && \
xcodebuild test -project git-watch.xcodeproj -scheme git-watch -destination 'platform=macOS' && \
bash build-dmg.sh
```

Expected: build green, all tests pass, DMG + zip produced. Open the DMG once to confirm drag-to-Applications layout renders.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add release pipeline, workflows, and repo conventions"
```

- [ ] **Step 7: Publish (manual, user-driven)**

Create the GitHub repository `Re-Jacky/git-watch`, push `main`, then run the Release workflow manually from the Actions tab. First release artifact set should be `GitWatch-1.0.0.dmg` + `GitWatch-1.0.0-updater.zip`. Verify the installed app finds updates by bumping `MARKETING_VERSION` locally and confirming the update banner appears.
