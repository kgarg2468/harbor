#!/bin/bash
# Recovery holds the persistent BSD flock inode shared with the app journal.
set -euo pipefail
umask 077
APP_SUPPORT="${INSOMNIA_HOME:-$HOME/Library/Application Support/Insomnia}"
LOG_DIR="${INSOMNIA_HOME:+$INSOMNIA_HOME/Logs}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/Insomnia}"
HELPER="$APP_SUPPORT/InsomniaRecovery"
original_args=("$@")
force=0
locked=0
while (( $# )); do
  case "$1" in
    --force) force=1 ;;
    --locked) locked=1 ;;
    --helper) [[ $# -ge 2 && "$2" == /* ]] || exit 2; HELPER="$2"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
SESSION="$APP_SUPPORT/session.json"
STATE="$APP_SUPPORT/state.json"
PLUTIL=/usr/bin/plutil
/bin/mkdir -p "$APP_SUPPORT"
/bin/chmod 700 "$APP_SUPPORT"
if (( locked == 0 )); then
  # -k retains the inode for existing waiters. The child inherits INSOMNIA_HOME.
  exec /usr/bin/lockf -k -t 30 "$APP_SUPPORT/recovery.lock" /bin/bash "$0" --locked ${original_args[@]+"${original_args[@]}"}
fi
log() {
  # Logging is bounded and private, and every failure is independent of recovery.
  (
    /bin/mkdir -p "$LOG_DIR" || exit 0
    /bin/chmod 700 "$LOG_DIR" || exit 0
    file="$LOG_DIR/insomnia.log"
    [[ ! -e "$file" ]] || /bin/chmod 600 "$file" || exit 0
    record="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ) backstop: $*"
    size=0
    [[ ! -f "$file" ]] || size="$(/usr/bin/wc -c < "$file")" || exit 0
    if (( size + ${#record} + 1 > 262144 )); then
      archive="$(/usr/bin/mktemp "$LOG_DIR/.backstop-log.XXXXXX")" || exit 0
      trap '/bin/rm -f "$archive"' EXIT
      if (( size > 262144 )); then
        /usr/bin/tail -c 262144 "$file" | /usr/bin/sed '1d' > "$archive" || exit 0
      else /bin/cp "$file" "$archive" || exit 0; fi
      /bin/chmod 600 "$archive" || exit 0
      /bin/mv -f "$archive" "$file.1" || exit 0
      : > "$file" || exit 0
    fi
    if [[ -f "$file.1" ]]; then
      /bin/chmod 600 "$file.1" || exit 0
      backup_size="$(/usr/bin/wc -c < "$file.1")" || exit 0
      if (( backup_size > 262144 )); then
        archive="$(/usr/bin/mktemp "$LOG_DIR/.backstop-log.XXXXXX")" || exit 0
        trap '/bin/rm -f "$archive"' EXIT
        /usr/bin/tail -c 262144 "$file.1" | /usr/bin/sed '1d' > "$archive" || exit 0
        /bin/chmod 600 "$archive" || exit 0
        /bin/mv -f "$archive" "$file.1" || exit 0
      fi
    fi
    printf '%s\n' "$record" >> "$file" || exit 0
    /bin/chmod 600 "$file" || exit 0
  ) 2>/dev/null || true
}
extract() { "$PLUTIL" -extract "$2" raw -o - "$1" 2>/dev/null; }
if (( force == 0 )) && [[ -f "$SESSION" ]]; then
  ends_at="$(extract "$SESSION" endsAt || true)"
  ends_epoch="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ends_at" +%s 2>/dev/null || true)"
  if [[ "$ends_epoch" =~ ^[0-9]+$ ]] && (( ends_epoch > $(/bin/date -u +%s) )); then exit 0; fi
fi
failed=0
/bin/rm -f "$SESSION" || failed=1
[[ -e "$STATE" ]] || exit "$failed"
log "restoring expired or ended session"
tmp="$(/usr/bin/mktemp "$APP_SUPPORT/.state.XXXXXX")"
trap '/bin/rm -f "$tmp"' EXIT
if ! "$PLUTIL" -convert json -o "$tmp" "$STATE" >/dev/null 2>&1; then
  log "unreadable state retained; recovery incomplete"; exit 1
fi
IFS= read -r -n 1 root_kind < "$tmp"
[[ "$root_kind" == '{' ]] || exit 1
# Power restoration is independent of the native helper. Never infer booleans
# from strings/numbers/null, and never signal or discard native ownership here.
for key in sleepDisabledByUs lowPowerSetByUs originalSleepDisabled originalBatteryLowPowerMode; do
  kind="$("$PLUTIL" -type "$key" "$tmp" 2>/dev/null || true)"
  if [[ -n "$kind" && "$kind" != bool ]]; then log "unsupported power state retained"; exit 1; fi
done
for spec in frozenPids:array frozenProcesses:array dockerFrozen:bool savedOutputVolume:float savedMuted:bool savedOutputDeviceUID:string; do
  key="${spec%%:*}"; expected="${spec#*:}"
  kind="$("$PLUTIL" -type "$key" "$tmp" 2>/dev/null || true)"
  if [[ -n "$kind" && "$kind" != "$expected" && ! ( "$expected" == float && "$kind" == integer ) ]]; then
    log "unsupported owned state retained"; exit 1
  fi
done
# A hash-bound marker prevents accidentally launching an old GUI binary.
digest="$(/usr/bin/shasum -a 256 "$HELPER" 2>/dev/null || true)"
marker="$(/bin/cat "$HELPER.protocol" 2>/dev/null || true)"
if [[ -x "$HELPER" && -n "$digest" && "$marker" == "insomnia-maintenance-v1 ${digest%% *}" ]]; then
  "$HELPER" --validate-recovery-state "$tmp" || exit 1
  # The helper never takes another lease. Import successful partial work even
  # when it returns nonzero for remaining process/device/legacy ownership.
  "$HELPER" --recover-owned "$tmp" || failed=1
  "$HELPER" --validate-recovery-state "$tmp" || exit 1
else
  for key in frozenPids frozenProcesses; do
    entries="$("$PLUTIL" -extract "$key" json -o - "$tmp" 2>/dev/null | /usr/bin/tr -d '[:space:]' || true)"
    if [[ -n "$entries" && "$entries" != '[]' ]]; then failed=1; fi
  done
  [[ "$(extract "$tmp" dockerFrozen || echo false)" != true ]] || failed=1
  for key in savedOutputVolume savedMuted savedOutputDeviceUID; do
    if "$PLUTIL" -type "$key" "$tmp" >/dev/null 2>&1; then failed=1; fi
  done
  if (( failed != 0 )); then
    log "compatible native helper unavailable; owned entries retained"
    echo "Native recovery requires a compatible InsomniaRecovery helper; rerun the current installer." >&2
  fi
fi
restore_power() {
  flag="$1"; original="$2"; scope="$3"; setting="$4"
  owned="$(extract "$tmp" "$flag" || echo false)"
  prior="$(extract "$tmp" "$original" || true)"
  if [[ "$owned" == true || -n "$prior" ]]; then
    value=0
    [[ "$prior" != true ]] || value=1
    if /usr/bin/sudo -n /usr/bin/pmset "$scope" "$setting" "$value"; then
      "$PLUTIL" -replace "$flag" -bool false "$tmp" >/dev/null
      if [[ -n "$prior" ]]; then "$PLUTIL" -remove "$original" "$tmp" >/dev/null; fi
    else failed=1; fi
  fi
}
restore_power sleepDisabledByUs originalSleepDisabled -a disablesleep
restore_power lowPowerSetByUs originalBatteryLowPowerMode -b lowpowermode
/bin/chmod 600 "$tmp"
/bin/mv -f "$tmp" "$STATE"
if (( failed == 0 )); then log "recovery complete"; else log "recovery incomplete; retained journal requires retry"; fi
exit "$failed"
