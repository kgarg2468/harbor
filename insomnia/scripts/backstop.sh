#!/bin/bash
# Independent recovery. Recovery uses the persistent BSD flock inode shared with the app journal.
# INSOMNIA_HOME relocates journals/logs; launchd must receive the same environment.
set -euo pipefail
umask 077
force=0
locked=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --locked) locked=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
APP_SUPPORT="${INSOMNIA_HOME:-$HOME/Library/Application Support/Insomnia}"
LOG_DIR="${INSOMNIA_HOME:+$INSOMNIA_HOME/Logs}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/Insomnia}"
SESSION="$APP_SUPPORT/session.json"
STATE="$APP_SUPPORT/state.json"
PLUTIL=/usr/bin/plutil
SUDO=/usr/bin/sudo
PMSET=/usr/bin/pmset
/bin/mkdir -p "$APP_SUPPORT"
/bin/chmod 700 "$APP_SUPPORT"
if (( locked == 0 )); then
  # -k retains the lock file: deleting it would allow concurrent locks on two inodes.
  exec /usr/bin/lockf -k -t 30 "$APP_SUPPORT/recovery.lock" /bin/bash "$0" --locked "$@"
fi
log() {
  { /bin/mkdir -p "$LOG_DIR" && /bin/chmod 700 "$LOG_DIR" &&
    printf '%s backstop: %s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_DIR/insomnia.log" &&
    /bin/chmod 600 "$LOG_DIR/insomnia.log"; } 2>/dev/null || true
}
extract() { "$PLUTIL" -extract "$2" raw -o - "$1" 2>/dev/null; }
if (( force == 0 )) && [[ -f "$SESSION" ]]; then
  ends_at="$(extract "$SESSION" endsAt || true)"
  ends_epoch="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ends_at" +%s 2>/dev/null || true)"
  if [[ "$ends_epoch" =~ ^[0-9]+$ ]] && (( ends_epoch > $(/bin/date -u +%s) )); then exit 0; fi
fi
failed=0
# Invalidate under the lock so a later app launch cannot revive an ended session.
/bin/rm -f "$SESSION" || failed=1
log "restoring expired or ended session"
sleep_ok=0
if "$SUDO" -n "$PMSET" -a disablesleep 0; then sleep_ok=1; else failed=1; fi
# Never replace an unreadable journal: it may be the only record of outstanding work.
tmp="$(/usr/bin/mktemp "$APP_SUPPORT/.state.XXXXXX")"
trap '/bin/rm -f "$tmp"' EXIT
if [[ -e "$STATE" ]]; then
  if ! "$PLUTIL" -convert json -o "$tmp" "$STATE" >/dev/null 2>&1; then
    log "unreadable state retained; recovery incomplete"; exit 1
  fi
else
  printf '{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenPids":[],"dockerFrozen":false}\n' > "$tmp"
fi
low_power="$(extract "$tmp" lowPowerSetByUs || echo false)"
low_ok=1
if [[ "$low_power" == true ]]; then
  if ! "$SUDO" -n "$PMSET" -b lowpowermode 0; then low_ok=0; failed=1; fi
elif [[ "$low_power" != false ]]; then low_ok=0; failed=1; fi

kind="$("$PLUTIL" -type frozenPids "$tmp" 2>/dev/null || true)"
if [[ -z "$kind" ]]; then pids='[]'
elif [[ "$kind" == array ]]; then
  pids="$("$PLUTIL" -extract frozenPids json -o - "$tmp" 2>/dev/null || echo invalid)"
else pids=invalid; fi
pids="$(printf '%s' "$pids" | /usr/bin/tr -d '[:space:]')"
valid=1
pid_pattern='^\[([1-9][0-9]*(,[1-9][0-9]*)*)?\]$'
[[ "$pids" =~ $pid_pattern ]] || valid=0
pid_list=()
if (( valid == 1 )); then
  values="${pids#\[}"; values="${values%\]}"
  if [[ -n "$values" ]]; then IFS=, read -r -a pid_list <<< "$values"; fi
  for pid in ${pid_list[@]+"${pid_list[@]}"}; do
    if (( ${#pid} > 10 )) || (( pid > 2147483647 )); then valid=0; fi
  done
fi
remaining=''
if (( valid == 1 )); then
  for pid in ${pid_list[@]+"${pid_list[@]}"}; do
    if ! /bin/kill -CONT "$pid" 2>/dev/null; then
      # kill cannot distinguish ESRCH from EPERM. A successful process lookup
      # means retry; ps exit 1 with no record means this PID has already exited.
      lookup_status=0
      record="$(/bin/ps -p "$pid" -o pid= 2>/dev/null)" || lookup_status=$?
      if [[ -n "$record" ]] || (( lookup_status != 1 )); then
        remaining="${remaining:+$remaining,}$pid"; failed=1
      fi
    fi
  done
else failed=1; log "invalid PID array retained without signaling"; fi

# Stage all journal changes; a failed edit never damages the original journal.
edit() { "$PLUTIL" -replace "$1" "$2" "$3" "$tmp" >/dev/null 2>&1; }
if (( sleep_ok == 1 )); then edit sleepDisabledByUs -bool false; else edit sleepDisabledByUs -bool true; fi
if (( low_ok == 1 )); then edit lowPowerSetByUs -bool false; fi
if (( valid == 1 )); then
  edit frozenPids -json "[$remaining]"
  if [[ -z "$remaining" ]]; then edit dockerFrozen -bool false; fi
fi
# Shell cannot safely restore audio; preserve its original values for the app/helper.
for key in savedMuted savedOutputVolume; do
  kind="$("$PLUTIL" -type "$key" "$tmp" 2>/dev/null || true)"
  if [[ -n "$kind" && "$kind" != null ]]; then failed=1; fi
done
/bin/chmod 600 "$tmp"
/bin/mv -f "$tmp" "$STATE"
if (( failed == 0 )); then log "recovery complete"; else log "recovery incomplete; retained journal requires retry"; fi
exit "$failed"
