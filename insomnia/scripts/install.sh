#!/bin/bash
# Build and stage before replacing the existing installation. Installations use the standard per-user paths.
set -euo pipefail
if [[ -n "${INSOMNIA_HOME:-}" ]]; then
  echo "Install/uninstall require standard paths. Unset INSOMNIA_HOME; relocation is only supported by the app/backstop." >&2
  exit 2
fi
umask 077
ROOT="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UID_NUM="$(/usr/bin/id -u)"
ACCOUNT="$(/usr/bin/id -un)"
[[ "$UID_NUM" != 0 ]] || { echo "Run as your login account, not root." >&2; exit 1; }
[[ "$ACCOUNT" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || { echo "Unsupported account name." >&2; exit 1; }
APP_DIR="$HOME/Applications"
APP="$APP_DIR/Insomnia.app"
APP_SUPPORT="$HOME/Library/Application Support/Insomnia"
LOG_DIR="$HOME/Library/Logs/Insomnia"
LABEL=com.insomnia.backstop
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SUDOERS=/etc/sudoers.d/insomnia
# Machine-wide, fail-closed exclusion: never steal another installer's guard.
INSTALL_LOCK=/private/tmp/com.kgarg.insomnia-install.lock
if ! /bin/mkdir "$INSTALL_LOCK" 2>/dev/null; then
  echo "Installer guard occupied: $INSTALL_LOCK. Check for another installer or a stale guard." >&2
  exit 1
fi
stage=''
cleanup() {
  status=$?
  if [[ -n "$stage" ]]; then
    if (( status != 0 )) && [[ -e "$stage/previous.app" || -e "$stage/rollback-failed" ]]; then
      echo "Recovery rollback files retained at $stage; inspect before retrying." >&2
    else /bin/rm -rf "$stage"; fi
  fi
  /bin/rmdir "$INSTALL_LOCK" || true
}
trap cleanup EXIT

# Only the current UID's exact grant may be migrated or removed. A legacy grant
# lacks the owner comment, but must still contain only this account's commands.
check_owner() {
  /usr/bin/sudo -v
  if /usr/bin/sudo /bin/test -e "$SUDOERS"; then
    grant="$(/usr/bin/sudo /bin/cat "$SUDOERS")"
    seen=0
    while IFS= read -r line; do
      command=0
      case "$line" in
        "# Insomnia owner UID: $UID_NUM") ;;
        '# Insomnia owner UID:'*) echo "Another account owns Insomnia." >&2; exit 1 ;;
        ''|'#'*) ;;
        "$ACCOUNT ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0") command=1 ;;
        "$ACCOUNT ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1") command=2 ;;
        "$ACCOUNT ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0") command=4 ;;
        "$ACCOUNT ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1") command=8 ;;
        *) echo "Refusing foreign or unrecognized sudoers grant: $SUDOERS" >&2; exit 1 ;;
      esac
      (( (seen & command) == 0 )) || { echo "Duplicate sudoers command; inspect $SUDOERS" >&2; exit 1; }
      seen=$((seen | command))
    done <<< "$grant"
    (( seen == 15 )) || { echo "Incomplete sudoers grant; inspect $SUDOERS" >&2; exit 1; }
  fi
}
app_running() {
  status=0
  /usr/bin/pgrep -u "$UID_NUM" -x Insomnia >/dev/null 2>&1 || status=$?
  if (( status > 1 )); then echo "Unable to check Insomnia termination." >&2; exit 1; fi
  return "$status"
}
quit_app() {
  if app_running; then
    /usr/bin/osascript -e 'tell application id "com.kgarg.insomnia" to quit' >/dev/null 2>&1 || true
    for (( attempt=0; attempt<30; attempt++ )); do
      app_running || return 0
      /bin/sleep 0.2
    done
    echo "Insomnia is still running. Quit it before retrying; no files removed." >&2
    return 1
  fi
}
unload_agent() {
  if ! /bin/launchctl bootout "gui/$UID_NUM" "$PLIST" >/dev/null 2>&1; then
    lookup_status=0
    /bin/launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || lookup_status=$?
    # launchctl's service-not-found status is the only acceptable failed lookup.
    if (( lookup_status != 113 )); then
      echo "LaunchAgent unload could not be confirmed; installed recovery files retained." >&2
      return 1
    fi
  fi
}
check_owner
quit_app

echo "Building Insomnia (release)"
cd "$ROOT"
/usr/bin/swift build -c release
BIN="$(/usr/bin/swift build -c release --show-bin-path)/Insomnia"
[[ -x "$BIN" ]] || { echo "Missing executable: $BIN" >&2; exit 1; }
# Verify a static marker before ever passing an unknown argument to a binary.
if ! /usr/bin/strings -a "$BIN" | /usr/bin/grep -F 'insomnia-maintenance-v1' >/dev/null ||
   [[ "$("$BIN" --maintenance-protocol)" != insomnia-maintenance-v1 ]]; then
  echo "Built executable does not support safe maintenance." >&2; exit 1
fi
# Building can take minutes; the app may have been reopened since the first check.
quit_app
/bin/mkdir -p "$APP_DIR" "$APP_SUPPORT" "$LOG_DIR" "$HOME/Library/LaunchAgents"
/bin/chmod 700 "$APP_SUPPORT" "$LOG_DIR"
for file in "$APP_SUPPORT/config.json" "$APP_SUPPORT/state.json" "$APP_SUPPORT/session.json" "$LOG_DIR/insomnia.log"; do
  if [[ -f "$file" ]]; then /bin/chmod 600 "$file"; fi
done
stage="$(/usr/bin/mktemp -d "$APP_DIR/.insomnia-install.XXXXXX")"
bundle="$stage/Insomnia.app"
/bin/mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
/bin/cp "$BIN" "$bundle/Contents/MacOS/Insomnia"
/bin/cp "$ROOT/Resources/Info.plist" "$bundle/Contents/Info.plist"
/bin/cp "$ROOT/Resources/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -replace InsomniaMaintenanceProtocol -string insomnia-maintenance-v1 "$bundle/Contents/Info.plist"
/usr/bin/plutil -lint "$bundle/Contents/Info.plist" >/dev/null
/usr/bin/codesign --force --sign - --deep "$bundle"
/usr/bin/codesign --verify --deep --strict "$bundle"

/bin/cp "$bundle/Contents/MacOS/Insomnia" "$stage/InsomniaRecovery"
/bin/chmod 700 "$stage/InsomniaRecovery"
digest="$(/usr/bin/shasum -a 256 "$stage/InsomniaRecovery")"
printf 'insomnia-maintenance-v1 %s\n' "${digest%% *}" > "$stage/InsomniaRecovery.protocol"
/bin/cp "$ROOT/scripts/backstop.sh" "$stage/backstop.sh"

# plutil serializes paths, including &, < and non-ASCII home-directory names.
new_plist="$stage/backstop.plist"
/usr/bin/plutil -create xml1 "$new_plist"
/usr/bin/plutil -insert Label -string "$LABEL" "$new_plist"
/usr/bin/plutil -insert ProgramArguments -xml '<array/>' "$new_plist"
/usr/bin/plutil -insert ProgramArguments.0 -string /bin/bash "$new_plist"
/usr/bin/plutil -insert ProgramArguments.1 -string "$APP_SUPPORT/backstop.sh" "$new_plist"
/usr/bin/plutil -insert RunAtLoad -bool true "$new_plist"
/usr/bin/plutil -insert KeepAlive -xml '<dict/>' "$new_plist"
/usr/bin/plutil -insert KeepAlive.SuccessfulExit -bool false "$new_plist"
/usr/bin/plutil -insert ThrottleInterval -integer 60 "$new_plist"
/usr/bin/plutil -lint "$new_plist" >/dev/null
{
  printf '# Insomnia owner UID: %s\n' "$UID_NUM"
  for mode in 1 0; do
    printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep %s\n' "$ACCOUNT" "$mode"
    printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode %s\n' "$ACCOUNT" "$mode"
  done
} > "$stage/sudoers"
/usr/bin/sudo /usr/sbin/visudo -cf "$stage/sudoers" >/dev/null
# Finish any newly reopened app before taking the lease its cleanup needs.
quit_app
export ROOT UID_NUM APP APP_SUPPORT LOG_DIR LABEL PLIST SUDOERS stage bundle new_plist
export -f app_running unload_agent
/usr/bin/lockf -k -t 30 "$APP_SUPPORT/recovery.lock" /bin/bash -seu -o pipefail <<'COMMIT'
# Do not request an asynchronous app quit while holding its recovery lease.
if app_running; then
  echo "Insomnia reopened before commit; quit it and retry. Existing installation retained." >&2
  exit 1
fi
# Restore the exact prior privilege grant on failed commit paths. A newly
# supplied grant stays only when incomplete recovery still needs it.
had_grant=0
recovery_incomplete=0
if /usr/bin/sudo /bin/test -e "$SUDOERS"; then
  /usr/bin/sudo /bin/cat "$SUDOERS" > "$stage/previous.sudoers"
  had_grant=1
fi
restore_grant() {
  if (( had_grant == 1 )); then
    /usr/bin/sudo /usr/bin/install -m 0440 -o root -g wheel "$stage/previous.sudoers" "$SUDOERS"
  elif (( recovery_incomplete == 1 )); then
    echo "New narrow command grant retained for pending recovery; rerun install after cleanup succeeds." >&2
  else /usr/bin/sudo /bin/rm -f "$SUDOERS"; fi
}
rollback_grant() {
  status=$?
  trap - EXIT
  if (( status != 0 )); then
    if ! restore_grant; then
      /usr/bin/touch "$stage/rollback-failed"
      echo "Restoring the previous sudoers grant failed; inspect retained rollback files." >&2
    fi
  fi
  exit "$status"
}
trap rollback_grant EXIT
/usr/bin/sudo /usr/bin/install -m 0440 -o root -g wheel "$stage/sudoers" "$SUDOERS"
if ! /usr/bin/sudo -n -l /usr/bin/pmset -a disablesleep 0; then
  echo "Sudoers verification failed; existing installation retained." >&2; exit 1
fi
if ! /bin/bash "$ROOT/scripts/backstop.sh" --locked --force --helper "$stage/InsomniaRecovery"; then
  recovery_incomplete=1
  echo "Restoration incomplete; existing app and recovery files retained. Retry after recovery." >&2; exit 1
fi
# Pair replacement is serialized by recovery.lock. Each file is atomically
# renamed; any failure rolls the entire generation and app bundle back.
for name in backstop.sh InsomniaRecovery InsomniaRecovery.protocol; do
  if [[ -e "$APP_SUPPORT/$name" ]]; then /bin/cp -p "$APP_SUPPORT/$name" "$stage/previous.$name"; fi
done
if [[ -f "$PLIST" ]]; then /bin/cp -p "$PLIST" "$stage/previous.plist"; fi
unload_agent
app_moved=0
new_app=0
rollback() {
  status=$?
  (( status != 0 )) || return 0
  trap - EXIT
  rollback_failed=0
  if (( new_app == 1 )); then /bin/mv "$APP" "$bundle" || rollback_failed=1; fi
  if (( app_moved == 1 )); then
    if [[ ! -e "$APP" ]]; then /bin/mv "$stage/previous.app" "$APP" || rollback_failed=1
    else rollback_failed=1; fi
  fi
  for name in backstop.sh InsomniaRecovery InsomniaRecovery.protocol; do
    if [[ -e "$stage/previous.$name" ]]; then
      /bin/cp -p "$stage/previous.$name" "$APP_SUPPORT/.$name.new" &&
        /bin/mv -f "$APP_SUPPORT/.$name.new" "$APP_SUPPORT/$name" || rollback_failed=1
    else /bin/rm -f "$APP_SUPPORT/$name" || rollback_failed=1; fi
    /bin/rm -f "$APP_SUPPORT/.$name.new" || rollback_failed=1
  done
  if [[ -f "$stage/previous.plist" ]]; then
    /bin/cp -p "$stage/previous.plist" "$PLIST" || rollback_failed=1
    if ! /bin/launchctl bootstrap "gui/$UID_NUM" "$PLIST"; then
      echo "Reloading the previous recovery job also failed. No recovery agent is confirmed loaded; re-run install successfully before using Insomnia." >&2
      rollback_failed=1
    fi
  else /bin/rm -f "$PLIST" || rollback_failed=1; fi
  restore_grant || rollback_failed=1
  if (( rollback_failed != 0 )); then /usr/bin/touch "$stage/rollback-failed"; fi
  echo "Installation failed; previous app and recovery generation retained." >&2
  exit "$status"
}
trap rollback EXIT
for name in InsomniaRecovery InsomniaRecovery.protocol backstop.sh; do
  /bin/cp "$stage/$name" "$APP_SUPPORT/.$name.new"
  if [[ "$name" == *.protocol ]]; then mode=600; else mode=700; fi
  /bin/chmod "$mode" "$APP_SUPPORT/.$name.new"
  /bin/mv -f "$APP_SUPPORT/.$name.new" "$APP_SUPPORT/$name"
done
/bin/cp "$new_plist" "$PLIST"
/bin/chmod 600 "$PLIST"
if [[ -e "$APP" ]]; then /bin/mv "$APP" "$stage/previous.app"; app_moved=1; fi
/bin/mv "$bundle" "$APP"
new_app=1
/bin/launchctl bootstrap "gui/$UID_NUM" "$PLIST"
trap - EXIT
echo "Installed: $APP"
echo "Config: $APP_SUPPORT/config.json; logs: $LOG_DIR"
COMMIT
