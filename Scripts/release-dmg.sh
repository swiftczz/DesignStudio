#!/usr/bin/env bash
# 打包发布用的 DMG：Apple 芯片（arm64）→ 签名 →（可选）公证 → dist/DesignStudio-<版本>.dmg
#
# 用法：
#   ./Scripts/release-dmg.sh                 # 版本号取 Support/Info.plist
#   ./Scripts/release-dmg.sh 1.2.0           # 指定版本号
#
# 签名（自动选择，也可用环境变量指定）：
#   DEVELOPER_ID="Developer ID Application: 名字 (TEAMID)"
#     不设置时自动查找钥匙串里的 Developer ID Application 证书；找不到就用 ad-hoc 签名。
#     ad-hoc 签名的 DMG 发给别人后，对方第一次打开需要在「系统设置 → 隐私与安全性」里点「仍要打开」。
#
# 公证（需要 Developer ID；对方双击即可打开，不会被拦）：
#   先保存一次凭据：xcrun notarytool store-credentials designstudio-notary \
#                     --apple-id 你的AppleID --team-id TEAMID --password App专用密码
#   再运行：NOTARY_PROFILE=designstudio-notary ./Scripts/release-dmg.sh 1.2.0
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="DesignStudio"
APP="build/${APP_NAME}.app"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)}"
DMG="dist/${APP_NAME}-${VERSION}.dmg"

# ---------- 签名身份 ----------
if [ -z "${DEVELOPER_ID:-}" ]; then
  DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)"
fi
if [ -n "${DEVELOPER_ID}" ]; then
  SIGN_IDENTITY="${DEVELOPER_ID}"
  echo "▶︎ 签名身份：Developer ID"
else
  SIGN_IDENTITY="-"
  echo "⚠︎ 没有找到 Developer ID Application 证书，使用 ad-hoc 签名（对方首次打开需要手动允许）"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "✗ 公证需要 Developer ID 签名，已忽略 NOTARY_PROFILE" >&2
    NOTARY_PROFILE=""
  fi
fi

# ---------- 编译并打包 .app ----------
SIGN_IDENTITY="${SIGN_IDENTITY}" VERSION="${VERSION}" \
  ./Scripts/build-app.sh release

echo "▶︎ 检查签名"
codesign --verify --deep --strict "${APP}"
echo "   架构：$(lipo -archs "${APP}/Contents/MacOS/${APP_NAME}")"

# ---------- 组装 DMG 内容 ----------
WORK_DIR="$(mktemp -d)"
STAGE="${WORK_DIR}/stage"
RW_DMG="${WORK_DIR}/writable.dmg"
MOUNT="${WORK_DIR}/mount"
MOUNTED=false
cleanup() {
  if [ "${MOUNTED}" = true ]; then
    diskutil eject "${MOUNT}" >/dev/null || return
  fi
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# 部分 macOS 版本要求 --mountPoint 指定的目录已存在。
mkdir "${STAGE}" "${MOUNT}"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
if [ "${SIGN_IDENTITY}" = "-" ]; then
  cat > "${STAGE}/打不开时看这里.txt" <<EOF
DesignStudio ${VERSION} 安装说明

1. 把 DesignStudio 拖到「Applications / 应用程序」文件夹。
2. 第一次打开时，如果提示「无法验证开发者」或「Apple 无法检查其是否包含恶意软件」：
   打开「系统设置 → 隐私与安全性」，滚动到底部，在 DesignStudio 旁点「仍要打开」，再确认一次即可。
   （也可以在终端运行：xattr -dr com.apple.quarantine /Applications/DesignStudio.app）

系统要求：搭载 Apple 芯片的 Mac，运行 macOS 26 或更新版本。
使用 Claude / Codex / Antigravity 账号登录生成设计时，需要先安装对应的命令行工具（claude / codex / agy），
在应用的「设置 → 模型与账号」里可以看到安装命令；也可以直接填写 DeepSeek、OpenAI 等服务商的 API Key。
EOF
fi

# 先做可写镜像，设置卷图标后再压缩
mkdir -p dist
rm -f "${DMG}"
hdiutil create -quiet -volname "${APP_NAME} ${VERSION}" -srcfolder "${STAGE}" -fs HFS+ -format UDRW "${RW_DMG}"
diskutil image attach --mountOptions nobrowse --mountPoint "${MOUNT}" "${RW_DMG}" >/dev/null
MOUNTED=true
if [ -f Support/AppIcon.icns ]; then
  cp Support/AppIcon.icns "${MOUNT}/.VolumeIcon.icns"
  SetFile -c icnC "${MOUNT}/.VolumeIcon.icns" 2>/dev/null || true
  SetFile -a C "${MOUNT}" 2>/dev/null || true
fi
sync
diskutil eject "${MOUNT}" >/dev/null
MOUNTED=false
hdiutil convert -quiet "${RW_DMG}" -format UDZO -imagekey zlib-level=9 -o "${DMG}"

if [ "${SIGN_IDENTITY}" != "-" ]; then
  codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${DMG}"
fi

# ---------- 公证 ----------
if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▶︎ 提交公证（通常几分钟）"
  xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait
  xcrun stapler staple "${DMG}"
  spctl --assess --type open --context context:primary-signature -v "${DMG}"
fi

echo
echo "✅ ${DMG}（$(du -h "${DMG}" | cut -f1 | tr -d ' ')）"
echo "   SHA-256：$(shasum -a 256 "${DMG}" | cut -d' ' -f1)"
if [ "${SIGN_IDENTITY}" = "-" ]; then
  echo "   ⚠︎ ad-hoc 签名：对方首次打开需要在「隐私与安全性」里允许（DMG 里附了说明）"
elif [ -z "${NOTARY_PROFILE:-}" ]; then
  echo "   ⚠︎ 已用 Developer ID 签名但未公证：设置 NOTARY_PROFILE 后重新运行即可公证"
fi
