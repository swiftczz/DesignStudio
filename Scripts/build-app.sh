#!/usr/bin/env bash
# 把 SPM 可执行文件打包成适用于 Apple 芯片的 DesignStudio.app
# 用法：./Scripts/build-app.sh [release|debug]
#
# 可选环境变量（本地开发通常无需设置）：
#   SIGN_IDENTITY="..."    签名身份；默认 "-"（ad-hoc）。给 Developer ID 时启用 Hardened Runtime 与时间戳
#   VERSION="1.2.0"        覆盖最近可达的发布标签，写入 CFBundleShortVersionString
#   BUILD_NUMBER="42"      覆盖 Git 历史提交数，写入 CFBundleVersion
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
ARCH="arm64"
APP_NAME="DesignStudio"
APP="build/${APP_NAME}.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [ -z "${VERSION:-}" ]; then
  RELEASE_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)"
  if [[ "${RELEASE_TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    VERSION="${RELEASE_TAG#v}"
  fi
fi

# 完整 Git 历史可用时，使用截至当前提交的累计提交数。
if [ -z "${BUILD_NUMBER:-}" ] && [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = false ]; then
  BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || true)"
fi
BUILD_NUMBER="${BUILD_NUMBER:-}"

echo "▶︎ swift build -c ${CONFIG} --arch ${ARCH}"
swift build -c "${CONFIG}" --arch "${ARCH}"
BIN_DIR="$(swift build -c "${CONFIG}" --arch "${ARCH}" --show-bin-path)"
BIN_ARCHS="$(lipo -archs "${BIN_DIR}/${APP_NAME}")"
if [ "${BIN_ARCHS}" != "${ARCH}" ]; then
  echo "✗ 预期架构为 ${ARCH}，实际为 ${BIN_ARCHS}" >&2
  exit 1
fi

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${APP}/Contents/Frameworks"
cp "${BIN_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp Support/Info.plist "${APP}/Contents/Info.plist"
SPARKLE="${APP}/Contents/Frameworks/Sparkle.framework"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "${SPARKLE}"
# SwiftPM 会写入构建机的框架搜索路径，打包后只保留相对路径。
while IFS= read -r rpath; do
  install_name_tool -delete_rpath "${rpath}" "${APP}/Contents/MacOS/${APP_NAME}"
done < <(otool -l "${APP}/Contents/MacOS/${APP_NAME}" | sed -nE 's/^ +path (\/.*) \(offset [0-9]+\)$/\1/p')

PLIST="${APP}/Contents/Info.plist"
[ -n "${VERSION:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${PLIST}"
[ -n "${BUILD_NUMBER}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${PLIST}"

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
  codesign --force --sign - "${APP}"
else
  # Hardened Runtime 要求内嵌代码和主应用使用同一个 Team ID。先签内层，再签框架和主应用。
  SPARKLE_VERSION="${SPARKLE}/Versions/Current"
  for helper in "${SPARKLE_VERSION}/Autoupdate" "${SPARKLE_VERSION}/Updater.app" "${SPARKLE_VERSION}/XPCServices/"*.xpc; do
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
      --sign "${SIGN_IDENTITY}" "${helper}"
  done
  codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${SPARKLE}"
  # Developer ID：开启 Hardened Runtime 并带时间戳（公证的必要条件）
  codesign --force --options runtime --timestamp \
    --entitlements Support/DesignStudio.entitlements \
    --sign "${SIGN_IDENTITY}" "${APP}"
fi
codesign --verify --deep --strict "${APP}"

echo "✅ 已生成 ${APP}"
echo "   运行：open ${APP}"
