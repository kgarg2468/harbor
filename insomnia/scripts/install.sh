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
    if (( status != 0 )) && [[ -e "$stage/previous.app" ]]; then
      echo "Previous app retained for recovery at $stage/previous.app" >&2
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
# Building can take minutes; the app may have been reopened since the first check.
quit_app
/bin/mkdir -p "$APP_DIR" "$APP_SUPPORT" "$LOG_DIR" "$HOME/Library/LaunchAgents"
/bin/chmod 700 "$APP_SUPPORT" "$LOG_DIR"
for file in "$APP_SUPPORT/config.json" "$APP_SUPPORT/state.json" "$APP_SUPPORT/session.json" "$LOG_DIR/insomnia.log"; do
  if [[ -f "$file" ]]; then /bin/chmod 600 "$file"; fi
done
stage="$(/usr/bin/mktemp -d "$APP_DIR/.insomnia-install.XXXXXX")"
bundle="$stage/Insomnia.app"
/bin/mkdir -p "$bundle/Contents/MacOS"
/bin/cp "$BIN" "$bundle/Contents/MacOS/Insomnia"
/bin/cp "$ROOT/Resources/Info.plist" "$bundle/Contents/Info.plist"
/usr/bin/plutil -lint "$bundle/Contents/Info.plist" >/dev/null
/usr/bin/codesign --force --sign - --deep "$bundle"
/usr/bin/codesign --verify --deep --strict "$bundle"

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
/usr/bin/sudo /usr/bin/install -m 0440 -o root -g wheel "$stage/sudoers" "$SUDOERS"
if ! /usr/bin/sudo -n -l /usr/bin/pmset -a disablesleep 0; then
  echo "Sudoers verification failed; existing installation retained." >&2; exit 1
fi
if ! /bin/bash "$ROOT/scripts/backstop.sh" --locked --force; then
  echo "Restoration incomplete; existing app and recovery files retained. Retry after recovery." >&2; exit 1
fi
# No teardown until recovery succeeds. Keep the previous agent plist for rollback.
if [[ -f "$PLIST" ]]; then /bin/cp "$PLIST" "$stage/previous.plist"; fi
unload_agent
/bin/cp "$ROOT/scripts/backstop.sh" "$APP_SUPPORT/backstop.sh"
/bin/chmod 700 "$APP_SUPPORT/backstop.sh"
/bin/cp "$new_plist" "$PLIST"
/bin/chmod 600 "$PLIST"
if ! /bin/launchctl bootstrap "gui/$UID_NUM" "$PLIST"; then
  if [[ -f "$stage/previous.plist" ]]; then
    /bin/cp "$stage/previous.plist" "$PLIST"
    /bin/launchctl bootstrap "gui/$UID_NUM" "$PLIST" || true
  fi
  echo "LaunchAgent installation failed; existing app retained." >&2; exit 1
fi
if [[ -e "$APP" ]]; then /bin/mv "$APP" "$stage/previous.app"; fi
if ! /bin/mv "$bundle" "$APP"; then
  if [[ -d "$stage/previous.app" ]]; then /bin/mv "$stage/previous.app" "$APP"; fi
  exit 1
fi
echo "Installed: $APP"
echo "Config: $APP_SUPPORT/config.json; logs: $LOG_DIR"
COMMIT
