#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ENV_FILE="${ROOT_DIR}/config/build.env"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

load_build_env() {
  [[ -f "${BUILD_ENV_FILE}" ]] || die "missing ${BUILD_ENV_FILE}"
  # shellcheck disable=SC1090
  source "${BUILD_ENV_FILE}"

  export OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/openwrt/openwrt.git}"
  export OPENWRT_REF="${OPENWRT_REF:-v25.12.4}"
  export OPENWRT_TARGET="${OPENWRT_TARGET:-ath79}"
  export OPENWRT_SUBTARGET="${OPENWRT_SUBTARGET:-nand}"
  export OPENWRT_PROFILE="${OPENWRT_PROFILE:-glinet_gl-e750}"
  export OPENWRT_WORKDIR="${OPENWRT_WORKDIR:-workdir}"
  export OPENWRT_SRC_DIR="${OPENWRT_SRC_DIR:-openwrt}"
  export DL_DIR="${DL_DIR:-.cache/openwrt/dl}"
  export CCACHE_DIR="${CCACHE_DIR:-.cache/openwrt/ccache}"
  export BUILD_CACHE_DIR="${BUILD_CACHE_DIR:-.cache/openwrt/build}"
  export KEEP_BUILD_DIR_CACHE="${KEEP_BUILD_DIR_CACHE:-0}"
  export JOBS="${JOBS:-}"

  if [[ "${OPENWRT_WORKDIR}" = /* ]]; then
    export WORKDIR_ABS="${OPENWRT_WORKDIR}"
  else
    export WORKDIR_ABS="${ROOT_DIR}/${OPENWRT_WORKDIR}"
  fi
  export SRC_DIR_ABS="${WORKDIR_ABS}/${OPENWRT_SRC_DIR}"
  export DL_DIR_ABS="${ROOT_DIR}/${DL_DIR}"
  export CCACHE_DIR_ABS="${ROOT_DIR}/${CCACHE_DIR}"
  export BUILD_CACHE_DIR_ABS="${ROOT_DIR}/${BUILD_CACHE_DIR}"
}

require_commands() {
  local cmd
  for cmd in git make rsync find xargs; do
    command -v "${cmd}" >/dev/null 2>&1 || die "required command not found: ${cmd}"
  done
}

prepare_directories() {
  mkdir -p "${WORKDIR_ABS}" "${DL_DIR_ABS}" "${CCACHE_DIR_ABS}"
  if [[ "${KEEP_BUILD_DIR_CACHE}" == "1" ]]; then
    mkdir -p "${BUILD_CACHE_DIR_ABS}"
  fi
}

clone_or_update_openwrt() {
  if [[ ! -d "${SRC_DIR_ABS}/.git" ]]; then
    log "Cloning ${OPENWRT_REPO} at ${OPENWRT_REF}"
    git clone --depth=1 --branch "${OPENWRT_REF}" "${OPENWRT_REPO}" "${SRC_DIR_ABS}"
    return
  fi

  log "Refreshing OpenWrt source tree"
  git -C "${SRC_DIR_ABS}" remote set-url origin "${OPENWRT_REPO}"
  git -C "${SRC_DIR_ABS}" fetch --depth=1 --tags origin "${OPENWRT_REF}"
  git -C "${SRC_DIR_ABS}" checkout --force "${OPENWRT_REF}"
  git -C "${SRC_DIR_ABS}" reset --hard FETCH_HEAD
}

detect_kernel_patchver() {
  local target_makefile
  target_makefile="${SRC_DIR_ABS}/target/linux/${OPENWRT_TARGET}/Makefile"
  [[ -f "${target_makefile}" ]] || die "missing target makefile: ${target_makefile}"

  export KERNEL_PATCHVER
  KERNEL_PATCHVER="$(awk -F ':=' '/^KERNEL_PATCHVER:=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "${target_makefile}")"
  [[ -n "${KERNEL_PATCHVER}" ]] || die "failed to detect KERNEL_PATCHVER from ${target_makefile}"
}

sync_feeds_config() {
  if [[ -f "${ROOT_DIR}/config/feeds.conf.default" ]]; then
    cp "${ROOT_DIR}/config/feeds.conf.default" "${SRC_DIR_ABS}/feeds.conf.default"
  fi
}


update_and_install_feeds() {
  reset_feed_worktrees

  log "Updating feeds"
  (cd "${SRC_DIR_ABS}" && ./scripts/feeds update -a)

  reset_feed_worktrees

  log "Installing feeds"
  (cd "${SRC_DIR_ABS}" && ./scripts/feeds install -a)
}


reset_feed_worktrees() {
  local feed

  log "SRC_DIR_ABS: ${SRC_DIR_ABS}"
  [[ -d "${SRC_DIR_ABS}/feeds" ]] || return 0

  while IFS= read -r feed; do
    log "Resetting feed worktree $(basename "${feed}")"
    git -C "${feed}" reset --hard
    git -C "${feed}" clean -fd
  done < <(find "${SRC_DIR_ABS}/feeds" -mindepth 2 -maxdepth 2 -name .git -type d -printf '%h\n' | sort)
}

copy_custom_packages() {
  if find "${ROOT_DIR}/packages" -mindepth 2 -name Makefile -print -quit | grep -q .; then
    log "Copying custom packages into package/custom"
    rm -rf "${SRC_DIR_ABS}/package/custom"
    mkdir -p "${SRC_DIR_ABS}/package/custom"
    rsync -a --delete "${ROOT_DIR}/packages/" "${SRC_DIR_ABS}/package/custom/"
  fi
  log "Done Copying custom packages"
}

clean_custom_packages() {
  local makefile pkg

  [[ -d "${ROOT_DIR}/packages" ]] || return

  while IFS= read -r makefile; do
    pkg="$(basename "$(dirname "${makefile}")")"
    log "Cleaning custom package ${pkg}"
    (cd "${SRC_DIR_ABS}" && make "package/${pkg}/clean")
  done < <(find "${ROOT_DIR}/packages" -mindepth 2 -maxdepth 2 -name Makefile | sort)
}

copy_rootfs_files() {
  if [[ ! -d "${ROOT_DIR}/files" ]]; then
    return
  fi

  log "Synchronizing rootfs overlay files"
  mkdir -p "${SRC_DIR_ABS}/files"
  rsync -a --delete --exclude '.gitkeep' "${ROOT_DIR}/files/" "${SRC_DIR_ABS}/files/"
}

apply_local_patches() {
  local patch
  shopt -s nullglob
  for patch in "${ROOT_DIR}"/patches/openwrt/*.patch; do
    log "Applying OpenWrt tree patch $(basename "${patch}")"
    (cd "${SRC_DIR_ABS}" && patch -p1 < "${patch}")
  done
  shopt -u nullglob
}

install_kernel_patches() {
  local source_dir target_dir patch

  target_dir="${SRC_DIR_ABS}/target/linux/${OPENWRT_TARGET}/patches-${KERNEL_PATCHVER}"
  mkdir -p "${target_dir}"
  find "${target_dir}" -maxdepth 1 -type f -name '9[0-9][0-9]-local-*.patch' -delete

  source_dir="${ROOT_DIR}/patches/kernel/${OPENWRT_TARGET}/${KERNEL_PATCHVER}"
  if [[ -d "${source_dir}" ]]; then
    shopt -s nullglob
    for patch in "${source_dir}"/*.patch; do
      log "Installing target kernel patch $(basename "${patch}")"
      cp "${patch}" "${target_dir}/"
    done
    shopt -u nullglob
  fi

  target_dir="${SRC_DIR_ABS}/target/linux/generic/pending-${KERNEL_PATCHVER}"
  source_dir="${ROOT_DIR}/patches/kernel/generic/${KERNEL_PATCHVER}"
  if [[ -d "${source_dir}" ]]; then
    mkdir -p "${target_dir}"
    find "${target_dir}" -maxdepth 1 -type f -name '9[0-9][0-9]-local-*.patch' -delete
    shopt -s nullglob
    for patch in "${source_dir}"/*.patch; do
      log "Installing generic kernel patch $(basename "${patch}")"
      cp "${patch}" "${target_dir}/"
    done
    shopt -u nullglob
  fi
}

prepare_cache_links() {
  rm -rf "${SRC_DIR_ABS}/dl"
  ln -sfn "${DL_DIR_ABS}" "${SRC_DIR_ABS}/dl"
  export CCACHE_DIR="${CCACHE_DIR_ABS}"
  export CCACHE_BASEDIR="${SRC_DIR_ABS}"
  export CCACHE_COMPRESS=1
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
  command -v ccache >/dev/null 2>&1 && ccache -M "${CCACHE_MAXSIZE}" >/dev/null 2>&1 || true
}

restore_optional_build_cache() {
  if [[ "${KEEP_BUILD_DIR_CACHE}" != "1" ]]; then
    return
  fi

  if [[ -d "${BUILD_CACHE_DIR_ABS}/build_dir" ]]; then
    log "Restoring cached build_dir"
    rsync -a --delete "${BUILD_CACHE_DIR_ABS}/build_dir/" "${SRC_DIR_ABS}/build_dir/"
  fi

  if [[ -d "${BUILD_CACHE_DIR_ABS}/staging_dir" ]]; then
    log "Restoring cached staging_dir"
    rsync -a --delete "${BUILD_CACHE_DIR_ABS}/staging_dir/" "${SRC_DIR_ABS}/staging_dir/"
  fi
}

save_optional_build_cache() {
  if [[ "${KEEP_BUILD_DIR_CACHE}" != "1" ]]; then
    return
  fi

  log "Saving selected build intermediates"
  mkdir -p "${BUILD_CACHE_DIR_ABS}/build_dir" "${BUILD_CACHE_DIR_ABS}/staging_dir"
  rsync -a --delete "${SRC_DIR_ABS}/build_dir/" "${BUILD_CACHE_DIR_ABS}/build_dir/"
  rsync -a --delete "${SRC_DIR_ABS}/staging_dir/" "${BUILD_CACHE_DIR_ABS}/staging_dir/"
}

write_dot_config() {
  log "Generating .config from diffconfig"
  cp "${ROOT_DIR}/config/diffconfig" "${SRC_DIR_ABS}/.config"
  (cd "${SRC_DIR_ABS}" && make defconfig)
}

download_sources() {
  log "Downloading sources"
  (cd "${SRC_DIR_ABS}" && make download -j8)
}

build_firmware() {
  local jobs
  jobs=$(nproc)
  log "Starting download"
  cd "${SRC_DIR_ABS}" && make download
  log "Starting build with ${jobs} job(s)"
  if ! (cd "${SRC_DIR_ABS}" && make -j"${jobs}"); then
    log "Parallel build failed, retrying with verbose single-thread build"
    (cd "${SRC_DIR_ABS}" && make -j1 V=s)
  fi
}

print_artifact_hint() {
  log "Artifacts should be under ${SRC_DIR_ABS}/bin/targets/${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}"
}
