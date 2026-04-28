#!/usr/bin/env bash

# 主编译入口
#
# 支持三种模式：
# 1. prepare-tree
#    只准备源码树，不更新 feeds、不编译。
# 2. prewarm-host-tool
#    预热 host/toolchain 缓存，解决第一次编译很慢的问题。
# 3. build
#    完整编译流程，包含 feeds、配置合并、下载源码和 make。
#
# 维护原则：
# - 机型选择来自 Config/MT3600BE.txt
# - 通用插件选择来自 Config/GENERAL.txt
# - 第三方插件同步逻辑放在 Scripts/Packages.sh
# - 环境与 defconfig 检查放在 Scripts/Settings.sh

set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_URL="${REPO_URL:-https://github.com/VIKINGYFY/immortalwrt.git}"
REPO_BRANCH="${REPO_BRANCH:-owrt}"
WRT_CONFIG="${WRT_CONFIG:-MT3600BE}"
WORK_ROOT="${WORK_ROOT:-$HOME/work}"
BUILD_ROOT="${BUILD_ROOT:-${WORK_ROOT}/immortalwrt-${WRT_CONFIG,,}}"
VENDOR_ROOT="${VENDOR_ROOT:-${WORK_ROOT}/immortalwrt-vendor}"
CACHE_ROOT="${CACHE_ROOT:-${WORK_ROOT}/cache}"
DL_DIR="${DL_DIR:-${CACHE_ROOT}/dl}"
CCACHE_DIR="${CCACHE_DIR:-${CACHE_ROOT}/ccache}"
CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-2G}"
DEVICE_NAME="${DEVICE_NAME:-glinet_gl-mt3600be}"
DEVICE_DTS="${DEVICE_DTS:-mt7987a-glinet-gl-mt3600be}"
# 当前项目默认主题。
# 这里保留环境变量入口，后续如果确实要换主题，只需在工作流里改 WRT_THEME。
WRT_THEME="${WRT_THEME:-aurora}"
JOBS="${JOBS:-$(nproc)}"
TEST_ONLY="${TEST_ONLY:-0}"
BUILD_VERBOSE="${BUILD_VERBOSE:-0}"
BUILD_MODE="${1:-build}"

source "${PROJECT_ROOT}/Scripts/Settings.sh"
source "${PROJECT_ROOT}/Scripts/Packages.sh"

# GitHub 上游偶发返回 500/超时 时，给 clone/fetch 一层轻量重试。
# 这里只兜底网络抖动，不改变现有编译流程结构。
run_git_with_retry() {
  local max_try="${1:-5}"
  shift

  local try
  for ((try=1; try<=max_try; try++)); do
    if "$@"; then
      return 0
    fi

    if [[ "${try}" -lt "${max_try}" ]]; then
      echo "Git command failed on attempt ${try}/${max_try}, retrying ..."
      sleep $((try * 15))
    fi
  done

  echo "Git command failed after ${max_try} attempts: $*"
  return 1
}

# 准备或更新源码树。
# 如果源码目录不存在则直接 clone；
# 如果已存在则只允许在工作树干净时 fast-forward 到目标分支。
prepare_build_tree() {
  mkdir -p "${WORK_ROOT}"

  if [[ ! -d "${BUILD_ROOT}/.git" ]]; then
    rm -rf "${BUILD_ROOT}"
    run_git_with_retry 5 git -c http.version=HTTP/1.1 clone --single-branch --branch "${REPO_BRANCH}" "${REPO_URL}" "${BUILD_ROOT}"
    return
  fi

  cd "${BUILD_ROOT}"
  git remote set-url origin "${REPO_URL}"

  if ! git diff --quiet --ignore-submodules HEAD -- || ! git diff --cached --quiet --ignore-submodules --; then
    echo "Existing build tree is dirty: ${BUILD_ROOT}"
    echo "Please commit/stash tracked source changes before updating it."
    exit 1
  fi

  run_git_with_retry 5 git -c http.version=HTTP/1.1 fetch origin "${REPO_BRANCH}" --depth 1
  git checkout -B "${REPO_BRANCH}" "origin/${REPO_BRANCH}"
}

# 配置共享缓存目录：
# - dl：源码下载缓存
# - ccache：编译缓存
# 这样同一台 runner 或下一次 workflow 复用时会快很多。
prepare_shared_cache_dirs() {
  mkdir -p "${DL_DIR}" "${CCACHE_DIR}"

  if [[ -e "${BUILD_ROOT}/dl" && ! -L "${BUILD_ROOT}/dl" ]]; then
    rm -rf "${BUILD_ROOT}/dl"
  fi

  ln -sfn "${DL_DIR}" "${BUILD_ROOT}/dl"

  export CCACHE_DIR
  export CCACHE_BASEDIR="${BUILD_ROOT}"
  export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"

  if command -v ccache >/dev/null 2>&1; then
    ccache -M "${CCACHE_MAXSIZE}" >/dev/null 2>&1 || true
    echo "ccache stats before build:"
    ccache -s || true
  fi
}

# 恢复 host/toolchain 缓存后，刷新 stamp 时间戳。
# 否则 OpenWrt/ImmortalWrt 可能会误判缓存失效，从头再编一次 host 工具链。
refresh_cached_host_tool_stamps() {
  local stamp_dir
  local refreshed=0

  while IFS= read -r -d '' stamp_dir; do
    case "${stamp_dir}" in
      "${BUILD_ROOT}"/staging_dir/host/stamp|\
      "${BUILD_ROOT}"/staging_dir/hostpkg/stamp|\
      "${BUILD_ROOT}"/staging_dir/toolchain-*/stamp)
        find "${stamp_dir}" -type f -exec touch {} + 2>/dev/null || true
        refreshed=1
        ;;
    esac
  done < <(find "${BUILD_ROOT}/staging_dir" -type d -name stamp -print0 2>/dev/null)

  if [[ "${refreshed}" == "1" ]]; then
    mkdir -p "${BUILD_ROOT}/tmp"
    : > "${BUILD_ROOT}/tmp/.build"
    echo "Refreshed restored host/toolchain cache stamps."
  fi
}

# 进入真正的编译工作目录，并挂接共享缓存。
prepare_build_workspace() {
  prepare_build_tree
  cd "${BUILD_ROOT}"
  prepare_shared_cache_dirs
}

# 统一准备 feeds 与 .config：
# 1. 更新 feeds
# 2. 注入第三方插件
# 3. 安装 feeds 包
# 4. 校验机型与 DTS
# 5. 合并机型和通用配置
prepare_feeds_and_config() {
  ./scripts/feeds update -a
  prepare_custom_packages
  ./scripts/feeds install -a
  sanitize_homeproxy_i18n_conflict

  hotfix_upstream_filogic_mk_parse_error
  validate_device_support
  apply_config_fragments
  refresh_cached_host_tool_stamps
}

# 统一 make 调用。
# BUILD_VERBOSE=1 时开启 V=s 方便排查问题。
run_make() {
  if [[ "${BUILD_VERBOSE}" == "1" ]]; then
    make -j"${JOBS}" V=s "$@"
  else
    make -j"${JOBS}" "$@"
  fi
}

run_full_build() {
  if run_make "$@"; then
    return 0
  fi

  if [[ "${BUILD_VERBOSE}" == "1" ]]; then
    return 1
  fi

  cat <<'EOF'

Parallel build failed.
Re-running once with single-thread verbose output so the real failing package is visible.

EOF
  make -j1 V=s "$@"
}

run_test_only_notice() {
  cat <<EOF

Test-only mode finished.

Generated config:
  ${BUILD_ROOT}/.config
EOF
}

run_build_complete_notice() {
  cat <<EOF

Build finished.

Expected output directory:
  ${BUILD_ROOT}/bin/targets/mediatek/filogic/

Recommended next checks:
  ls -lh ${BUILD_ROOT}/bin/targets/mediatek/filogic/
  sha256sum ${BUILD_ROOT}/bin/targets/mediatek/filogic/*
EOF
}

run_prewarm_complete_notice() {
  cat <<EOF

Host/toolchain prewarm finished.

Prepared cache directories:
  ${BUILD_ROOT}/staging_dir/host
  ${BUILD_ROOT}/staging_dir/hostpkg
EOF
}

# 主流程分发：
# - TEST 工作流会走 build，但 TEST_ONLY=1，只生成配置和日志，不编整套固件。
# - 正式编译会先下载源码，再执行完整 make。
main() {
  validate_host_environment
  case "${BUILD_MODE}" in
    prepare-tree)
      prepare_build_tree
      ;;
    prewarm-host-tool)
      prepare_build_workspace
      prepare_feeds_and_config
      run_make tools/install toolchain/install
      run_prewarm_complete_notice
      ;;
    build)
      prepare_build_workspace
      prepare_feeds_and_config

      if [[ "${TEST_ONLY}" == "1" ]]; then
        run_test_only_notice
        exit 0
      fi

      make download -j"${JOBS}"
      find dl -type f -size -1024c -delete

      run_full_build

      if command -v ccache >/dev/null 2>&1; then
        echo "ccache stats after build:"
        ccache -s || true
      fi

      run_build_complete_notice
      ;;
    *)
      echo "Usage: $0 [build|prepare-tree|prewarm-host-tool]"
      exit 1
      ;;
  esac
}

main "$@"
