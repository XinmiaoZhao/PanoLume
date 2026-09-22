#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
if [[ -f "${PROJECT_DIR}/scripts/Private/environment.sh" ]]; then
  source "${PROJECT_DIR}/scripts/Private/environment.sh"
fi
SOURCE_PNG="${PANOLUME_APP_ICON_SOURCE:-$PROJECT_DIR/Resources/AppIconSource.png}"
OUTPUT_DIR="${1:-$PROJECT_DIR/.build/app-icon}"
MINIMUM_DEPLOYMENT_TARGET="${MINIMUM_DEPLOYMENT_TARGET:-14.0}"

ASSET_CATALOG="$OUTPUT_DIR/Assets.xcassets"
APP_ICON_SET="$ASSET_CATALOG/AppIcon.appiconset"
COMPILED_DIR="$OUTPUT_DIR/Compiled"
PARTIAL_INFO_PLIST="$OUTPUT_DIR/AppIconPartialInfo.plist"
ACTOOL_RESULT_PLIST="$OUTPUT_DIR/actool-result.plist"
ACTOOL_LOG="$OUTPUT_DIR/actool.log"

if [[ ! -f "$SOURCE_PNG" ]]; then
  print -u2 "Missing app icon source: $SOURCE_PNG"
  exit 1
fi
if ! command -v xcrun >/dev/null 2>&1; then
  print -u2 "Xcode command-line tools are required to build the app icon."
  exit 1
fi

source_width="$(/usr/bin/sips -g pixelWidth "$SOURCE_PNG" 2>/dev/null | /usr/bin/awk '/pixelWidth/ {print $2}')"
source_height="$(/usr/bin/sips -g pixelHeight "$SOURCE_PNG" 2>/dev/null | /usr/bin/awk '/pixelHeight/ {print $2}')"
source_has_alpha="$(/usr/bin/sips -g hasAlpha "$SOURCE_PNG" 2>/dev/null | /usr/bin/awk '/hasAlpha/ {print $2}')"
if [[ "$source_width" != 1024 || "$source_height" != 1024 ]]; then
  print -u2 "App icon source must be exactly 1024×1024 pixels; got ${source_width:-?}×${source_height:-?}."
  exit 1
fi
if [[ "$source_has_alpha" != "yes" ]]; then
  print -u2 "App icon source must preserve an alpha channel for the rounded transparent outer edge."
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$ASSET_CATALOG" "$COMPILED_DIR" "$PARTIAL_INFO_PLIST" "$ACTOOL_RESULT_PLIST" "$ACTOOL_LOG"
mkdir -p "$APP_ICON_SET" "$COMPILED_DIR"

render_icon() {
  local width="$1"
  local height="$2"
  local filename="$3"
  /usr/bin/sips -z "$height" "$width" "$SOURCE_PNG" --out "$APP_ICON_SET/$filename" >/dev/null
}

render_icon 16 16 "icon_16x16.png"
render_icon 32 32 "icon_16x16@2x.png"
render_icon 32 32 "icon_32x32.png"
render_icon 64 64 "icon_32x32@2x.png"
render_icon 128 128 "icon_128x128.png"
render_icon 256 256 "icon_128x128@2x.png"
render_icon 256 256 "icon_256x256.png"
render_icon 512 512 "icon_256x256@2x.png"
render_icon 512 512 "icon_512x512.png"
render_icon 1024 1024 "icon_512x512@2x.png"

cat > "$APP_ICON_SET/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

if ! xcrun actool \
  --compile "$COMPILED_DIR" \
  --platform macosx \
  --minimum-deployment-target "$MINIMUM_DEPLOYMENT_TARGET" \
  --target-device mac \
  --app-icon AppIcon \
  --standalone-icon-behavior all \
  --output-partial-info-plist "$PARTIAL_INFO_PLIST" \
  "$ASSET_CATALOG" \
  > "$ACTOOL_RESULT_PLIST" \
  2> "$ACTOOL_LOG"; then
  /bin/cat "$ACTOOL_LOG" >&2
  /bin/cat "$ACTOOL_RESULT_PLIST" >&2
  exit 1
fi

if [[ ! -f "$COMPILED_DIR/AppIcon.icns" || ! -f "$COMPILED_DIR/Assets.car" ]]; then
  print -u2 "actool did not produce both AppIcon.icns and Assets.car."
  /bin/cat "$ACTOOL_RESULT_PLIST" >&2
  exit 1
fi

/usr/bin/ditto "$COMPILED_DIR/AppIcon.icns" "$OUTPUT_DIR/AppIcon.icns"
/usr/bin/ditto "$COMPILED_DIR/Assets.car" "$OUTPUT_DIR/Assets.car"
print "$OUTPUT_DIR"
