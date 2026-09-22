#!/bin/zsh
set -euo pipefail

APP_NAME="PanoLume"
PRODUCT_NAME="PanoLume"
BUNDLE_ID="com.zhaoxinmiao.PanoLume"
MARKETING_VERSION="0.3.0"

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
if [[ -f "${PROJECT_DIR}/scripts/Private/environment.sh" ]]; then
  source "${PROJECT_DIR}/scripts/Private/environment.sh"
fi
PACKAGE_DIR="$PROJECT_DIR/macos/PanoLume"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
BACKUP_ROOT="${BACKUP_ROOT:-$PROJECT_DIR/AppBackups}"
LEGACY_BACKUP_ROOT="$INSTALL_DIR/AppBackups"
PREVIOUS_BACKUP="$BACKUP_ROOT/Previous-$APP_NAME.app"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"
typeset -a LEGACY_APPS ACCEPTED_BUNDLE_IDS
LEGACY_APPS=()
ACCEPTED_BUNDLE_IDS=("$BUNDLE_ID")
SYSTEM_TARGET_APP="/Applications/$APP_NAME.app"
BUILD_ROOT="${PANOLUME_INSTALL_BUILD_DIR:-}"
SWIFTPM_BUILD_DIR=""
OWNS_BUILD_ROOT=0
STAGE_DIR=""
INSTALL_CANDIDATE=""
NEW_BACKUP_PATH=""
BACKUP_SOURCE_APP=""
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
source "$SCRIPT_DIR/app_install_transaction.sh"
if [[ -f "$SCRIPT_DIR/Private/installation-policy.sh" ]]; then
  source "$SCRIPT_DIR/Private/installation-policy.sh"
fi
trap cleanup EXIT


linked_dylib_paths() {
  local binary="$1"
  local skip_name="${2:-}"
  /usr/bin/otool -L "$binary" | /usr/bin/awk -v skip="$skip_name" '
    /^\t/ {
      split($1, parts, "/")
      name = parts[length(parts)]
      if (name != skip) print $1
    }
  '
}

is_system_dylib_path() {
  local path="$1"
  [[ "$path" == /System/* || "$path" == /usr/lib/* ]]
}

resolve_dylib_source() {
  local dependency="$1"
  local loader_source="$2"
  local name="${dependency:t}"
  local candidate

  if [[ "$dependency" == /* && -f "$dependency" ]]; then
    print "$dependency"
    return 0
  fi
  for candidate in \
    "${loader_source:h}/$name" \
    "/opt/homebrew/lib/$name" \
    "/usr/local/lib/$name"; do
    if [[ -f "$candidate" ]]; then
      print "$candidate"
      return 0
    fi
  done
  return 1
}

bundle_dylib_closure() {
  local binary="$1"
  local framework_dir="$2"
  local -a queue copied
  local -A queued copied_map
  local dependency source name target resolved dependency_name

  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    is_system_dylib_path "$dependency" && continue
    resolved="$(resolve_dylib_source "$dependency" "$binary" 2>/dev/null || true)"
    if [[ -z "$resolved" ]]; then
      print -u2 "Cannot resolve non-system dependency of ${binary:t}: $dependency"
      return 1
    fi
    name="${resolved:t}"
    [[ -n "${queued[$name]:-}" ]] && continue
    queue+=("$resolved")
    queued[$name]=1
  done < <(linked_dylib_paths "$binary" "${binary:t}")

  while (( ${#queue} > 0 )); do
    source="$queue[1]"
    shift queue
    name="${source:t}"
    [[ -n "${copied_map[$name]:-}" ]] && continue
    target="$framework_dir/$name"
    /bin/cp -fL "$source" "$target"
    /bin/chmod u+w "$target"
    /usr/bin/codesign --remove-signature "$target" >/dev/null 2>&1 || true
    copied+=("$name")
    copied_map[$name]=1

    while IFS= read -r dependency; do
      [[ -n "$dependency" ]] || continue
      is_system_dylib_path "$dependency" && continue
      resolved="$(resolve_dylib_source "$dependency" "$source" 2>/dev/null || true)"
      if [[ -z "$resolved" ]]; then
        print -u2 "Cannot resolve non-system dependency of $name: $dependency"
        return 1
      fi
      dependency_name="${resolved:t}"
      [[ -n "${queued[$dependency_name]:-}" || -n "${copied_map[$dependency_name]:-}" ]] && continue
      queue+=("$resolved")
      queued[$dependency_name]=1
    done < <(linked_dylib_paths "$target" "$name")
  done

  while IFS= read -r dependency; do
    name="${dependency:t}"
    [[ -f "$framework_dir/$name" ]] || continue
    /usr/bin/install_name_tool -change "$dependency" "@executable_path/../Frameworks/$name" "$binary"
  done < <(linked_dylib_paths "$binary" "${binary:t}")

  for name in "${copied[@]}"; do
    target="$framework_dir/$name"
    /usr/bin/install_name_tool -id "@rpath/$name" "$target"
    while IFS= read -r dependency; do
      dependency_name="${dependency:t}"
      [[ -f "$framework_dir/$dependency_name" ]] || continue
      /usr/bin/install_name_tool -change "$dependency" "@loader_path/$dependency_name" "$target"
    done < <(linked_dylib_paths "$target" "$name")
  done
}

verify_relocatable_dylibs() {
  local app_root="$1"
  local target dependency dylib_id failed=false
  local -a targets
  targets+=("$app_root/Contents/MacOS/$PRODUCT_NAME")
  for target in "$app_root/Contents/Frameworks"/*.dylib(N); do
    targets+=("$target")
  done
  for target in "${targets[@]}"; do
    if [[ "$target" == *.dylib ]]; then
      dylib_id="$(/usr/bin/otool -D "$target" | /usr/bin/tail -n 1)"
      if [[ "$dylib_id" == /* ]]; then
        print -u2 "Non-relocatable install ID remains in ${target:t}: $dylib_id"
        failed=true
      fi
    fi
    while IFS= read -r dependency; do
      case "$dependency" in
        /opt/homebrew/*|/usr/local/*)
          print -u2 "Non-relocatable dependency remains in ${target:t}: $dependency"
          failed=true
          ;;
      esac
    done < <(linked_dylib_paths "$target" "${target:t}")
  done
  [[ "$failed" == false ]]
}

if [[ -z "$BUILD_ROOT" ]]; then
  BUILD_ROOT="$(mktemp -d /private/tmp/panolume-install-build.XXXXXX)"
  OWNS_BUILD_ROOT=1
else
  mkdir -p "$BUILD_ROOT"
fi
SWIFTPM_BUILD_DIR="$BUILD_ROOT/swiftpm"

print "Building release executable…"
swift build \
  --package-path "$PACKAGE_DIR" \
  --configuration release \
  --jobs 4 \
  --product "$PRODUCT_NAME" \
  --scratch-path "$SWIFTPM_BUILD_DIR"

print "Building Metal renderer…"
env PANOLUME_METAL_OUTPUT_DIR="$BUILD_ROOT/metal" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/panolume-clang-module-cache}" \
  /bin/bash "$PROJECT_DIR/scripts/build_metal_renderer.sh" >/dev/null

STAGE_DIR="$(mktemp -d /private/tmp/panolume-app-stage.XXXXXX)"
STAGED_APP="$STAGE_DIR/$APP_NAME.app"
ICON_OUTPUT="$STAGE_DIR/AppIconBuild"
EXECUTABLE_PATH="$SWIFTPM_BUILD_DIR/release/$PRODUCT_NAME"
METAL_DYLIB="$BUILD_ROOT/metal/libpanolume_metal.dylib"

"$PROJECT_DIR/scripts/build_app_icon.sh" "$ICON_OUTPUT" >/dev/null
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$STAGED_APP/Contents/Frameworks"
/usr/bin/install -m 755 "$EXECUTABLE_PATH" "$STAGED_APP/Contents/MacOS/$PRODUCT_NAME"
/usr/bin/ditto "$ICON_OUTPUT/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
/usr/bin/ditto "$ICON_OUTPUT/Assets.car" "$STAGED_APP/Contents/Resources/Assets.car"
/usr/bin/install -m 755 "$METAL_DYLIB" "$STAGED_APP/Contents/Frameworks/libpanolume_metal.dylib"
bundle_dylib_closure "$STAGED_APP/Contents/MacOS/$PRODUCT_NAME" "$STAGED_APP/Contents/Frameworks"
verify_relocatable_dylibs "$STAGED_APP"

BUILD_NUMBER="$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"
GIT_REVISION="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || print local)"
print "APPL????" > "$STAGED_APP/Contents/PkgInfo"
cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$PRODUCT_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>PanoLume development build $GIT_REVISION.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null
/usr/bin/xattr -cr "$STAGED_APP" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$STAGED_APP" >/dev/null
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
if [[ "$(bundle_identifier "$STAGED_APP")" != "$BUNDLE_ID" ]]; then
  print -u2 "Staged bundle identifier verification failed."
  exit 1
fi

install_validated_app
