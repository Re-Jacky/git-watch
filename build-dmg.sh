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

CHECKSUM=$(shasum -a 256 "${ZIP_OUT}" | awk '{print $1}')
printf '%s  %s\n' "${CHECKSUM}" "$(basename "${ZIP_OUT}")" > "${DIST_DIR}/${APP_NAME}-${VERSION}-updater.zip.sha256"

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
echo "sha256: ${CHECKSUM}"
