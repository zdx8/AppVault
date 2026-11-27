#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AppVault"
ARCH="$(uname -m)"
DMG_NAME="${APP_NAME}-macOS-${ARCH}.dmg"
DIST_DIR="${ROOT_DIR}/dist"
STAGING_DIR="${DIST_DIR}/dmg-staging"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

if [[ ! -d "${DIST_DIR}/${APP_NAME}.app" ]]; then
  "${ROOT_DIR}/Scripts/package_app.sh"
fi

rm -rf "${STAGING_DIR}" "${DMG_PATH}" "${DMG_PATH}.sha256"
mkdir -p "${STAGING_DIR}"

cp -R "${DIST_DIR}/${APP_NAME}.app" "${STAGING_DIR}/"
cp "${ROOT_DIR}/LICENSE" "${STAGING_DIR}/LICENSE.txt"
cp "${ROOT_DIR}/README.md" "${STAGING_DIR}/使用说明.md"
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING_DIR}" -fs HFS+ -format UDZO -ov "${DMG_PATH}"
(cd "${DIST_DIR}" && shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256")
rm -rf "${STAGING_DIR}"

echo "DMG 已生成：${DMG_PATH}"
cat "${DMG_PATH}.sha256"
