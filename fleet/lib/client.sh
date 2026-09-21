#!/bin/bash
# fleet/lib/client.sh
# The Mac half of Harbor (design section 5.5). Everything here runs on stock
# macOS, so it is bash 3.2 and it uses only what a Mac ships with: no jq, no
# GNU coreutils, no Homebrew.

# harbor_client_json_flatten: JSON on stdin, one "path<TAB>json-value" line per
# scalar on stdout. Nonzero, and nothing on stdout, for a body that is not JSON.
#
# macOS's built-in JavaScript host is the whole JSON dependency (design section
# 5.5: "client/ and PR 6 need no jq on the Mac"). The document arrives on stdin
# rather than as an argument because it is remote input and an argument is
# visible in the process table to every user on this Mac.
#
# Flattened once rather than queried per field: each osascript spawn costs about
# a tenth of a second, and a flattened document is a plain file a test can assert
# against, which a chain of live queries is not.
#
# Values stay JSON-encoded so a value carrying a newline or a tab still occupies
# exactly one line. harbor_client_json_field decodes them on the way out.
harbor_client_json_flatten() {
  /usr/bin/osascript -l JavaScript -e '
    ObjC.import("Foundation");
    var input = $.NSString.alloc.initWithDataEncoding(
      $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile,
      $.NSUTF8StringEncoding);
    if (input.js === undefined) { throw new Error("input is not UTF-8"); }
    var doc = JSON.parse(input.js);
    var out = [];
    function walk(path, value) {
      // A key carrying a newline or a tab would split one entry into two lines,
      // or two fields into one, and the readers below work on lines and tabs.
      // {"x\nBackendState":"Running"} flattens to a line that reads exactly
      // like a real top-level BackendState, so a document with no such key
      // answers Running to a caller that asks for it. The whole document is
      // refused rather than the key sanitized: this parses remote input, and a
      // status document with a control character in a key is not a document
      // Harbor has any business interpreting the rest of.
      if (/[\n\r\t]/.test(path)) {
        throw new Error("key contains a control character");
      }
      if (value !== null && typeof value === "object") {
        var keys = Array.isArray(value)
          ? value.map(function (_, i) { return String(i); })
          : Object.keys(value);
        if (keys.length === 0) { return; }
        keys.forEach(function (k) {
          walk(path === "" ? k : path + "." + k, value[k]);
        });
        return;
      }
      out.push(path + "\t" + JSON.stringify(value));
    }
    walk("", doc);
    out.join("\n");
  '
}

# harbor_client_json_pattern PATH: PATH as a basic regular expression matching
# itself. Every flattened path is dotted by construction, and an unescaped dot
# matches any character -- so a reader asked for "access.mode" would answer just
# as happily for a field spelled "accessXmode". No node emits such a key today,
# and a reader that cannot tell the two apart is still the wrong reader. The
# slash is escaped too, because it is the delimiter the two readers below use.
#
# One expression per character rather than one bracket expression: BSD sed reads
# a class that opens with "][" as unbalanced -- measured, not guessed -- and the
# portable spelling of that class is unreadable enough that nobody would notice
# it going wrong. Backslash is escaped first, so the backslashes the later
# expressions add are not escaped again by it.
harbor_client_json_pattern() {
  printf '%s' "${1}" | sed \
    -e 's/\\/\\\\/g' \
    -e 's/\./\\./g' \
    -e 's/\*/\\*/g' \
    -e 's/\[/\\[/g' \
    -e 's/\]/\\]/g' \
    -e 's/\^/\\^/g' \
    -e 's/\$/\\$/g' \
    -e 's|/|\\/|g'
}

# harbor_client_json_field FLATFILE PATH: the value at PATH, decoded. A string
# loses its quotes and its escapes; a number, boolean or null is printed as it
# stands. An absent path prints nothing and still succeeds, which is why callers
# that care about the difference ask harbor_client_json_has first.
harbor_client_json_field() {
  local raw
  raw="$(sed -n "s/^$(harbor_client_json_pattern "${2}")$(printf '\t')//p" "${1}" | sed -n 1p)"
  case "${raw}" in
    '"'*'"')
      raw="${raw#\"}"
      raw="${raw%\"}"
      # One left-to-right pass, not a chain of substitutions. A chain decodes the
      # escapes in whatever order it is written in, so the literal two characters
      # \n -- which arrive encoded as \\n -- get their second backslash eaten by
      # the \n rule and come out as a real newline. Measured: the sed chain gets
      # "lit \\n not newline" wrong and this gets it right.
      #
      # Every single-character escape JSON defines except \u, which needs a
      # UTF-8 encoder and a surrogate pairing rule and is not something to write
      # in awk. A \u sequence stays as written rather than being guessed at: a
      # wrong decoding of a remote detail line is worse than a literal one.
      printf '%s' "${raw}" | awk '{
        s = $0; out = ""; i = 1
        while (i <= length(s)) {
          c = substr(s, i, 1)
          if (c == "\\" && i < length(s)) {
            n = substr(s, i + 1, 1)
            if (n == "n") { out = out "\n"; i += 2; continue }
            if (n == "t") { out = out "\t"; i += 2; continue }
            if (n == "r") { out = out "\r"; i += 2; continue }
            if (n == "b") { out = out "\b"; i += 2; continue }
            if (n == "f") { out = out "\f"; i += 2; continue }
            if (n == "/") { out = out "/"; i += 2; continue }
            if (n == "\"") { out = out "\""; i += 2; continue }
            if (n == "\\") { out = out "\\"; i += 2; continue }
          }
          out = out c; i++
        }
        printf "%s", out
      }'
      ;;
    *) printf '%s' "${raw}" ;;
  esac
}

# harbor_client_json_has FLATFILE PATH: exit 0 when PATH is present, whatever its
# value. "Absent" and "present and empty" are different answers about a node, and
# a verifier that cannot tell them apart will call a missing check a passing one.
harbor_client_json_has() {
  grep -q "^$(harbor_client_json_pattern "${2}")$(printf '\t')" "${1}"
}

# The app-bundled CLI, which is where both the App Store build and the standalone
# build put it. HARBOR_CLIENT_TAILSCALE overrides it; that is a test seam and
# nothing else reads it.
harbor_client_tailscale_cli() {
  local cli="${HARBOR_CLIENT_TAILSCALE:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
  [ -x "${cli}" ] || return 1
  printf '%s' "${cli}"
}

# harbor_client_tailscale_status FLATFILE: the Mac's own tailscale status,
# flattened into FLATFILE. Nonzero when the CLI could not answer or did not
# answer JSON -- both of which are preconditions to the caller, never findings.
harbor_client_tailscale_status() {
  local cli
  cli="$(harbor_client_tailscale_cli)" || return 1
  "${cli}" status --json 2>/dev/null | harbor_client_json_flatten >"${1}" || return 1
  [ -s "${1}" ] || return 1
}

# harbor_client_preflight FLATFILE: the three things that must be true of this
# Mac before anything is written or reached (design section 5.5).
harbor_client_preflight() {
  local flat="${1}" backend suffix
  harbor_client_tailscale_cli >/dev/null \
    || harbor_die 3 client.tailscale_absent "the Tailscale client is not installed on this Mac, or its CLI is not where the app puts it (/Applications/Tailscale.app/Contents/MacOS/Tailscale); install Tailscale and log in, then rerun"
  harbor_client_tailscale_status "${flat}" \
    || harbor_die 3 client.tailscale_unreadable "the Tailscale client is installed but did not answer 'status --json' on this Mac; open the app and make sure it is running, then rerun"
  backend="$(harbor_client_json_field "${flat}" BackendState)"
  [ "${backend}" = Running ] \
    || harbor_die 3 client.tailscale_not_running "the Tailscale client on this Mac reports BackendState ${backend}, not Running; log in through the app, then rerun"
  suffix="$(harbor_client_json_field "${flat}" MagicDNSSuffix)"
  # Section 5.5 names this one: without MagicDNS there is no harbor-node name to
  # put in an ssh block and no HTTPS MagicDNS URL to reach, so
  # this is a precondition for both halves rather than a warning for one.
  [ -n "${suffix}" ] \
    || harbor_die 3 client.magicdns_off "this tailnet has MagicDNS turned off, so the node has no name this Mac can use; turn MagicDNS on in the Tailscale admin console, then rerun"
}

# harbor_client_magicdns FLATFILE HOSTNAME: the peer's MagicDNS name, without the
# trailing dot the status document carries. Refusing here rather than returning
# an empty string is the point: an empty HostName in an ssh block is a block that
# silently connects somewhere else.
harbor_client_magicdns() {
  local flat="${1}" want="${2}" key name
  # The tab in the sed pattern is written with printf rather than typed: a literal
  # tab in a source file is invisible and the next editor to touch this line will
  # turn it into spaces.
  for key in $(sed -n "s/^Peer\.\([^.]*\)\.HostName$(printf '\t').*\$/\1/p" "${flat}"); do
    if [ "$(harbor_client_json_field "${flat}" "Peer.${key}.HostName")" = "${want}" ]; then
      name="$(harbor_client_json_field "${flat}" "Peer.${key}.DNSName")"
      # The peer is there and still has no name. Returning the empty string here
      # would be this function doing the exact thing its comment says it exists to
      # prevent, one step further in: an empty HostName in an ssh block, reached
      # through a peer that matched rather than through a peer that was missing.
      [ -n "${name%.}" ] \
        || harbor_die 3 client.node_unnamed "this Mac's tailnet has a node named ${want} but reports no MagicDNS name for it; check that MagicDNS is on and that the node has finished registering, then rerun"
      printf '%s' "${name%.}"
      return 0
    fi
  done
  harbor_die 3 client.node_absent "this Mac's tailnet has no node named ${want}; run 'harbor auth tailscale' on the node first, and check it appears in the Tailscale admin console"
}

# The block design section 5.5 specifies, and nothing else. The alias is exactly
# "harbor-node" because T3's desktop-managed SSH launch uses this same block, so
# the name is part of the contract rather than a label Harbor is free to choose.
harbor_client_conf_body() {
  printf 'Host harbor-node\n'
  printf '  HostName %s\n' "${1}"
  printf '  User %s\n' "${2}"
  printf '  IdentitiesOnly yes\n'
}

# Written at 0600 before it moves into place. An ssh configuration that is
# world-readable for an instant was world-readable -- and a chmod after the
# redirection is exactly that instant, because the shell creates the file with
# whatever umask the operator's shell happens to carry. The umask is set in a
# subshell so it applies to the creation itself and does not outlive this write.
#
# mktemp rather than "${path}.tmp.$$", which was a name anyone could work out in
# advance. A redirection follows a symlink, so a symlink planted at that path
# sent the write straight through it: measured, the target file was truncated,
# filled with the generated block, chmodded 0600, and harbor.conf was left as a
# symlink pointing at it -- with Harbor exiting 0. mktemp creates with O_EXCL and
# refuses an existing path, which is the property that matters here; the
# unguessable name is a bonus. The temp lands in the target's own directory
# because the last step has to be a rename, and a rename across filesystems is
# not one.
#
# The temp file is named for the exit trap as soon as it exists, for the same
# reason the include writer's is: a failure between the write and the rename
# leaves a copy of the generated configuration beside the target, unjournaled,
# and recovery only ever looks at entries. The two writers share the one
# variable because setup runs them in sequence, never at once, and a second name
# would only be a second thing to forget.
harbor_client_conf_write() {
  local path="${1}" tmp
  tmp="$(
    umask 077
    mktemp "$(dirname "${path}")/.harbor.XXXXXX"
  )"
  HARBOR_CLIENT_STAGE_TMP="${tmp}"
  harbor_client_conf_body "${2}" "${3}" >"${tmp}"
  chmod 0600 "${tmp}"
  mv -f "${tmp}" "${path}"
  # shellcheck disable=SC2034 # read by harbor_on_exit in lib/log.sh
  HARBOR_CLIENT_STAGE_TMP=
}

# The literal design section 5.5 names. Spelled with ~ rather than an expanded
# path because that is what the operator would have written and what ssh itself
# expands; an absolute path here would differ from the documented line and make
# the "already present" check miss a hand-written one.
harbor_client_include_line() {
  printf 'Include ~/.ssh/harbor.conf'
}

# -F and -x, not an anchored pattern: the line carries a dot, and as a regular
# expression that dot matches any character -- so a config holding
# "Include ~/.ssh/harborAconf" would answer yes here. That answer is the
# expensive one. harbor_client_include_add would return success having written
# nothing and journaled nothing, and ssh would go on never loading harbor.conf,
# with every visible sign saying setup had succeeded.
harbor_client_include_present() {
  [ -f "${1}" ] || return 1
  grep -Fqx "$(harbor_client_include_line)" "${1}"
}

# harbor_client_include_add STATE_ROOT CONFIG: the include, once, prepended.
#
# Prepended rather than appended because ssh applies an Include where it stands,
# so one added after an existing "Host *" block would be read too late to affect
# anything above it -- a configuration that looks right in the file and does
# nothing in practice.
#
# Ownership is the honest word, and the whole of --remove turns on it: modified
# when the operator already had a config, created when Harbor made the file.
harbor_client_include_add() {
  local root="${1}" config="${2}" ownership pre post tmp entry work staged tmpdir
  if harbor_client_include_present "${config}"; then
    # Already there, by Harbor's hand on an earlier run or by the operator's.
    # Either way there is nothing to do and nothing to own, and a journal entry
    # for a mutation that did not happen is a claim recovery would act on.
    return 0
  fi
  # A symlinked config is refused rather than followed. The rename at the end of
  # this function replaces whatever is at that path with a regular file, so a
  # config symlinked into a dotfiles checkout is silently converted into an
  # unmanaged copy: measured, the link was gone, the file it had pointed at was
  # left untouched and orphaned, and the entry recorded ownership "modified",
  # phase "applied", a symlink pre_state and a regular-file post_state -- Harbor
  # calling a destroyed setup a success. Every edit the operator makes in their
  # checkout from then on reaches nothing.
  #
  # Writing through the link instead was the other option and it is worse: it
  # puts Harbor's include in a file Harbor was never pointed at, inside a
  # repository it would then be committed to.
  if [ -L "${config}" ]; then
    harbor_die 3 client.config_symlink "${config} is a symlink to $(readlink "${config}"), and adding the include would replace the link with a regular file and orphan what it points at; add this line to the file the link points at yourself, then rerun: $(harbor_client_include_line)"
  fi
  if [ -f "${config}" ]; then ownership=modified; else ownership=created; fi
  pre="$(harbor_journal_observe file "${config}")"
  # The new contents are built somewhere that is not the operator's ~/.ssh, and
  # only move next to the target once the entry exists. Building them in place
  # was the obvious spelling and it leaks: harbor_journal_create does not return
  # a status when it refuses, it exits, so no cleanup written after the call ever
  # runs and a config.tmp.NNNN is left behind -- an unjournaled file in ~/.ssh,
  # which is the one class of artifact nothing in Harbor ever collects, because
  # recovery only ever looks at entries. Measured, not reasoned about: a test
  # seeds an unwritable journal and asserts nothing is left beside the config.
  #
  # An explicit template rather than "mktemp -d -t harbor-client": measured, BSD
  # mktemp's -t form ignores TMPDIR entirely and always answers with the per-user
  # /var/folders directory, which is both a surprise and untestable. Interpolating
  # the directory keeps this consistent with harbor_test_pause_sentinel, which
  # already reads TMPDIR, and lets a test say where the staging goes. mktemp
  # creates the directory itself, atomically, at 0700 and owned by this user, so
  # the fallback to a shared /tmp is still not somewhere another user can read.
  tmpdir="${TMPDIR:-/tmp}"
  work="$(mktemp -d "${tmpdir%/}/harbor-client.XXXXXX")"
  # Named for the exit trap before anything is written into it. Both of these
  # hold a copy of the operator's ssh config, and every path out of the rest of
  # this function that is not the last line is an exit rather than a return:
  # harbor_journal_create exits, harbor_die exits, set -e exits, and an operator
  # pressing ^C between the install and the rename exits through
  # harbor_on_interrupt. A cleanup written inline runs on none of them, which is
  # how the staging directory and a config.tmp.NNNN beside the target survive a
  # failure. harbor_on_exit is the one place all of those meet, and it is
  # already where HARBOR_LOCK_ROOT is released for the same reason.
  #
  # It does not cover SIGKILL, and nothing can: the test hook's fail-after kills
  # this process outright, exactly as a power cut would, and leaves the staging
  # directory behind in TMPDIR. That is the one leak Harbor accepts, because the
  # alternative is a sweep of paths Harbor cannot prove it created.
  HARBOR_CLIENT_STAGE="${work}"
  staged="${work}/config"
  (
    umask 077
    harbor_client_include_line >"${staged}"
  )
  printf '\n' >>"${staged}"
  # Spelled as an if rather than "[ -f x ] && cat x", which is a landmine: that
  # form survives set -e only because another command follows it, so the next
  # person to move this line to the end of the block gets an exit nobody asked for.
  if [ -f "${config}" ]; then
    cat "${config}" >>"${staged}"
  fi
  chmod 0600 "${staged}"
  # The post-state is measured on the finished file rather than predicted, and it
  # holds across the move because harbor_observe_file reads sha256, mode and
  # owner and none of the three depends on which directory the file is in. An
  # entry prepared with no post-state is an entry harbor_journal_recover could
  # never decide after a crash.
  post="$(harbor_observe_file "${staged}")"
  harbor_journal_create "${root}" ssh-include "${config}" "${ownership}" prepared "${pre}" "${post}" \
    || exit "$?"
  entry="${HARBOR_JOURNAL_ENTRY:-}"
  harbor_step "client-include-prepared"
  # The config is read once to build the staged copy and replaced wholesale at
  # the end, so anything written to it in between would be overwritten without a
  # word. The window is short and it is not empty -- the test hook can hold this
  # function open across it, and so can a slow journal write -- and the thing
  # lost is the operator's own edit to their own ssh config. Harbor refuses
  # instead: the entry stays prepared, recovery will find the file at its
  # pre_state and record it reverted, and nothing has been mutated yet.
  if [ "$(harbor_journal_observe file "${config}")" != "${pre}" ]; then
    harbor_die 1 client.config_moved "${config} changed while Harbor was preparing to add the include, so the copy it staged no longer contains what the file now holds and writing it would discard that change; nothing was written, and its journal entry is still prepared -- rerun once nothing else is editing the file"
  fi
  # Copied beside the target and then renamed, rather than renamed straight out
  # of the staging directory: a rename across filesystems is not a rename, and
  # the whole reason for the two steps is that the last one is atomic.
  #
  # mktemp rather than "${config}.tmp.$$". Unlike harbor_client_conf_write, this
  # one was not exploitable: measured, BSD install replaces a symlink at its
  # destination rather than writing through it, so a planted link here was
  # overwritten, not followed. The name is unguessable anyway, because the
  # difference between the two writers is one character of shell and not a thing
  # to rely on. install copies onto the file mktemp made, setting the mode as it
  # goes, so the file the post-state describes is the file that lands.
  tmp="$(
    umask 077
    mktemp "$(dirname "${config}")/.harbor.XXXXXX"
  )"
  HARBOR_CLIENT_STAGE_TMP="${tmp}"
  install -m 0600 "${staged}" "${tmp}"
  mv -f "${tmp}" "${config}"
  # Read by harbor_on_exit in lib/log.sh, which shellcheck cannot see from here
  # because this file does not source that one -- the dispatcher sources both.
  # Not exported, deliberately: an exported value would be inherited by every
  # child this run spawns, and a child's own exit trap would then remove the
  # parent's staging out from under it.
  #
  # Cleared after the removal rather than before. Clearing first leaves a window
  # in which the directory still exists and nothing names it, so an interrupt
  # during the rm -rf leaks exactly what the trap is there to collect. The other
  # order has no such window: rm -rf on a path already gone is a no-op, and the
  # trap's own [ -d ] guard makes a second attempt free.
  # shellcheck disable=SC2034
  HARBOR_CLIENT_STAGE_TMP=
  rm -rf "${work}"
  # shellcheck disable=SC2034
  HARBOR_CLIENT_STAGE=
  harbor_journal_set_phase "${entry}" applied \
    || harbor_die 2 client.include_record "the include was added to ${config} but its journal entry could not be marked applied; inspect the journal before rerunning"
}

# The ssh-include op uses the same file state for crash recovery.
harbor_observe_op_ssh_include() {
  harbor_observe_file "${1}"
}
