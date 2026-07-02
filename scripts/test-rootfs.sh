#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ARTIFACT_BASENAME="${ARTIFACT_BASENAME:-strongswan-trixie-arm64}"
DIST_DIR="${DIST_DIR:-${REPO_ROOT}/dist}"
ROOTFS_TAR="${ROOTFS_TAR:-${DIST_DIR}/${ARTIFACT_BASENAME}-rootfs.tar}"
MANIFEST="${MANIFEST:-${DIST_DIR}/${ARTIFACT_BASENAME}-package-manifest.tsv}"
SHA256SUMS="${SHA256SUMS:-${DIST_DIR}/SHA256SUMS}"

log() {
  printf '[test-rootfs] %s\n' "$*" >&2
}

fail() {
  printf '[test-rootfs] %s\n' "$*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -f "${path}" ]] || fail "missing ${path}"
}

require_path() {
  local root="$1"
  local path="$2"
  [[ -e "${root}${path}" || -L "${root}${path}" ]] || fail "missing ${path}"
}

require_symlink() {
  local root="$1"
  local path="$2"
  local expected_target="$3"

  [[ -L "${root}${path}" ]] || fail "${path} is not a symlink"

  local actual_target
  actual_target="$(readlink "${root}${path}")"
  [[ "${actual_target}" == "${expected_target}" ]] || {
    fail "${path} points to ${actual_target}, expected ${expected_target}"
  }
}

require_glob() {
  local pattern="$1"
  local matches=()

  shopt -s nullglob
  matches=(${pattern})
  shopt -u nullglob

  [[ "${#matches[@]}" -gt 0 ]] || fail "no matches for ${pattern}"
}

check_sha256sums() {
  (
    cd "${DIST_DIR}"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum --check "$(basename -- "${SHA256SUMS}")"
    elif command -v shasum >/dev/null 2>&1; then
      shasum -a 256 --check "$(basename -- "${SHA256SUMS}")"
    else
      fail "missing sha256sum or shasum"
    fi
  )
}

main() {
  require_file "${ROOTFS_TAR}"
  require_file "${MANIFEST}"
  require_file "${SHA256SUMS}"

  check_sha256sums

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT

  log "extracting ${ROOTFS_TAR} for smoke checks"
  if tar --version 2>/dev/null | grep -qi 'gnu tar'; then
    tar --no-same-owner -xf "${ROOTFS_TAR}" -C "${tmp_dir}"
  else
    tar -xf "${ROOTFS_TAR}" -C "${tmp_dir}"
  fi

  require_path "${tmp_dir}" /usr/sbin/ipsec
  require_path "${tmp_dir}" /usr/lib/ipsec/charon
  require_path "${tmp_dir}" /usr/sbin/ip
  require_path "${tmp_dir}" /usr/bin/jq
  require_path "${tmp_dir}" /usr/sbin/conntrack
  require_path "${tmp_dir}" /usr/bin/tcpdump
  require_path "${tmp_dir}" /usr/bin/chmod
  require_path "${tmp_dir}" /usr/bin/sleep
  require_path "${tmp_dir}" /usr/bin/uname
  require_path "${tmp_dir}" /usr/bin/grep
  require_path "${tmp_dir}" /usr/bin/pgrep
  require_path "${tmp_dir}" /bin/bash
  require_symlink "${tmp_dir}" /bin/sh /bin/dash

  require_path "${tmp_dir}" /usr/sbin/iptables-nft
  require_path "${tmp_dir}" /usr/sbin/ip6tables-nft
  require_symlink "${tmp_dir}" /usr/sbin/iptables /usr/sbin/iptables-nft
  require_symlink "${tmp_dir}" /usr/sbin/ip6tables /usr/sbin/ip6tables-nft

  require_glob "${tmp_dir}/usr/lib/ipsec/plugins/libstrongswan-*.so"
  require_glob "${tmp_dir}/var/lib/dpkg/status.d/strongswan-charon"
  require_glob "${tmp_dir}/var/lib/dpkg/status.d/iptables"

  grep -q $'^strongswan-charon\t' "${MANIFEST}" || fail "manifest missing strongswan-charon"
  grep -q $'^iptables\t' "${MANIFEST}" || fail "manifest missing iptables"

  log "rootfs smoke checks passed"
}

main "$@"
