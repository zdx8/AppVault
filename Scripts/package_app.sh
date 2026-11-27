#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AppVault"
BUNDLE_ID="com.appvault.macos"
VERSION="0.1.1"
BUILD_NUM="2"

DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

BUILD_ARGS=(-c release)
if [[ "${DISABLE_SANDBOX:-0}" == "1" ]]; then
  BUILD_ARGS+=(--disable-sandbox --cache-path /tmp/spm-cache --config-path /tmp/spm-config --security-path /tmp/spm-security)
fi

echo "[1/4] 编译 Release 可执行文件..."
cd "${ROOT_DIR}"
swift build "${BUILD_ARGS[@]}"

BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/${APP_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
  echo "未找到编译产物：${BIN_PATH}" >&2
  exit 1
fi

echo "[2/4] 组装 ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

if [[ -f "${ROOT_DIR}/Assets/AppIcon.icns" ]]; then
  cp "${ROOT_DIR}/Assets/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUM}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "[3/4] 剥离本地符号并执行加固签名..."
strip -x "${MACOS_DIR}/${APP_NAME}" 2>/dev/null || true

SIGN_ID="${CODESIGN_IDENTITY:-}"
if [[ -z "${SIGN_ID}" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "AppVault Local Sign"; then
    SIGN_ID="AppVault Local Sign"
  else
    SIGN_ID="-"
  fi
fi

if [[ "${SIGN_ID}" == "-" ]]; then
  codesign --force --deep --options runtime --sign - "${APP_BUNDLE}" 2>/dev/null || codesign --force --deep --sign - "${APP_BUNDLE}"
else
  echo "使用稳定本地证书签名：${SIGN_ID}"
  codesign --force --deep --options runtime --sign "${SIGN_ID}" "${APP_BUNDLE}"
fi

echo "[4/4] 完成打包：${APP_BUNDLE}"
ls -lh "${MACOS_DIR}/${APP_NAME}"
