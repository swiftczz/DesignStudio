#!/usr/bin/env bash
# 由 Support/AppIcon.svg 生成 Support/AppIcon.icns（需要 rsvg-convert：brew install librsvg）
# 用法：./Scripts/make-icon.sh
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="Support/AppIcon.svg"
OUT="Support/AppIcon.icns"

if ! command -v rsvg-convert >/dev/null; then
  echo "需要 rsvg-convert，请先运行：brew install librsvg" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"

render() { rsvg-convert -w "$1" -h "$1" "$SRC" -o "$SET/$2"; }
for size in 16 32 128 256 512; do
  render "$size" "icon_${size}x${size}.png"
  render "$((size * 2))" "icon_${size}x${size}@2x.png"
done

iconutil -c icns "$SET" -o "$OUT"
echo "✅ 已生成 $OUT"
