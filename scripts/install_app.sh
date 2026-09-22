#!/bin/zsh
set -euo pipefail

APP_NAME="PanoLume"
PRODUCT_NAME="MyPTGuiNative"
BUNDLE_ID="com.zhaoxinmiao.MyPTGuiNative"
MARKETING_VERSION="0.3.0"

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
PACKAGE_DIR="$PROJECT_DIR/macos/MyPTGuiNative"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
BACKUP_ROOT="${BACKUP_ROOT:-$PROJECT_DIR/AppBackups}"
LEGACY_BACKUP_ROOT="$INSTALL_DIR/AppBackups"
PREVIOUS_BACKUP="$BACKUP_ROOT/Previous-$APP_NAME.app"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"
LEGACY_USER_APP="$INSTALL_DIR/MyPTGui Native.app"
LEGACY_SYSTEM_APP="/Applications/MyPTGui Native.app"
SYSTEM_TARGET_APP="/Applications/$APP_NAME.app"
BUILD_ROOT="${MYPTGUI_INSTALL_BUILD_DIR:-}"
SWIFTPM_BUILD_DIR=""
OWNS_BUILD_ROOT=0
STAGE_DIR=""
INSTALL_CANDIDATE=""
NEW_BACKUP_PATH=""
BACKUP_SOURCE_APP=""
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cleanup() {
  local exit_status=$?
  # If replacement fails after moving the installed predecessor aside, restore
  # it to the exact source location. Successful installs keep TARGET_APP and
  # finalize NEW_BACKUP_PATH before this trap runs.
  if (( exit_status != 0 )) \
    && [[ -n "$NEW_BACKUP_PATH" && -d "$NEW_BACKUP_PATH" ]] \
    && [[ -n "$BACKUP_SOURCE_APP" && ! -e "$BACKUP_SOURCE_APP" ]]; then
    /bin/mv "$NEW_BACKUP_PATH" "$BACKUP_SOURCE_APP" 2>/dev/null || true
    NEW_BACKUP_PATH=""
  fi
  if [[ -n "$STAGE_DIR" ]]; then
    rm -rf "$STAGE_DIR"
  fi
  if [[ -n "$INSTALL_CANDIDATE" && -e "$INSTALL_CANDIDATE" ]]; then
    rm -rf "$INSTALL_CANDIDATE"
  fi
  if [[ "$OWNS_BUILD_ROOT" == "1" && -n "$BUILD_ROOT" && -e "$BUILD_ROOT" ]]; then
    rm -rf "$BUILD_ROOT"
  fi
  return $exit_status
}
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

bundle_identifier() {
  local app="$1"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true
}

backup_previous_app() {
  local app="$1"
  local actual_id
  [[ -d "$app" ]] || return 0
  actual_id="$(bundle_identifier "$app")"
  if [[ "$actual_id" != "$BUNDLE_ID" ]]; then
    print -u2 "Refusing to move $app because its bundle ID is '${actual_id:-missing}', not '$BUNDLE_ID'."
    return 1
  fi
  NEW_BACKUP_PATH="$BACKUP_ROOT/.Previous-$APP_NAME-installing-$$.app"
  BACKUP_SOURCE_APP="$app"
  if [[ -e "$NEW_BACKUP_PATH" ]]; then
    print -u2 "Unexpected temporary backup already exists: $NEW_BACKUP_PATH"
    return 1
  fi
  /bin/mv "$app" "$NEW_BACKUP_PATH"
}

finalize_backup_history() {
  local backup
  # The replacement is already installed and verified before this function is
  # called. Only now is it safe to discard older backup generations.
  for backup in "$BACKUP_ROOT"/*.app(N); do
    /bin/rm -rf "$backup"
  done
  for backup in "$BACKUP_ROOT"/.Previous-$APP_NAME-installing-*.app(N); do
    [[ "$backup" == "$NEW_BACKUP_PATH" ]] || /bin/rm -rf "$backup"
  done
  if [[ -n "$NEW_BACKUP_PATH" && -d "$NEW_BACKUP_PATH" ]]; then
    /bin/mv "$NEW_BACKUP_PATH" "$PREVIOUS_BACKUP"
    NEW_BACKUP_PATH=""
    print "Saved previous version to $PREVIOUS_BACKUP"
  fi

  # Remove backup generations created by older installers under Applications.
  # Preserve unrelated non-App files if that directory was repurposed locally.
  if [[ "$LEGACY_BACKUP_ROOT" != "$BACKUP_ROOT" && -d "$LEGACY_BACKUP_ROOT" ]]; then
    for backup in "$LEGACY_BACKUP_ROOT"/*.app(N); do
      /bin/rm -rf "$backup"
    done
    /bin/rmdir "$LEGACY_BACKUP_ROOT" 2>/dev/null || true
  fi
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
  --product "$PRODUCT_NAME" \
  --scratch-path "$SWIFTPM_BUILD_DIR"

print "Building Metal renderer…"
env MYPTGUI_METAL_OUTPUT_DIR="$BUILD_ROOT/metal" \
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/myptgui-clang-module-cache}" \
  /bin/bash "$PROJECT_DIR/scripts/build_metal_renderer.sh" >/dev/null

STAGE_DIR="$(mktemp -d /private/tmp/myptgui-app-stage.XXXXXX)"
STAGED_APP="$STAGE_DIR/$APP_NAME.app"
ICON_OUTPUT="$STAGE_DIR/AppIconBuild"
EXECUTABLE_PATH="$SWIFTPM_BUILD_DIR/release/$PRODUCT_NAME"
METAL_DYLIB="$BUILD_ROOT/metal/libmyptgui_metal.dylib"

"$PROJECT_DIR/scripts/build_app_icon.sh" "$ICON_OUTPUT" >/dev/null
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "$STAGED_APP/Contents/Frameworks"
/usr/bin/install -m 755 "$EXECUTABLE_PATH" "$STAGED_APP/Contents/MacOS/$PRODUCT_NAME"
/usr/bin/ditto "$ICON_OUTPUT/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
/usr/bin/ditto "$ICON_OUTPUT/Assets.car" "$STAGED_APP/Contents/Resources/Assets.car"
/usr/bin/install -m 755 "$METAL_DYLIB" "$STAGED_APP/Contents/Frameworks/libmyptgui_metal.dylib"
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

# No installed app is moved until the replacement has passed dependency,
# plist, icon and signature validation above.
mkdir -p "$INSTALL_DIR" "$BACKUP_ROOT"
for existing_app in "$LEGACY_USER_APP" "$LEGACY_SYSTEM_APP" "$SYSTEM_TARGET_APP" "$TARGET_APP"; do
  if [[ -d "$existing_app" && "$(bundle_identifier "$existing_app")" != "$BUNDLE_ID" ]]; then
    print -u2 "Refusing to replace $existing_app because its bundle ID is not '$BUNDLE_ID'."
    exit 1
  fi
done

# Copy the fully validated candidate onto the destination volume first. The
# final move is then atomic on that volume and cannot strand the current app
# merely because a long cross-volume copy failed.
INSTALL_CANDIDATE="$INSTALL_DIR/.PanoLume-installing-$$.app"
if [[ -e "$INSTALL_CANDIDATE" ]]; then
  print -u2 "Unexpected installation candidate already exists: $INSTALL_CANDIDATE"
  exit 1
fi
/usr/bin/ditto "$STAGED_APP" "$INSTALL_CANDIDATE"
/usr/bin/codesign --verify --deep --strict "$INSTALL_CANDIDATE"

# Preserve exactly one previous version. Prefer the canonical user install;
# legacy locations are considered only during the first migration.
PREVIOUS_APP=""
for existing_app in "$TARGET_APP" "$SYSTEM_TARGET_APP" "$LEGACY_USER_APP" "$LEGACY_SYSTEM_APP"; do
  if [[ -d "$existing_app" ]]; then
    PREVIOUS_APP="$existing_app"
    break
  fi
done
if [[ -n "$PREVIOUS_APP" ]]; then
  backup_previous_app "$PREVIOUS_APP"
fi
/bin/mv "$INSTALL_CANDIDATE" "$TARGET_APP"
INSTALL_CANDIDATE=""
/usr/bin/xattr -cr "$TARGET_APP" 2>/dev/null || true
/usr/bin/codesign --verify --deep --strict "$TARGET_APP"
/usr/bin/touch "$TARGET_APP"

# Matching duplicate installations are older than both the new canonical app
# and its single saved predecessor. Remove them only after replacement passes.
for existing_app in "$SYSTEM_TARGET_APP" "$LEGACY_USER_APP" "$LEGACY_SYSTEM_APP"; do
  if [[ -d "$existing_app" ]]; then
    /bin/rm -rf "$existing_app" 2>/dev/null \
      || print -u2 "Warning: could not remove obsolete duplicate $existing_app"
  fi
done
finalize_backup_history

if [[ "${MYPTGUI_SKIP_LAUNCH_SERVICES:-0}" != 1 && -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$TARGET_APP" >/dev/null 2>&1 || true
fi
print "Installed $APP_NAME to $TARGET_APP"
