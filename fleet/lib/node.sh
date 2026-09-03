#!/bin/bash
# Node.js runtime (design sections 2 and 5.2): version inspection at the root-owned
# prefix, the checksum-verified download and install journaled as runtime-install,
# the four journaled bin symlinks, and the report-only operator probe. The prefix
# and the bin directory are parameters; production passes /opt/harbor/node and
# /usr/local/bin, unit tests pass fixture paths.
HARBOR_NODE_LINKS="node npm npx corepack"
# harbor_node_installed_version PREFIX: "absent" when PREFIX/bin/node is not an
# executable file, else the bare version PREFIX/bin/node --version reports. Reads
# nothing from operator state. A runtime that is present but cannot answer is exit 2.
harbor_node_installed_version() {
  local node="${1}/bin/node" out
  if [ ! -f "${node}" ] || [ ! -x "${node}" ]; then
    printf 'absent'
    return 0
  fi
  out="$("${node}" --version 2>/dev/null)" || harbor_die 2 node.unreadable "${node} --version failed; remove ${1} by hand and rerun so it is reinstalled"
  case "${out}" in
    v[0-9]*.[0-9]*.[0-9]*) printf '%s' "${out#v}" ;;
    *) harbor_die 2 node.unreadable "${node} --version printed '${out}', not a version; remove ${1} by hand and rerun so it is reinstalled" ;;
  esac
}
# harbor_node_tar_flag URL: the tar decompression flag for the tarball URL names
harbor_node_tar_flag() {
  case "${1}" in
    *.tar.gz | *.tgz) printf 'z' ;;
    *.tar.xz) printf 'J' ;;
    *) harbor_die 3 node.install_format "nodejs_install ${1} is not a .tar.gz or .tar.xz tarball" ;;
  esac
}
# harbor_node_download URL FILE: fetch URL into FILE through curl, https only, with
# stdout redirected so the shim's fixture body lands in FILE just as a real body does
harbor_node_download() {
  harbor_log_vendor curl -fsSL --proto =https --tlsv1.2 "${1}"
  curl -fsSL --proto =https --tlsv1.2 "${1}" >"${2}"
}
# harbor_node_install STATE_ROOT PREFIX: install the locked nodejs_version at PREFIX
# from the tarball nodejs_install names, verified against nodejs_sha256 before
# anything is unpacked. A matching installed version is a no-op with no entry.
# Otherwise one runtime-install entry, target PREFIX, pre_state the previous version
# or "absent", post_state the locked version, prepared before the download and
# applied after PREFIX/bin/node reports the locked version. The download and the
# staging tree live in a temporary directory beside PREFIX, created by the caller's
# identity (root in production), so the swap into place is a rename.
harbor_node_install() {
  local root="${1}" prefix="${2}" locked url sha flag pre pre_json ownership entry
  local parent tmp tarball actual post
  locked="$(harbor_version_require nodejs_version)" || exit "$?"
  url="$(harbor_version_require nodejs_install)" || exit "$?"
  sha="$(harbor_version_require nodejs_sha256)" || exit "$?"
  flag="$(harbor_node_tar_flag "${url}")" || exit "$?"
  case "${url}" in
    https://*) ;;
    *) harbor_die 3 node.install_scheme "nodejs_install must be an https:// URL, got ${url} in ${HARBOR_VERSIONS_FILE}" ;;
  esac
  pre="$(harbor_node_installed_version "${prefix}")" || exit "$?"
  if [ "${pre}" = "${locked}" ]; then
    harbor_log node "Node.js ${locked} at ${prefix} equals the lock; nothing to do"
    return 0
  fi
  if [ "${pre}" = absent ]; then
    ownership=created
    pre_json='"absent"'
  else
    ownership=modified
    pre_json="\"${pre}\""
  fi
  harbor_journal_create "${root}" runtime-install "${prefix}" "${ownership}" prepared "${pre_json}" "\"${locked}\""
  entry="${HARBOR_JOURNAL_ENTRY}"
  harbor_step node-prepared
  parent="$(dirname "${prefix}")"
  mkdir -p "${parent}"
  tmp="$(mktemp -d "${parent}/.node-install.XXXXXX")" || harbor_die 2 node.tmpdir "cannot create a temporary directory under ${parent}"
  tarball="${tmp}/${url##*/}"
  if ! harbor_node_download "${url}" "${tarball}"; then
    rm -rf "${tmp}"
    harbor_die 2 node.download "download of ${url} failed; $(basename "${entry}") stays prepared, rerun after fixing the cause"
  fi
  harbor_step node-downloaded
  actual="$(harbor_sha256 "${tarball}")"
  if [ "${actual}" != "${sha}" ]; then
    rm -rf "${tmp}"
    harbor_die 2 node.checksum "${url}: sha256 ${actual} does not match nodejs_sha256 ${sha} in ${HARBOR_VERSIONS_FILE}; the download was discarded and nothing was unpacked"
  fi
  harbor_step node-verified
  mkdir "${tmp}/node"
  chmod 0755 "${tmp}/node"
  if ! tar "-x${flag}f" "${tarball}" -C "${tmp}/node" --strip-components=1 --no-same-owner; then
    rm -rf "${tmp}"
    harbor_die 2 node.extract "extraction of ${tarball##*/} failed; ${prefix} is unchanged and $(basename "${entry}") stays prepared"
  fi
  harbor_step node-extracted
  if [ -e "${prefix}" ] || [ -L "${prefix}" ]; then
    mv "${prefix}" "${tmp}/previous"
  fi
  mv "${tmp}/node" "${prefix}"
  rm -rf "${tmp}"
  post="$(harbor_node_installed_version "${prefix}")" || exit "$?"
  [ "${post}" = "${locked}" ] || harbor_die 2 node.verify "${prefix}/bin/node --version reports ${post} after installing ${locked}; $(basename "${entry}") stays prepared"
  harbor_journal_set_phase "${entry}" applied
  harbor_step node-applied
  harbor_msg "installed Node.js ${locked} at ${prefix}"
}
# harbor_node_link_state LINK: "absent", {"symlink":"<target>"} for a symlink, or an
# unobservable marker for anything else
harbor_node_link_state() {
  if [ -L "${1}" ]; then
    printf '{"symlink":"%s"}' "$(harbor_json_escape "$(readlink "${1}")")"
  elif [ ! -e "${1}" ]; then
    printf '"absent"'
  else
    printf '"unobservable:not-a-symlink"'
  fi
}
# harbor_node_link STATE_ROOT PREFIX BINDIR: one symlink BINDIR/<name> to
# PREFIX/bin/<name> for node, npm, npx, and corepack, each one file entry: created
# when absent, observed (directly applied, nothing touched) when already correct,
# modified with the prior target as pre_state when it points elsewhere. Every link
# is inspected before any is written: a non-symlink at a link path exits 3 and a
# missing target exits 2, both with nothing journaled.
harbor_node_link() {
  local root="${1}" prefix="${2}" bindir="${3}" name link target pre post ownership tmp entry
  [ -d "${bindir}" ] || harbor_die 3 node.bindir "${bindir} is not a directory"
  for name in ${HARBOR_NODE_LINKS}; do
    link="${bindir}/${name}"
    target="${prefix}/bin/${name}"
    [ -e "${target}" ] || harbor_die 2 node.link_target "${target} does not exist; the Node.js runtime at ${prefix} is incomplete, remove it by hand and rerun"
    if [ -e "${link}" ] && [ ! -L "${link}" ]; then
      harbor_die 3 node.link_foreign "${link} exists and is not a symlink; inspect it, remove it by hand if it is not needed, and rerun"
    fi
    if [ -L "${link}" ] && [ -d "${link}" ]; then
      harbor_die 3 node.link_foreign "${link} is a symlink to a directory; inspect it, remove it by hand if it is not needed, and rerun"
    fi
  done
  for name in ${HARBOR_NODE_LINKS}; do
    link="${bindir}/${name}"
    target="${prefix}/bin/${name}"
    pre="$(harbor_node_link_state "${link}")"
    post="{\"symlink\":\"$(harbor_json_escape "${target}")\"}"
    if [ "${pre}" = "${post}" ]; then
      harbor_journal_create "${root}" file "${link}" observed applied "${pre}" "${post}"
      continue
    fi
    if [ "${pre}" = '"absent"' ]; then
      ownership=created
    else
      ownership=modified
    fi
    harbor_journal_create "${root}" file "${link}" "${ownership}" prepared "${pre}" "${post}"
    entry="${HARBOR_JOURNAL_ENTRY}"
    harbor_step "node-link-${name}"
    tmp="${bindir}/.${name}.harbor.${HARBOR_LOCK_ID_PID:-$$}"
    rm -f "${tmp}"
    ln -s "${target}" "${tmp}"
    mv -f "${tmp}" "${link}"
    [ "$(harbor_node_link_state "${link}")" = "${post}" ] || harbor_die 2 node.link_verify "${link} does not point at ${target} after linking; $(basename "${entry}") stays prepared"
    harbor_journal_set_phase "${entry}" applied
  done
}
# harbor_node_operator_probe OPERATOR: run sh -lc 'node --version' as OPERATOR and
# report what T3's launch will see. Returns 0 when it prints the locked version; a
# failure or another version is a precondition line for the operator to fix in
# their own profile, return 3, and never a reinstall or any other mutation.
harbor_node_operator_probe() {
  local operator="${1}" locked out rc=0
  locked="$(harbor_version_require nodejs_version)" || exit "$?"
  harbor_log_vendor runuser -u "${operator}" -- sh -lc 'node --version'
  out="$(runuser -u "${operator}" -- sh -lc 'node --version' 2>&1)" || rc="$?"
  out="$(printf '%s' "${out}" | tr '\n\r' '  ')"
  if [ "${rc}" -ne 0 ]; then
    harbor_msg "node.operator_probe: precondition: sh -lc 'node --version' as ${operator} failed (exit ${rc}): ${out}; Node.js ${locked} is installed for root, so fix the operator's shell profile until that command prints v${locked}; root will not reinstall"
    return 3
  fi
  if [ "${out}" != "v${locked}" ]; then
    harbor_msg "node.operator_probe: precondition: sh -lc 'node --version' as ${operator} prints ${out}, not v${locked}; the operator's shell profile shadows the Harbor-installed Node.js, fix it until that command prints v${locked}; root will not reinstall"
    return 3
  fi
  harbor_msg "node.operator_probe: sh -lc 'node --version' as ${operator} prints v${locked}"
  return 0
}
