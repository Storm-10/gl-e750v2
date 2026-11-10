#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

main() {
  load_build_env
  require_commands
  prepare_directories
  clone_or_update_openwrt
  detect_kernel_patchver
  sync_feeds_config
  prepare_cache_links
  restore_optional_build_cache
  install_kernel_patches
  copy_custom_packages
  update_and_install_feeds
  force_passwall_packages
  copy_rootfs_files
  apply_local_patches
  install_apk_signing_key
  write_dot_config
  clean_custom_packages
  download_sources
  build_firmware
  collect_release_assets
  save_optional_build_cache
# print_artifact_hint
}

main "$@"
