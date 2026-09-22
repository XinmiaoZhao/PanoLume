#!/bin/zsh
# Shared installation transaction; caller supplies validated staging paths.

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
bundle_identity_allowed() {
  local actual="$1" allowed
  for allowed in "${ACCEPTED_BUNDLE_IDS[@]}"; do
    [[ "$actual" == "$allowed" ]] && return 0
  done
  return 1
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
  if ! bundle_identity_allowed "$actual_id"; then
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

install_validated_app() {
setopt localtraps
trap cleanup EXIT
# No installed app is moved until the replacement has passed dependency,
# plist, icon and signature validation above.
mkdir -p "$INSTALL_DIR" "$BACKUP_ROOT"
for existing_app in "${LEGACY_APPS[@]}" "$SYSTEM_TARGET_APP" "$TARGET_APP"; do
  if [[ -d "$existing_app" ]] && ! bundle_identity_allowed "$(bundle_identifier "$existing_app")"; then
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
for existing_app in "$TARGET_APP" "$SYSTEM_TARGET_APP" "${LEGACY_APPS[@]}"; do
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
for existing_app in "$SYSTEM_TARGET_APP" "${LEGACY_APPS[@]}"; do
  if [[ -d "$existing_app" ]]; then
    /bin/rm -rf "$existing_app" 2>/dev/null \
      || print -u2 "Warning: could not remove obsolete duplicate $existing_app"
  fi
done
finalize_backup_history

if [[ "${PANOLUME_SKIP_LAUNCH_SERVICES:-0}" != 1 && -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$TARGET_APP" >/dev/null 2>&1 || true
fi
print "Installed $APP_NAME to $TARGET_APP"
}
