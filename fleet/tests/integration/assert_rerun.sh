#!/bin/bash
# The second run: inspection-first idempotency (design section 6.1). A rerun on a
# healthy node must make no mutating vendor call at all and must add no journal
# entry that claims to have created or modified anything.
#
# A word on "no new journal entries". Harbor journals an observed applied entry
# for every already-correct row on every run, by design: that is how a rerun
# records what it found rather than staying silent about it. A literal "no new
# entries" is therefore not a property this system has, and asserting it would be
# asserting something false. What design section 7's own test map asks for, and
# what this asserts, is "no new created or modified entry" -- together with a
# byte-identical mutating-call log, which is the stronger half: not one vendor
# command that changes anything was issued. The observed delta is printed, so the
# number is visible rather than swallowed.
#
# Runs as the unprivileged workflow user, because it drives the rerun through
# run_root.sh and so has to be the SUDO_USER Harbor copies an authorized key
# from. Privileged reads go through individual sudo commands; there is no sudo -E
# anywhere and no hook variable is passed at all.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${0}")" && pwd -P)/lib/common.sh"

[ "$(id -u)" != 0 ] || {
  printf 'assert_rerun.sh runs as the workflow user, not as root\n' >&2
  exit 1
}

# --after-recovery: as in assert_bootstrap.sh. This node reached its state through a
# crash and a rerun, so the journal may carry an entry the recovery scan reverted.
after_recovery=0
case "${1:-}" in
  --after-recovery) after_recovery=1 ;;
  '') ;;
  *)
    printf 'assert_rerun.sh: unknown argument %s\n' "${1}" >&2
    exit 1
    ;;
esac

snapshot="$(mktemp -d)"
trap 'rm -rf "${snapshot}"' EXIT

section() {
  printf '\n-- %s\n' "${*}"
}

# copy_journal DEST -- a readable copy of the root-owned journal.
copy_journal() {
  rm -rf "${1}"
  sudo cp -a "${IT_HARBOR_JOURNAL}" "${1}"
  sudo chown -R "$(id -un)" "${1}"
  sudo chmod -R u+rwX "${1}"
}

# mut_count FILE PROGRAM -- mutating calls to PROGRAM recorded in FILE.
mut_count() {
  awk -F '\t' -v prog="${2}" '$3 == prog { n++ } END { printf "%d", n + 0 }' "${1}"
}

# ---------------------------------------------------------------------------
section 'snapshot of the converged node'
# ---------------------------------------------------------------------------
cp "${IT_MUT_LOG}" "${snapshot}/mutations.before"
before_mutations="$(sha256sum "${IT_MUT_LOG}" | cut -d ' ' -f 1)"
before_shim_lines="$(wc -l <"${IT_SHIM_LOG}")"
before_record="$(sudo sha256sum "${IT_HARBOR_RECORD}" | cut -d ' ' -f 1)"
copy_journal "${snapshot}/journal.before"
ls -1 "${snapshot}/journal.before" | LC_ALL=C sort >"${snapshot}/names.before"
printf 'mutating calls so far:  %s\n' "$(wc -l <"${IT_MUT_LOG}")"
printf 'journal entries so far: %s\n' "$(wc -l <"${snapshot}/names.before")"

# ---------------------------------------------------------------------------
section 'the second run'
# ---------------------------------------------------------------------------
rc=0
"${IT_INTEGRATION}/run_root.sh" --from installed || rc="$?"
it_eq 'the second run exits 0' 0 "${rc}"

# ---------------------------------------------------------------------------
section 'zero mutating vendor calls'
# ---------------------------------------------------------------------------
after_mutations="$(sha256sum "${IT_MUT_LOG}" | cut -d ' ' -f 1)"
if [ "${after_mutations}" = "${before_mutations}" ]; then
  it_pass 'the mutating-call log is byte for byte what it was before the rerun'
else
  it_fail 'the rerun made mutating vendor calls'
  diff_rc=0
  mut_diff="$(diff "${snapshot}/mutations.before" "${IT_MUT_LOG}")" || diff_rc="$?"
  printf 'mutating-call diff (rc %s):\n%s\n' "${diff_rc}" "${mut_diff}" >&2
fi
for prog in ufw systemctl loginctl tailscale apt-get curl; do
  it_eq "mutating ${prog} calls" \
    "$(mut_count "${snapshot}/mutations.before" "${prog}")" "$(it_mutations "${prog}")"
done

# apt-get and curl are not called at all on a converged node: the packages row
# finds every package installed, the Tailscale row finds the pinned version, and
# neither reaches for a vendor source.
after_shim_lines="$(wc -l <"${IT_SHIM_LOG}")"
tail -n "+$((before_shim_lines + 1))" "${IT_SHIM_LOG}" >"${snapshot}/calls.rerun"
printf 'vendor calls the rerun made (%s in total):\n' "$((after_shim_lines - before_shim_lines))"
cat "${snapshot}/calls.rerun"
for prog in apt-get curl; do
  it_eq "${prog} calls of any kind during the rerun" 0 \
    "$(awk -F '\t' -v prog="${prog}" '$3 == prog { n++ } END { printf "%d", n + 0 }' "${snapshot}/calls.rerun")"
done

# ---------------------------------------------------------------------------
section 'no new created or modified journal entry'
# ---------------------------------------------------------------------------
copy_journal "${snapshot}/journal.after"
ls -1 "${snapshot}/journal.after" | LC_ALL=C sort >"${snapshot}/names.after"
comm -13 "${snapshot}/names.before" "${snapshot}/names.after" >"${snapshot}/names.new"
new_written=0
new_observed=0
while IFS= read -r entry; do
  [ -n "${entry}" ] || continue
  ownership="$(it_journal_field "${snapshot}/journal.after/${entry}" ownership)"
  case "${ownership}" in
    observed) new_observed=$((new_observed + 1)) ;;
    *)
      new_written=$((new_written + 1))
      it_fail "the rerun journalled ${entry} as ${ownership}"
      ;;
  esac
done <"${snapshot}/names.new"
it_eq 'new created or modified entries' 0 "${new_written}"
printf 'the rerun journalled %s new observed entries. That is what an inspection-first\n' "${new_observed}"
printf 'rerun records: already-correct state, observed and applied, mutating nothing.\n'

phases=""
for entry in "${snapshot}/journal.after"/*.json; do
  phases="${phases}$(it_journal_field "${entry}" phase)
"
done
phases="$(printf '%s' "${phases}" | LC_ALL=C sort -u | tr -d '\n')"
if [ "${after_recovery}" = 1 ]; then
  # A reverted entry is the recovery scan of the earlier rerun having decided the
  # crashed mutation never happened, and this second rerun leaves it exactly as it
  # found it. What matters here is that nothing moved back to prepared and nothing
  # became undecidable, not that the crash left no trace.
  case "${phases}" in
    applied | appliedreverted | reverted)
      it_pass "every entry is still applied or reverted (${phases})"
      ;;
    *) it_fail "a journal entry is neither applied nor reverted: ${phases}" ;;
  esac
else
  it_eq 'every entry is still applied' applied "${phases}"
fi

# ---------------------------------------------------------------------------
section 'the state record is untouched'
# ---------------------------------------------------------------------------
it_eq 'bootstrap.json is unchanged by the rerun' "${before_record}" \
  "$(sudo sha256sum "${IT_HARBOR_RECORD}" | cut -d ' ' -f 1)"

# ---------------------------------------------------------------------------
section 'the installed entrypoint preflight refuses a different flag set'
# ---------------------------------------------------------------------------
# The flag binding happens in the preflight, before the install step and before
# any mutation, so a run whose normalized flag set differs from the bound one
# exits 3 having changed nothing. That is the installed-entrypoint preflight
# proving itself on a node the journal says is already bootstrapped.
rc=0
"${IT_INTEGRATION}/run_root.sh" --from installed -- --harden-sshd || rc="$?"
it_eq 'a differing flag set is a precondition failure' 3 "${rc}"
it_eq 'and it mutated nothing' "${after_mutations}" \
  "$(sha256sum "${IT_MUT_LOG}" | cut -d ' ' -f 1)"
it_file_absent 'the global hardening drop-in was never written' \
  /etc/ssh/sshd_config.d/51-harbor-global.conf

it_done 'assert_rerun'
