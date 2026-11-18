#!/usr/bin/env bash
set -euo pipefail

# 用法：SPARKLE_PRIVATE_ED_KEY=… bash Scripts/generate-appcast.sh DMG CHANGELOG.md DOWNLOAD_URL_PREFIX
DMG="${1:?缺少 DMG 路径}"
NOTES="${2:?缺少更新说明路径}"
DOWNLOAD_URL_PREFIX="${3:?缺少更新包下载地址前缀}"
: "${SPARKLE_PRIVATE_ED_KEY:?缺少 Sparkle 更新签名密钥}"

SPARKLE_TOOLS="$(dirname "$0")/../.build/artifacts/sparkle/Sparkle/bin"
STAGE="$(mktemp -d)"
ARCHIVE_NAME="$(basename "${DMG}")"
NOTES_NAME="${ARCHIVE_NAME%.dmg}.md"
cleanup() {
  rm -f "${STAGE}/${ARCHIVE_NAME}" "${STAGE}/${NOTES_NAME}" "${STAGE}/appcast.xml"
  rmdir "${STAGE}"
}
trap cleanup EXIT

cp "${DMG}" "${STAGE}/${ARCHIVE_NAME}"
cp "${NOTES}" "${STAGE}/${NOTES_NAME}"
printf '%s\n' "${SPARKLE_PRIVATE_ED_KEY}" | "${SPARKLE_TOOLS}/generate_appcast" --ed-key-file - \
  --embed-release-notes --maximum-deltas 0 --download-url-prefix "${DOWNLOAD_URL_PREFIX}" \
  -o "${STAGE}/appcast.xml" "${STAGE}"

# generate_appcast 会为公私钥不匹配的归档打印警告，因此还要确认归档签名确实写入了更新源。
HAS_SIGNATURE="$(xmllint --xpath "boolean(/rss/channel/item/enclosure[@*[local-name()='edSignature'] and @length])" "${STAGE}/appcast.xml")"
if [ "${HAS_SIGNATURE}" != true ]; then
  echo "✗ 更新包缺少 EdDSA 签名，请检查签名密钥是否与 Info.plist 中的公钥配对。" >&2
  exit 1
fi
printf '%s\n' "${SPARKLE_PRIVATE_ED_KEY}" | "${SPARKLE_TOOLS}/sign_update" --ed-key-file - --verify "${STAGE}/appcast.xml"
cp "${STAGE}/appcast.xml" "$(dirname "${DMG}")/appcast.xml"
