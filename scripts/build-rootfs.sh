#!/usr/bin/env bash
set -euo pipefail
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

STRONGSWAN_VERSION="${STRONGSWAN_VERSION:-6.0.7}"
STRONGSWAN_SOURCE_URL="${STRONGSWAN_SOURCE_URL:-https://download.strongswan.org/strongswan-${STRONGSWAN_VERSION}.tar.bz2}"
STRONGSWAN_SOURCE_SHA256="${STRONGSWAN_SOURCE_SHA256:-e518e34e159514f4c6ba80d1f926cb151e0dd4e3a1d94213171234b8b9ae6f55}"
ARTIFACT_BASENAME="${ARTIFACT_BASENAME:-strongswan-${STRONGSWAN_VERSION}-trixie-arm64}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
DOCKER_IMAGE="${DOCKER_IMAGE:-debian:trixie-slim}"
SNAPSHOT_HOSTS="${SNAPSHOT_HOSTS:-snapshot-cloudflare.debian.org snapshot.debian.org}"
DOWNLOAD_ATTEMPTS="${DOWNLOAD_ATTEMPTS:-3}"
MAKE_JOBS="${MAKE_JOBS:-}"

CONFIG_DIR="${REPO_ROOT}/config"
PACKAGES_FILE="${PACKAGES_FILE:-${CONFIG_DIR}/packages.txt}"
SOURCES_LIST="${SOURCES_LIST:-${CONFIG_DIR}/debian-snapshot.sources.list}"
SYMLINKS_FILE="${SYMLINKS_FILE:-${CONFIG_DIR}/runtime-symlinks.tsv}"

BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build/${ARTIFACT_BASENAME}}"
DIST_DIR="${DIST_DIR:-${REPO_ROOT}/dist}"
ROOTFS_DIR="${BUILD_DIR}/rootfs"
STRONGSWAN_SOURCE_TARBALL="${BUILD_DIR}/strongswan-${STRONGSWAN_VERSION}.tar.bz2"
STRONGSWAN_SOURCE_DIR="${BUILD_DIR}/strongswan-${STRONGSWAN_VERSION}"
APT_STATE_DIR="${BUILD_DIR}/apt-state"
APT_LISTS_DIR="${APT_STATE_DIR}/lists"
APT_STATUS_FILE="${APT_STATE_DIR}/status"
DEB_DIR="${BUILD_DIR}/debs"
ACTIVE_SOURCES_LIST="${BUILD_DIR}/sources.list"

ROOTFS_TAR="${DIST_DIR}/${ARTIFACT_BASENAME}-rootfs.tar"
MANIFEST="${DIST_DIR}/${ARTIFACT_BASENAME}-package-manifest.tsv"
SHA256SUMS="${DIST_DIR}/SHA256SUMS"

log() {
  printf '[build-rootfs] %s\n' "$*" >&2
}

require_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "${command_name}" >&2
    exit 1
  fi
}

fix_output_ownership() {
  if [[ -n "${HOST_UID:-}" && -n "${HOST_GID:-}" ]]; then
    chown -R "${HOST_UID}:${HOST_GID}" "${BUILD_DIR}" "${DIST_DIR}" 2>/dev/null || true
  fi
}

run_in_docker_if_needed() {
  if [[ "${STRONGSWAN_ROOTFS_IN_CONTAINER:-}" == "1" || "${STRONGSWAN_ROOTFS_NATIVE:-}" == "1" ]]; then
    return
  fi

  require_command docker

  local docker_args=(
    run
    --rm
    --platform "linux/${TARGET_ARCH}"
    -e STRONGSWAN_ROOTFS_IN_CONTAINER=1
    -e STRONGSWAN_VERSION
    -e STRONGSWAN_SOURCE_URL
    -e STRONGSWAN_SOURCE_SHA256
    -e ARTIFACT_BASENAME
    -e TARGET_ARCH
    -e SOURCE_DATE_EPOCH
    -e DOCKER_IMAGE
    -e SNAPSHOT_HOSTS
    -e DOWNLOAD_ATTEMPTS
    -e MAKE_JOBS
    -e HOST_UID="$(id -u)"
    -e HOST_GID="$(id -g)"
    -v "${REPO_ROOT}:/work"
    -w /work
    "${DOCKER_IMAGE}"
    bash
    scripts/build-rootfs.sh
  )

  log "re-running inside ${DOCKER_IMAGE} for linux/${TARGET_ARCH}"
  docker "${docker_args[@]}"
  exit 0
}

read_packages() {
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${PACKAGES_FILE}"
}

resolve_essential_packages() {
  apt-cache "${apt_args[@]}" dumpavail | awk -v target_arch="${TARGET_ARCH}" '
    BEGIN { RS = ""; FS = "\n" }
    {
      package_name = "";
      architecture = "";
      essential = "no";

      for (i = 1; i <= NF; i++) {
        if ($i ~ /^Package: /) {
          package_name = substr($i, 10);
        } else if ($i ~ /^Architecture: /) {
          architecture = substr($i, 15);
        } else if ($i ~ /^Essential: /) {
          essential = tolower(substr($i, 12));
        }
      }

      if (package_name != "" && essential == "yes" && (architecture == target_arch || architecture == "all")) {
        print package_name;
      }
    }
  ' | sort -u
}

apt_option_args() {
  printf '%s\0' \
    -o "APT::Architecture=${TARGET_ARCH}" \
    -o "APT::Architectures::=${TARGET_ARCH}" \
    -o "APT::Get::Assume-Yes=true" \
    -o "APT::Get::Download-Only=true" \
    -o "APT::Install-Recommends=false" \
    -o "APT::Install-Suggests=false" \
    -o "Acquire::Check-Valid-Until=false" \
    -o "Acquire::Retries=5" \
    -o "Acquire::http::Timeout=30" \
    -o "Acquire::https::Timeout=30" \
    -o "Acquire::Languages=none" \
    -o "APT::Update::Error-Mode=any" \
    -o "Dir::State::status=${APT_STATUS_FILE}" \
    -o "Dir::State::lists=${APT_LISTS_DIR}" \
    -o "Dir::Cache::archives=${DEB_DIR}" \
    -o "Dir::Etc::sourcelist=${ACTIVE_SOURCES_LIST}" \
    -o "Dir::Etc::sourceparts=-" \
    -o "Dir::Etc::main=-" \
    -o "APT::Get::List-Cleanup=0"
}

run_with_retries() {
  local description="$1"
  shift

  local attempt
  for ((attempt = 1; attempt <= DOWNLOAD_ATTEMPTS; attempt++)); do
    if "$@"; then
      return 0
    fi

    if [[ "${attempt}" -eq "${DOWNLOAD_ATTEMPTS}" ]]; then
      printf '%s failed after %s attempts\n' "${description}" "${attempt}" >&2
      return 1
    fi

    local sleep_seconds=$((attempt * 10))
    log "${description} failed; retrying in ${sleep_seconds}s"
    sleep "${sleep_seconds}"
  done
}

write_sources_list_for_host() {
  local snapshot_host="$1"

  sed \
    -e "s#https://snapshot.debian.org#https://${snapshot_host}#g" \
    -e "s#https://snapshot-cloudflare.debian.org#https://${snapshot_host}#g" \
    "${SOURCES_LIST}" >"${ACTIVE_SOURCES_LIST}"
}

apply_runtime_symlinks() {
  [[ -f "${SYMLINKS_FILE}" ]] || return

  while IFS=$'\t' read -r link_path target_path; do
    [[ -n "${link_path}" ]] || continue
    [[ "${link_path}" != \#* ]] || continue
    [[ -n "${target_path}" ]] || {
      printf 'bad symlink entry in %s: %s\n' "${SYMLINKS_FILE}" "${link_path}" >&2
      exit 1
    }

    local rootfs_link="${ROOTFS_DIR}${link_path}"
    mkdir -p "$(dirname -- "${rootfs_link}")"
    ln -sfn "${target_path}" "${rootfs_link}"
  done <"${SYMLINKS_FILE}"
}

materialize_base_passwd_files() {
  local etc_dir="${ROOTFS_DIR}/etc"
  local passwd_master="${ROOTFS_DIR}/usr/share/base-passwd/passwd.master"
  local group_master="${ROOTFS_DIR}/usr/share/base-passwd/group.master"

  mkdir -p "${etc_dir}"

  if [[ ! -e "${etc_dir}/passwd" ]]; then
    [[ -f "${passwd_master}" ]] || {
      printf 'missing base-passwd master file: %s\n' "${passwd_master}" >&2
      exit 1
    }
    install -m 0644 "${passwd_master}" "${etc_dir}/passwd"
  fi

  if [[ ! -e "${etc_dir}/group" ]]; then
    [[ -f "${group_master}" ]] || {
      printf 'missing base-passwd master file: %s\n' "${group_master}" >&2
      exit 1
    }
    install -m 0644 "${group_master}" "${etc_dir}/group"
  fi
}

record_name_exists() {
  local file="$1"
  local name="$2"

  awk -F: -v name="${name}" '$1 == name { found = 1 } END { exit found ? 0 : 1 }' "${file}"
}

record_id_exists() {
  local file="$1"
  local id="$2"

  awk -F: -v id="${id}" '$3 == id { found = 1 } END { exit found ? 0 : 1 }' "${file}"
}

record_id_for_name() {
  local file="$1"
  local name="$2"

  awk -F: -v name="${name}" '$1 == name { print $3; exit }' "${file}"
}

next_free_system_id() {
  local passwd_file="$1"
  local group_file="$2"
  local id

  for id in {900..999}; do
    if ! record_id_exists "${passwd_file}" "${id}" && ! record_id_exists "${group_file}" "${id}"; then
      printf '%s\n' "${id}"
      return
    fi
  done

  printf 'could not find free deterministic system uid/gid in 900..999\n' >&2
  exit 1
}

materialize_tcpdump_user() {
  local passwd_file="${ROOTFS_DIR}/etc/passwd"
  local group_file="${ROOTFS_DIR}/etc/group"
  local tcpdump_gid tcpdump_uid

  if record_name_exists "${group_file}" tcpdump; then
    tcpdump_gid="$(record_id_for_name "${group_file}" tcpdump)"
  else
    tcpdump_gid="$(next_free_system_id "${passwd_file}" "${group_file}")"
    printf 'tcpdump:x:%s:\n' "${tcpdump_gid}" >>"${group_file}"
  fi

  if record_name_exists "${passwd_file}" tcpdump; then
    return
  fi

  tcpdump_uid="${tcpdump_gid}"
  if record_id_exists "${passwd_file}" "${tcpdump_uid}"; then
    tcpdump_uid="$(next_free_system_id "${passwd_file}" "${group_file}")"
  fi

  printf 'tcpdump:x:%s:%s:tcpdump:/nonexistent:/usr/sbin/nologin\n' "${tcpdump_uid}" "${tcpdump_gid}" >>"${passwd_file}"
}

materialize_base_files_runtime_links() {
  mkdir -p "${ROOTFS_DIR}/run/lock" "${ROOTFS_DIR}/var"
  rm -rf "${ROOTFS_DIR}/var/run" "${ROOTFS_DIR}/var/lock"
  ln -s /run "${ROOTFS_DIR}/var/run"
  ln -s /run/lock "${ROOTFS_DIR}/var/lock"
}

generate_ld_so_cache() {
  [[ -x "${ROOTFS_DIR}/sbin/ldconfig" || -x "${ROOTFS_DIR}/usr/sbin/ldconfig" ]] || {
    printf 'rootfs is missing ldconfig; cannot generate ld.so.cache\n' >&2
    exit 1
  }

  ldconfig -r "${ROOTFS_DIR}"
}

write_status_file() {
  local deb="$1"
  local package_name="$2"
  local status_file="${ROOTFS_DIR}/var/lib/dpkg/status.d/${package_name}"

  mkdir -p "$(dirname -- "${status_file}")"
  dpkg-deb -f "${deb}" | awk '
    BEGIN { inserted = 0 }
    /^Package:/ {
      print
      print "Status: install ok installed"
      inserted = 1
      next
    }
    { print }
    END {
      if (inserted == 0) {
        print "Status: install ok installed"
      }
    }
  ' >"${status_file}"
}

ensure_build_dependencies() {
  if [[ "${STRONGSWAN_ROOTFS_IN_CONTAINER:-}" != "1" ]]; then
    return
  fi

  log "installing source build dependencies in ephemeral build container"
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
    bzip2 \
    build-essential \
    ca-certificates \
    curl \
    libcap-dev \
    libgmp-dev \
    libssl-dev \
    pkg-config
}

download_strongswan_source() {
  require_command curl

  log "downloading strongSwan ${STRONGSWAN_VERSION} from ${STRONGSWAN_SOURCE_URL}"
  curl \
    --fail \
    --location \
    --retry "${DOWNLOAD_ATTEMPTS}" \
    --retry-delay 5 \
    --show-error \
    --silent \
    --output "${STRONGSWAN_SOURCE_TARBALL}" \
    "${STRONGSWAN_SOURCE_URL}"

  local actual_sha
  actual_sha="$(sha256sum "${STRONGSWAN_SOURCE_TARBALL}" | awk '{ print $1 }')"
  if [[ "${actual_sha}" != "${STRONGSWAN_SOURCE_SHA256}" ]]; then
    printf 'strongSwan source SHA256 mismatch: got %s, expected %s\n' "${actual_sha}" "${STRONGSWAN_SOURCE_SHA256}" >&2
    exit 1
  fi

  tar -xf "${STRONGSWAN_SOURCE_TARBALL}" -C "${BUILD_DIR}"
  [[ -d "${STRONGSWAN_SOURCE_DIR}" ]] || {
    printf 'strongSwan source archive did not create %s\n' "${STRONGSWAN_SOURCE_DIR}" >&2
    exit 1
  }
}

make_jobs() {
  if [[ -n "${MAKE_JOBS}" ]]; then
    printf '%s\n' "${MAKE_JOBS}"
  elif command -v nproc >/dev/null 2>&1; then
    nproc
  else
    getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2\n'
  fi
}

build_strongswan_from_source() {
  require_command make

  local jobs
  jobs="$(make_jobs)"

  local configure_args=(
    --prefix=/usr
    --sysconfdir=/etc
    --libdir=/usr/lib
    --libexecdir=/usr/lib
    --localstatedir=/var
    --runstatedir=/run
    --with-ipsecdir=/usr/lib/ipsec
    --with-ipseclibdir=/usr/lib/ipsec
    --with-plugindir=/usr/lib/ipsec/plugins
    --with-capabilities=libcap
    --enable-aes
    --enable-ccm
    --enable-chapoly
    --enable-ctr
    --enable-gcm
    --enable-gmp
    --enable-hmac
    --enable-md5
    --enable-mgf1
    --enable-openssl
    --enable-sha1
    --enable-sha2
    --enable-stroke
    --enable-swanctl
    --disable-systemd
    --disable-blowfish
    --disable-des
    --disable-dependency-tracking
    --enable-silent-rules
  )

  log "building strongSwan ${STRONGSWAN_VERSION} from source with ${jobs} jobs"
  (
    cd "${STRONGSWAN_SOURCE_DIR}"
    ./configure "${configure_args[@]}"
    make -j "${jobs}" V=0
    make install DESTDIR="${ROOTFS_DIR}" V=0
  )

  find "${ROOTFS_DIR}/usr/lib" \( -name '*.la' -o -name '*.a' \) -delete
  printf 'strongswan-upstream\t%s\t%s\t%s\t%s\n' \
    "${STRONGSWAN_VERSION}" \
    "${TARGET_ARCH}" \
    "${STRONGSWAN_SOURCE_SHA256}" \
    "$(basename -- "${STRONGSWAN_SOURCE_TARBALL}")" >>"${MANIFEST}"
}

build_rootfs() {
  require_command apt-get
  require_command apt-cache
  require_command awk
  require_command dpkg-deb
  require_command find
  require_command grep
  require_command install
  require_command ldconfig
  require_command sed
  require_command sha256sum
  require_command sort
  require_command tar

  if ! tar --version 2>/dev/null | grep -qi 'gnu tar'; then
    printf 'GNU tar is required for deterministic archive flags\n' >&2
    exit 1
  fi

  mapfile -t packages < <(read_packages)
  if [[ "${#packages[@]}" -eq 0 ]]; then
    printf 'no packages configured in %s\n' "${PACKAGES_FILE}" >&2
    exit 1
  fi

  rm -rf "${BUILD_DIR}"
  mkdir -p "${ROOTFS_DIR}" "${DIST_DIR}"

  ensure_build_dependencies
  download_strongswan_source

  local apt_args=()
  while IFS= read -r -d '' arg; do
    apt_args+=("${arg}")
  done < <(apt_option_args)

  local snapshot_host download_succeeded=0
  for snapshot_host in ${SNAPSHOT_HOSTS}; do
    rm -rf "${APT_STATE_DIR}" "${DEB_DIR}" "${ACTIVE_SOURCES_LIST}"
    mkdir -p "${APT_LISTS_DIR}/partial" "${DEB_DIR}/partial"
    : >"${APT_STATUS_FILE}"
    write_sources_list_for_host "${snapshot_host}"

    log "updating apt metadata from ${snapshot_host}"
    if ! run_with_retries "apt snapshot update from ${snapshot_host}" apt-get "${apt_args[@]}" update; then
      log "metadata fetch failed from ${snapshot_host}; trying next snapshot host"
      continue
    fi

    mapfile -t essential_packages < <(resolve_essential_packages)
    mapfile -t install_packages < <(printf '%s\n' "${essential_packages[@]}" "${packages[@]}" | sort -u)

    log "resolving and downloading ${#install_packages[@]} packages for ${TARGET_ARCH} from ${snapshot_host} (${#packages[@]} configured, ${#essential_packages[@]} essential)"
    if run_with_retries "apt package download from ${snapshot_host}" apt-get "${apt_args[@]}" install "${install_packages[@]}"; then
      download_succeeded=1
      break
    fi

    log "package download failed from ${snapshot_host}; trying next snapshot host"
  done

  if [[ "${download_succeeded}" != "1" ]]; then
    printf 'failed to download package closure from snapshot hosts: %s\n' "${SNAPSHOT_HOSTS}" >&2
    exit 1
  fi

  mapfile -d '' -t debs < <(find "${DEB_DIR}" -maxdepth 1 -type f -name '*.deb' -print0 | sort -z)
  if [[ "${#debs[@]}" -eq 0 ]]; then
    printf 'apt did not download any .deb files into %s\n' "${DEB_DIR}" >&2
    exit 1
  fi

  log "extracting ${#debs[@]} Debian packages"
  printf 'package\tversion\tarchitecture\tsha256\tartifact\n' >"${MANIFEST}"
  mkdir -p "${ROOTFS_DIR}/var/lib/dpkg"
  : >"${ROOTFS_DIR}/var/lib/dpkg/status"
  for deb in "${debs[@]}"; do
    local package_name version architecture sha deb_name
    package_name="$(dpkg-deb -f "${deb}" Package)"
    version="$(dpkg-deb -f "${deb}" Version)"
    architecture="$(dpkg-deb -f "${deb}" Architecture)"
    sha="$(sha256sum "${deb}" | awk '{print $1}')"
    deb_name="$(basename -- "${deb}")"

    dpkg-deb -x "${deb}" "${ROOTFS_DIR}"
    write_status_file "${deb}" "${package_name}"
    cat "${ROOTFS_DIR}/var/lib/dpkg/status.d/${package_name}" >>"${ROOTFS_DIR}/var/lib/dpkg/status"
    printf '\n' >>"${ROOTFS_DIR}/var/lib/dpkg/status"
    printf '%s\t%s\t%s\t%s\t%s\n' "${package_name}" "${version}" "${architecture}" "${sha}" "${deb_name}" >>"${MANIFEST}"
  done

  build_strongswan_from_source
  apply_runtime_symlinks
  materialize_base_passwd_files
  materialize_tcpdump_user
  materialize_base_files_runtime_links
  generate_ld_so_cache

  log "creating deterministic rootfs tar"
  rm -f "${ROOTFS_TAR}" "${SHA256SUMS}"
  tar \
    --sort=name \
    --mtime="@${SOURCE_DATE_EPOCH}" \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --pax-option=delete=atime,delete=ctime \
    -cf "${ROOTFS_TAR}" \
    -C "${ROOTFS_DIR}" \
    .

  (
    cd "${DIST_DIR}"
    sha256sum "$(basename -- "${ROOTFS_TAR}")" "$(basename -- "${MANIFEST}")" >"$(basename -- "${SHA256SUMS}")"
  )

  fix_output_ownership

  log "wrote ${ROOTFS_TAR}"
  log "wrote ${MANIFEST}"
  log "wrote ${SHA256SUMS}"
}

run_in_docker_if_needed
trap fix_output_ownership EXIT
build_rootfs
