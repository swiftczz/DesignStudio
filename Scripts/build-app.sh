#!/usr/bin/env bash
# 把 SPM 可执行文件打包成可双击运行的 DesignStudio.app
# 用法：./Scripts/build-app.sh [release|debug]
#
# 可选环境变量（发布脚本 release-dmg.sh 会设置，本地开发不用管）：
#   ARCHS="arm64 x86_64"   编译的架构，默认只编当前机器的架构
#   SIGN_IDENTITY="..."    签名身份；默认 "-"（ad-hoc）。给 Developer ID 时启用 Hardened Runtime 与时间戳
#   VERSION="1.2.0"        写入 CFBundleShortVersionString
#   BUILD_NUMBER="42"      写入 CFBundleVersion
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP_NAME="DesignStudio"
APP="build/${APP_NAME}.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

ARCH_FLAGS=()
for arch in ${ARCHS:-}; do ARCH_FLAGS+=(--arch "$arch"); done

echo "▶︎ swift build -c ${CONFIG} ${ARCH_FLAGS[*]:-}"
swift build -c "${CONFIG}" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "${CONFIG}" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp Support/Info.plist "${APP}/Contents/Info.plist"

PLIST="${APP}/Contents/Info.plist"
[ -n "${VERSION:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${PLIST}"
[ -n "${BUILD_NUMBER:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${PLIST}"

# 如果存在 SPM 资源包也一并拷贝
for bundle in "${BIN_DIR}"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "${APP}/Contents/Resources/"
done

# 可选图标：Support/AppIcon.icns
if [ -f Support/AppIcon.icns ]; then
  cp Support/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${PLIST}" 2>/dev/null || true
fi

if [ "${SIGN_IDENTITY}" = "-" ]; then
  # ad-hoc 签名：本机运行没问题；发给别人时对方需要在「隐私与安全性」里允许一次
  codesign --force --deep --sign - "${APP}"
else
  # Developer ID：开启 Hardened Runtime 并带时间戳（公证的必要条件）
  codesign --force --options runtime --timestamp \
    --entitlements Support/DesignStudio.entitlements \
    --sign "${SIGN_IDENTITY}" "${APP}"
fi

echo "✅ 已生成 ${APP}"
echo "   运行：open ${APP}"
