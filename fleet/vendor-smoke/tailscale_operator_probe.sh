#!/bin/bash
# The Tailscale half of the vendor-smoke lane (design section 7): a real install of the
# pinned Tailscale from the pinned channel, a real tailscaled started from its packaged
# systemd unit and never logged in, and the measurements the "Preserved pre-state" row
# of the section 7 test map asks this lane to record -- whether tailscale get operator
# exists on the pinned version and whether it prints an exact value, what
# sudo tailscale set --operator answers, what tailscale status --json answers for the
# configured operator and for an ordinary user who is not the operator, and the section
# 3.6 probe itself: whether that operator can run the exact
#   tailscale up --hostname=harbor-node --ssh
# form without sudo, or whether the daemon refuses it.
#
# Usage: fleet/vendor-smoke/tailscale_operator_probe.sh <record-file>
#
# The record is one key=value line per measurement, in the shape
# fleet/vendor-smoke/tailscale-ssh.probe carries, so a human can transcribe this run's
# answer into that file verbatim. lib/auth.sh reads date, tailscale_version, and result
# out of it and ignores every other key, so the extra keys here are for the reviewer.
# This script never writes that file itself: the gate's record is a human's to move,
# from a run whose verdict a human has read.
#
# There is no Tailscale account in this lane, no auth key, and no tailnet. The daemon is
# started and left logged out, which is the state a freshly bootstrapped Harbor node is
# in when harbor auth tailscale is first run, and it is the only state the section 3.6
# question is worth asking in.
#
# Nothing the vendor prints ever leaves this runner. tailscale up prints a login URL the
# moment it proceeds, and that URL is a bearer capability for this node: every vendor
# invocation below writes to a file under a private working directory, is classified
# there against markers this file chose, and contributes to the record only a word this
# file chose. No vendor byte reaches the record, the step summary, the artifact, or the
# job log, and the working directory is removed on every exit path.
#
# Runs as the unprivileged workflow user and reaches for sudo one action at a time, the
# way fleet/tests/integration/setup.sh does. It never uses sudo -E.
set -euo pipefail

# The exact form of design section 3.6, spelled once. It is the whole question this lane
# exists to answer, so it is written here as the operator would type it and passed to the
# vendor as those three words.
SSH_PROBE_HOSTNAME="harbor-node"
# Long enough for a daemon that accepts the flag to reach its login step and print, short
# enough that a job is not held by a command that waits for a human who will never come.
SSH_PROBE_TIMEOUT_SECONDS=45
# The two throwaway accounts. Neither is the runner user and neither is root: the whole
# point of the reading is what an ordinary unprivileged account is answered, and an
# account that could sudo would be measuring root's authority wearing another name.
PROBE_OPERATOR="harbor-smoke-operator"
PROBE_OTHER="harbor-smoke-other"

self_dir="$(cd "$(dirname "${0}")" && pwd -P)"
lock="${self_dir}/../versions.lock"
record="${1:?usage: tailscale_operator_probe.sh <record-file>}"

fail() {
  printf '\ntailscale_operator_probe.sh: %s\n' "${*}" >&2
  exit 1
}

banner() {
  printf '\n========================================================================\n'
  printf '%s\n' "${*}"
  printf '========================================================================\n'
}

# lock_value KEY: the single locked value for KEY. Every pinned value this lane installs
# is read here, at runtime, from the lock the repository ships; no version is spelled in
# this file or in the workflow that calls it.
lock_value() {
  local value
  value="$(sed -n "s/^${1}=//p" "${lock}" | sed -n 1p)"
  [ -n "${value}" ] || fail "${lock} has no value for ${1}"
  printf '%s' "${value}"
}

[ "$(id -u)" != 0 ] || fail 'this lane runs as the workflow user, not as root'
sudo -n true || fail 'this lane needs passwordless sudo on a throwaway runner'
# An auth key in the environment would turn the one command below into a real login, and
# a real login is exactly what this lane must never perform: it holds no account, and a
# node it logged in would be a node nobody owns. Refused before anything is installed.
for leaked in TS_AUTHKEY TAILSCALE_AUTHKEY TS_AUTH_KEY; do
  eval "value=\${${leaked}:-}"
  [ -z "${value}" ] || fail "${leaked} is set in this environment; the vendor-smoke lane holds no Tailscale credential and will not run beside one"
done

tailscale_version="$(lock_value tailscale_version)"
channel="$(lock_value tailscale_apt_channel)"
ubuntu_release="$(lock_value ubuntu_release)"
track="${channel%/*}"
codename="${channel##*/}"

# The private working directory every vendor capture is written into. It is removed on
# every exit path, successful or not, so that no later step of the job can find a login
# URL lying on the filesystem and no artifact upload can sweep one up by accident.
work=""
cleanup() {
  [ -z "${work}" ] || rm -rf "${work}"
}
trap cleanup EXIT
work="$(mktemp -d)"
chmod 0700 "${work}"
: >"${work}/record"

# emit KEY VALUE: one line of the record. Everything that reaches this function is a
# word this file chose, an exit status, or a value read out of versions.lock.
emit() {
  printf '%s=%s\n' "${1}" "${2}" >>"${work}/record"
}

# publish: the record, three times over -- the job log, the step summary, and the file
# the workflow uploads as the artifact -- from the one file every line was appended to,
# so the three cannot disagree.
publish() {
  banner 'record'
  cat "${work}/record"
  mkdir -p "$(dirname "${record}")"
  cp "${work}/record" "${record}"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    printf '### Tailscale vendor-smoke record (tailscale %s)\n\n' "${tailscale_version}"
    printf 'Transcribe these lines into `fleet/vendor-smoke/tailscale-ssh.probe` to move\n'
    printf 'the design section 3.6 feature gate; `lib/auth.sh` reads `date`,\n'
    printf '`tailscale_version`, and `result` and ignores the rest.\n\n'
    printf '```\n'
    cat "${work}/record"
    printf '```\n'
  } >>"${GITHUB_STEP_SUMMARY}"
}

# abort REASON: a run that could not make the measurement records inconclusive and says
# why in this file's own words. A lane that guessed at a result it never observed would
# be worse than one that failed, because the gate it feeds would open on the guess.
abort() {
  emit result inconclusive
  emit ssh_probe_reason not-reached
  emit note "${1}"
  publish
  fail "${1}"
}

# The header of the record, written before anything can go wrong, so that even an aborted
# run produces a record a human can read and file.
emit date "$(date -u +%Y-%m-%d)"
emit tailscale_version "${tailscale_version}"
emit tailscale_apt_channel "${channel}"
emit ubuntu_release "${ubuntu_release}"
emit operator_user "${PROBE_OPERATOR}"
emit nonoperator_user "${PROBE_OTHER}"

banner "vendor-smoke: tailscale ${tailscale_version} from ${channel}, never logged in"

# ---------------------------------------------------------------------------
banner 'the pinned install'
# ---------------------------------------------------------------------------
# The vendor keyring and source, written the way the vendor's own instructions spell
# them and the way lib/tailscale.sh derives them from tailscale_apt_channel: the keyring
# at <track>/<codename>.noarmor.gpg, the packages under the apt suite <codename> of
# <track>. Nothing here is Harbor's install path; this lane measures the vendor package,
# it does not exercise the bootstrap.
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL --proto '=https' --tlsv1.2 \
  "https://pkgs.tailscale.com/${track}/${codename}.noarmor.gpg" \
  | sudo tee /etc/apt/keyrings/tailscale-archive-keyring.gpg >/dev/null
sudo chmod 0644 /etc/apt/keyrings/tailscale-archive-keyring.gpg
printf 'deb [signed-by=/etc/apt/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/%s %s main\n' \
  "${track}" "${codename}" | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
sudo env DEBIAN_FRONTEND=noninteractive apt-get update

# The simulation is the pin check, exactly as harbor_tailscale_install makes it: apt
# refuses a version its sources do not carry. A pin the channel no longer publishes is a
# real finding about versions.lock and not a fault of this lane, so it fails the job
# naming the pin and the lock file rather than falling back to whatever apt would prefer.
rc=0
sudo env DEBIAN_FRONTEND=noninteractive apt-get -s install "tailscale=${tailscale_version}" || rc="$?"
[ "${rc}" = 0 ] \
  || abort "tailscale_version ${tailscale_version} pinned by fleet/versions.lock is not installable from the ${channel} channel (apt-get -s install exited ${rc}), so no measurement was made; either the pin has to move or the channel has to be fixed"
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "tailscale=${tailscale_version}"
installed="$(dpkg-query -W -f='${Version}' tailscale 2>/dev/null || printf '')"
[ "${installed}" = "${tailscale_version}" ] \
  || abort "apt installed tailscale ${installed:-nothing}, not the ${tailscale_version} fleet/versions.lock pins, so nothing measured below would have been a measurement of the pinned version"

# ---------------------------------------------------------------------------
banner 'the daemon, from its packaged unit, never logged in'
# ---------------------------------------------------------------------------
sudo systemctl daemon-reload
rc=0
sudo systemctl start tailscaled || rc="$?"
printf 'systemctl start tailscaled exit: %s\n' "${rc}"
waited=0
while [ "${waited}" -lt 30 ] && [ ! -S /var/run/tailscale/tailscaled.sock ]; do
  sleep 1
  waited=$((waited + 1))
done
printf 'tailscaled.sock after %ss: %s\n' "${waited}" \
  "$([ -S /var/run/tailscale/tailscaled.sock ] && printf present || printf absent)"
# A daemon that never started measures nothing: every reading below would be the CLI
# failing to reach a socket, which has the same exit codes as a refusal and none of the
# meaning.
sudo systemctl is-active --quiet tailscaled \
  || abort "tailscaled did not become active after the pinned install, so every reading below would have measured a missing socket rather than a never-logged-in daemon"

# The record has to be able to say the daemon was logged out, because a logged-in daemon
# answers the operator question differently and this lane has no way to log one in. Root
# reads the state; only this file's yes or no is ever emitted from it.
root_state="$(sudo tailscale status --json 2>/dev/null \
  | sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n 1p)"
[ "${root_state}" != Running ] \
  || abort "the freshly installed tailscaled reports itself logged in, which this lane cannot have caused and cannot measure around; nothing was recorded"
emit daemon_logged_in no

# ---------------------------------------------------------------------------
banner 'the two unprivileged accounts'
# ---------------------------------------------------------------------------
# create_probe_user USER: an ordinary account with a home and no authority at all. Both
# the grant and the refusal this lane records are only worth recording about an account
# that could not have done the thing anyway by being root, so an account that can reach
# sudo aborts the run rather than quietly producing a flattering result.
create_probe_user() {
  local user="${1}" groups
  if id "${user}" >/dev/null 2>&1; then
    abort "the account ${user} already exists on this runner, and this lane will only measure accounts it created itself"
  fi
  sudo useradd --create-home --shell /bin/bash "${user}"
  groups="$(id -nG "${user}")"
  case " ${groups} " in
    *' sudo '* | *' admin '* | *' root '*)
      abort "the probe account ${user} landed in a privileged group (${groups}), so nothing it is answered would be an unprivileged answer"
      ;;
  esac
  # sudo's own answer, not a guess from group membership: a sudoers drop-in could grant
  # an account that is in no privileged group at all, and the runner image ships one.
  if sudo -n -l -U "${user}" >/dev/null 2>&1; then
    abort "sudo lists rules for the probe account ${user}, so it is not the powerless account this measurement needs"
  fi
  printf '%s: created, groups %s, no sudo\n' "${user}" "${groups}"
}
create_probe_user "${PROBE_OPERATOR}"
create_probe_user "${PROBE_OTHER}"

# ---------------------------------------------------------------------------
banner 'reading: tailscale get operator on the pinned version'
# ---------------------------------------------------------------------------
# read_get_operator LABEL: the operator preference as the pinned CLI's documented
# tailscale get operator prints it, classified the way harbor_tailscale_get_operator
# classifies it -- unavailable when the command fails or answers with anything Harbor
# could not write back exactly, absent when it exits 0 and prints nothing, exact when it
# prints one portable account name. GET_SUBCOMMAND says whether the subcommand exists on
# this version at all, which is the first half of the section 7 question. The readings
# are globals rather than stdout because a command substitution would lose every one of
# them to the subshell, the reason lib/tailscale.sh gives for the same shape.
read_get_operator() {
  local out="${work}/get-operator-${1}.out" rc=0 lines value
  GET_STATE=unavailable
  GET_VALUE=""
  GET_SUBCOMMAND=present
  # The redirect is this shell's, not sudo's, which is the point: every capture below
  # lands in the 0700 working directory this unprivileged user owns rather than anywhere
  # root could be tricked into writing. SC2024 warns about the general case.
  # shellcheck disable=SC2024
  sudo tailscale get operator >"${out}" 2>&1 || rc="$?"
  if [ "${rc}" != 0 ]; then
    # The capture is matched, never printed. A CLI that has no such subcommand says so in
    # its usage text; anything else that failed is a subcommand that exists and refused.
    if grep -qiE 'unknown subcommand|unknown command|flag provided but not defined|is not a tailscale command|^USAGE' "${out}"; then
      GET_SUBCOMMAND=absent
    fi
    return 0
  fi
  lines="$(awk 'END { print NR }' <"${out}")"
  if [ "${lines}" = 0 ]; then
    GET_STATE=absent
    return 0
  fi
  [ "${lines}" = 1 ] || return 0
  value="$(sed -n 1p "${out}")"
  case "${value}" in
    '')
      GET_STATE=absent
      return 0
      ;;
    # The same portable-name rule harbor_tailscale_check_operator_name applies. It is
    # also what makes this the one vendor-derived string the record may carry: a value
    # that survives it holds only letters, digits, dot, underscore and hyphen, so it can
    # be no URL and no credential.
    -* | *[!A-Za-z0-9._-]*) return 0 ;;
  esac
  GET_STATE=exact
  GET_VALUE="${value}"
}

read_get_operator before
emit get_operator_subcommand "${GET_SUBCOMMAND}"
emit get_operator_before "${GET_STATE}"
printf 'before the grant: subcommand %s, value %s\n' "${GET_SUBCOMMAND}" "${GET_STATE}"

# ---------------------------------------------------------------------------
banner 'mutation: sudo tailscale set --operator'
# ---------------------------------------------------------------------------
# The one write this lane makes, and it is the write design section 5.2 names rather than
# a no-op sent to discover whether writing is allowed: section 7 forbids probing write
# authority with a no-op mutation, so nothing else here writes a preference.
set_exit=0
# shellcheck disable=SC2024 # the redirect is this user's own, into their 0700 work dir
sudo tailscale set "--operator=${PROBE_OPERATOR}" >"${work}/set-operator.out" 2>&1 || set_exit="$?"
emit set_operator_exit "${set_exit}"
printf 'sudo tailscale set --operator=%s exit: %s\n' "${PROBE_OPERATOR}" "${set_exit}"

read_get_operator after
emit get_operator_after "${GET_STATE}"
if [ "${GET_STATE}" = exact ]; then
  emit get_operator_value "${GET_VALUE}"
  # The pinned CLI reads its own preference back exactly, so the section 5.2 adoption
  # path can record a prior operator and the reverse walk can restore it.
  emit adoption_path tailscale-get-operator-exact
else
  # It cannot, so section 5.2 has no prior value to record, and the adoption of a
  # pre-existing Tailscale falls back to the owner running the grant outside Harbor.
  emit adoption_path owner-run-sudo-tailscale-set-operator
fi
printf 'after the grant: value %s\n' "${GET_STATE}"

# ---------------------------------------------------------------------------
banner 'reading: tailscale status --json as the operator and as an ordinary user'
# ---------------------------------------------------------------------------
# status_probe USER LABEL: tailscale status --json as USER, with the CLI running under
# that account's own uid and no privilege of any kind -- sudo appears only to drop from
# the workflow user into the account, the way lib/tailscale.sh drops through runuser from
# root, and the daemon is answering an unprivileged peer either way. Two facts leave this
# function, the exit status and whether BackendState could be read; the JSON itself stays
# in the capture file and is removed with it.
status_probe() {
  local user="${1}" out="${work}/status-${2}.out" rc=0 state
  STATUS_EXIT=0
  STATUS_BACKEND_READABLE=no
  # shellcheck disable=SC2024 # the redirect is this user's own, into their 0700 work dir
  sudo runuser -u "${user}" -- tailscale status --json >"${out}" 2>&1 || rc="$?"
  STATUS_EXIT="${rc}"
  state="$(sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${out}" | sed -n 1p)"
  [ -z "${state}" ] || STATUS_BACKEND_READABLE=yes
}

status_probe "${PROBE_OPERATOR}" operator
emit operator_status_exit "${STATUS_EXIT}"
emit operator_backend_state_readable "${STATUS_BACKEND_READABLE}"
printf '%s (the operator): exit %s, BackendState readable %s\n' \
  "${PROBE_OPERATOR}" "${STATUS_EXIT}" "${STATUS_BACKEND_READABLE}"

status_probe "${PROBE_OTHER}" nonoperator
emit nonoperator_status_exit "${STATUS_EXIT}"
emit nonoperator_backend_state_readable "${STATUS_BACKEND_READABLE}"
printf '%s (not the operator): exit %s, BackendState readable %s\n' \
  "${PROBE_OTHER}" "${STATUS_EXIT}" "${STATUS_BACKEND_READABLE}"

# ---------------------------------------------------------------------------
banner 'the design section 3.6 probe'
# ---------------------------------------------------------------------------
# The question, in the exact form harbor auth tailscale would run: the operator user,
# without sudo, against a daemon that has never been logged in. It is bounded by a
# timeout because a daemon that accepts the flag proceeds to a login step and then waits
# for a human, and waiting is itself the answer this lane is looking for.
ssh_exit=0
ssh_out="${work}/ssh-up.out"
: >"${ssh_out}"
printf 'running: tailscale up --hostname=%s --ssh as %s, without sudo, %ss bound\n' \
  "${SSH_PROBE_HOSTNAME}" "${PROBE_OPERATOR}" "${SSH_PROBE_TIMEOUT_SECONDS}"
printf 'its output goes to a private file and is classified there; none of it is printed\n'
# shellcheck disable=SC2024 # the redirect is this user's own, into their 0700 work dir
sudo runuser -u "${PROBE_OPERATOR}" -- \
  timeout -k 10 -s TERM "${SSH_PROBE_TIMEOUT_SECONDS}" \
  tailscale up "--hostname=${SSH_PROBE_HOSTNAME}" --ssh \
  >"${ssh_out}" 2>&1 || ssh_exit="$?"

# The classification, and the only place a verdict is decided. Every test is grep -q
# against a marker this file chose, so the match prints nothing, and each branch sets a
# word this file chose, so nothing the vendor wrote can reach the record even by being
# quoted as a reason. The order is the order of certainty: a flag the CLI does not have
# fails before the daemon is ever asked; a refusal by the daemon is a refusal whatever
# else it printed; only then is a login step evidence that the flag was accepted; and an
# answer matching none of them is inconclusive, which is the safe verdict because the
# gate stays closed on it.
ssh_result=inconclusive
ssh_reason=unclassified-answer
if grep -qiE 'flag provided but not defined|unknown flag|unknown shorthand flag|unknown subcommand|is not a tailscale command' "${ssh_out}"; then
  ssh_result=refused
  ssh_reason=unsupported-flag
elif grep -qiE 'access denied|permission denied|operation not permitted|must be root|use sudo|not the operator' "${ssh_out}"; then
  ssh_result=refused
  ssh_reason=permission-denied
elif grep -qiE 'to authenticate|to approve|login\.tailscale\.com' "${ssh_out}"; then
  # The daemon accepted --ssh and went on to ask for a login. What it printed to ask with
  # is the login URL, and that is precisely why this branch emits one word and no reason
  # drawn from the text it just matched.
  ssh_result=accepted
  ssh_reason=login-step-reached
elif [ "${ssh_exit}" = 124 ] || [ "${ssh_exit}" = 137 ]; then
  # It neither refused nor reached a login step before the bound ran out. Something held
  # it, and a lane that called that acceptance would open the gate on a hang.
  ssh_reason=timed-out-without-marker
fi
# A grant that did not happen makes the reading above a reading of an ungranted account,
# which is a different question with the same shape. Nothing is asserted from it.
if [ "${set_exit}" != 0 ]; then
  ssh_result=inconclusive
  ssh_reason=operator-grant-not-made
fi

emit ssh_probe_form "tailscale up --hostname=${SSH_PROBE_HOSTNAME} --ssh"
emit ssh_probe_sudo no
emit ssh_probe_timeout_seconds "${SSH_PROBE_TIMEOUT_SECONDS}"
emit ssh_probe_exit "${ssh_exit}"
emit ssh_probe_reason "${ssh_reason}"
emit result "${ssh_result}"

case "${ssh_result}" in
  accepted)
    emit note "The vendor-smoke lane ran tailscale up --hostname=${SSH_PROBE_HOSTNAME} --ssh as the operator ${PROBE_OPERATOR}, without sudo, against a never-logged-in tailscale ${tailscale_version} installed from the ${channel} channel, and the daemon accepted the flag and proceeded to its login step (${ssh_reason}, exit ${ssh_exit}). No login was completed, no auth key exists in this lane, and no vendor output left the runner."
    ;;
  refused)
    emit note "The vendor-smoke lane ran tailscale up --hostname=${SSH_PROBE_HOSTNAME} --ssh as the operator ${PROBE_OPERATOR}, without sudo, against a never-logged-in tailscale ${tailscale_version} installed from the ${channel} channel, and the daemon refused it (${ssh_reason}, exit ${ssh_exit}), so the section 3.6 feature gate stays closed on this version and harbor auth tailscale keeps printing the root-owned alternative, sudo tailscale set --ssh."
    ;;
  *)
    emit note "The vendor-smoke lane ran tailscale up --hostname=${SSH_PROBE_HOSTNAME} --ssh as the operator ${PROBE_OPERATOR}, without sudo, against a never-logged-in tailscale ${tailscale_version} installed from the ${channel} channel, and could not classify what the daemon answered (${ssh_reason}, exit ${ssh_exit}). Nothing is asserted by this run and the section 3.6 feature gate stays closed."
    ;;
esac

publish

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '\n'
    case "${ssh_result}" in
      accepted)
        printf 'The pinned Tailscale **accepted** `--ssh` from the operator without sudo.\n'
        printf 'Transcribing `result=accepted` with this `tailscale_version` opens the design\n'
        printf 'section 3.6 gate in `lib/auth.sh`.\n'
        ;;
      refused)
        printf 'The pinned Tailscale **refused** `--ssh` from the operator without sudo\n'
        printf '(`%s`). The section 3.6 gate stays closed, which is what this release ships.\n' "${ssh_reason}"
        ;;
      *)
        printf 'The probe was **inconclusive** (`%s`), so nothing is asserted and the\n' "${ssh_reason}"
        printf 'section 3.6 gate stays closed.\n'
        ;;
    esac
    printf '\nNo Tailscale account, auth key, or tailnet exists in this lane, and no vendor\n'
    printf 'output was written to this summary, the artifact, or the job log.\n'
  } >>"${GITHUB_STEP_SUMMARY}"
fi

banner "result: ${ssh_result} (${ssh_reason})"
