#!/bin/bash
# Recovery must succeed before removing any installed recovery capability.
PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h|--help) echo "usage: $0 [--purge]"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
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

/bin/mkdir -p "$APP_SUPPORT"
export ROOT UID_NUM APP APP_SUPPORT LOG_DIR LABEL PLIST SUDOERS PURGE
export -f app_running unload_agent
/usr/bin/lockf -k -t 30 "$APP_SUPPORT/recovery.lock" /bin/bash -seu -o pipefail <<'COMMIT'
if app_running; then
  echo "Insomnia reopened before teardown; quit it and retry. Installed files retained." >&2
  exit 1
fi
# Use the current source recovery implementation, even when an old installed
# helper returned success on partial recovery. Session invalidation is locked.
if ! /bin/bash "$ROOT/scripts/backstop.sh" --locked --force; then
  echo "Restoration incomplete; journal, helper, grant and app retained. Retry after recovery." >&2
  exit 1
fi
unload_agent
/bin/rm -f "$PLIST"
/usr/bin/sudo /bin/rm -f "$SUDOERS"
/bin/rm -rf "$APP"
if (( PURGE == 1 )); then
  # Never unlink recovery.lock: an existing waiter may still hold its inode.
  for file in "$APP_SUPPORT"/* "$APP_SUPPORT"/.[!.]* "$APP_SUPPORT"/..?*; do
    [[ "${file##*/}" == recovery.lock ]] || /bin/rm -rf "$file"
  done
  if [[ "$LOG_DIR" != "$APP_SUPPORT" ]]; then /bin/rm -rf "$LOG_DIR"; fi
else
  /bin/rm -f "$APP_SUPPORT/backstop.sh" "$APP_SUPPORT/state.json"
  echo "Kept config and logs (use --purge to remove)."
fi
echo "Uninstalled. The persistent recovery.lock file is retained."
COMMIT
