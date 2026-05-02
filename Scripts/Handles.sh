#!/usr/bin/env bash

# 编译产物与 Release 辅助脚本
#
# 作用：
# - 把固件、manifest、build.log、.config 等文件统一收集到 artifact 目录。
# - 生成 GitHub Release 所需的 tag、标题和发布说明。
#
# 这样工作流本身可以保持简洁，具体命名、打包和发布信息都统一收口在这里。
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK_ROOT="${WORK_ROOT:-$HOME/work}"
WRT_CONFIG="${WRT_CONFIG:-MT3600BE}"
BUILD_ROOT="${BUILD_ROOT:-${WORK_ROOT}/immortalwrt-${WRT_CONFIG,,}}"
RUNNER_TEMP="${RUNNER_TEMP:-${PROJECT_ROOT}/.tmp}"
TARGET_DIR="${TARGET_DIR:-${BUILD_ROOT}/bin/targets/mediatek/filogic}"
ARTIFACT_DIR="${ARTIFACT_DIR:-${RUNNER_TEMP}/mt3600be-artifacts}"
WRT_NAME="${WRT_NAME:-GL-MT3600BE}"
WRT_DEVICE_LABEL="${WRT_DEVICE_LABEL:-GL.iNet GL-MT3600BE}"
DEVICE_NAME="${DEVICE_NAME:-glinet_gl-mt3600be}"
DEVICE_DTS="${DEVICE_DTS:-mt7987a-glinet-gl-mt3600be}"
REPO_BRANCH="${REPO_BRANCH:-owrt}"
RELEASE_TAG_PREFIX="${RELEASE_TAG_PREFIX:-mt3600be}"
TEST_ONLY="${TEST_ONLY:-0}"

# 收集 artifacts。
# TEST_ONLY=1 时只收集日志和 .config；正式编译则额外收集固件、manifest、buildinfo、json 等文件。
collect_artifacts() {
  local file
  local files=()

  mkdir -p "${ARTIFACT_DIR}"

  files+=("${RUNNER_TEMP}/build.log")

  if [[ -f "${BUILD_ROOT}/.config" ]]; then
    cp -v "${BUILD_ROOT}/.config" "${ARTIFACT_DIR}/${WRT_CONFIG}.config"
  fi

  if [[ "${TEST_ONLY}" != "1" ]]; then
    files+=(
      "${TARGET_DIR}"/*"${DEVICE_NAME}"*sysupgrade*.bin
      "${TARGET_DIR}"/*"${DEVICE_NAME}"*initramfs*.bin
      "${TARGET_DIR}"/*"${DEVICE_NAME}"*.itb
      "${TARGET_DIR}"/*"${DEVICE_DTS}"*.bin
      "${TARGET_DIR}"/*"${DEVICE_NAME}"*.bin
      "${TARGET_DIR}"/*.buildinfo
      "${TARGET_DIR}"/*.json
      "${TARGET_DIR}"/*.manifest
    )
  fi

  for file in "${files[@]}"; do
    if [[ -f "${file}" ]]; then
      cp -v "${file}" "${ARTIFACT_DIR}/"
    fi
  done

  if ! find "${ARTIFACT_DIR}" -maxdepth 1 -type f | grep -q .; then
    echo "No artifacts were collected."
    exit 1
  fi

  (
    cd "${ARTIFACT_DIR}"
    local copied=(*)
    if [[ ${#copied[@]} -gt 0 ]]; then
      sha256sum "${copied[@]}" > SHA256SUMS
    fi
    ls -lh
  )
}

# 从本次实际拉取的源码树里识别内核版本。
# 优先读取目标平台 Makefile 的 KERNEL_PATCHVER，再读取 generic/kernel-x.xx 里的小版本号。
detect_kernel_version() {
  local kernel_patchver=""
  local kernel_suffix=""
  local target_makefile="${BUILD_ROOT}/target/linux/mediatek/Makefile"
  local kernel_details_file

  if [[ -f "${target_makefile}" ]]; then
    kernel_patchver="$(awk -F':=' '
      /^[[:space:]]*KERNEL_PATCHVER[[:space:]]*:=/ {
        gsub(/[[:space:]]/, "", $2)
        print $2
        exit
      }
    ' "${target_makefile}")"
  fi

  if [[ -z "${kernel_patchver}" && -f "${BUILD_ROOT}/.config" ]]; then
    kernel_patchver="$(awk -F= '
      /^CONFIG_LINUX_[0-9]+_[0-9]+(=y)?$/ {
        gsub(/^CONFIG_LINUX_/, "", $1)
        gsub(/_/, ".", $1)
        print $1
        exit
      }
    ' "${BUILD_ROOT}/.config")"
  fi

  if [[ -z "${kernel_patchver}" ]]; then
    echo "unknown"
    return 0
  fi

  kernel_details_file="${BUILD_ROOT}/target/linux/generic/kernel-${kernel_patchver}"
  if [[ -f "${kernel_details_file}" ]]; then
    kernel_suffix="$(awk -F'=' -v patchver="${kernel_patchver}" '
      $1 ~ "^[[:space:]]*LINUX_VERSION-" patchver "[[:space:]]*$" {
        gsub(/[[:space:]]/, "", $2)
        print $2
        exit
      }
    ' "${kernel_details_file}")"
  fi

  echo "Linux ${kernel_patchver}${kernel_suffix}"
}

# 生成 GitHub Release 元数据。
# tag 会带上分支、UTC 时间和 run number，方便之后回看每次自动构建。
prepare_release_metadata() {
  local branch_slug
  local build_commit
  local build_time
  local kernel_version
  local tag
  local title
  local notes_file

  branch_slug="$(printf '%s' "${REPO_BRANCH}" | tr '/ ' '--' | tr -cd '[:alnum:]._-')"
  build_commit="$(git -C "${BUILD_ROOT}" rev-parse --short=12 HEAD)"
  build_time="$(date -u +'%Y%m%d-%H%M%S')"
  kernel_version="$(detect_kernel_version)"
  tag="${RELEASE_TAG_PREFIX}-${branch_slug}-${build_time}-run${GITHUB_RUN_NUMBER:-local}"
  title="${WRT_DEVICE_LABEL} ImmortalWrt ${branch_slug} ${build_time}"
  notes_file="${RUNNER_TEMP}/release-notes.md"

  {
    echo "# ${WRT_DEVICE_LABEL} automated build"
    echo
    echo "- Config: \`${WRT_CONFIG}\`"
    echo "- Branch: \`${REPO_BRANCH}\`"
    echo "- Kernel: \`${kernel_version}\`"
    echo "- Commit: \`${build_commit}\`"
    if [[ -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
      echo "- Workflow run: [#${GITHUB_RUN_NUMBER}](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID})"
    fi
    echo "- Trigger event: \`${GITHUB_EVENT_NAME:-manual}\`"
    echo
    echo "Firmware files and checksums are attached below."
  } > "${notes_file}"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "tag=${tag}"
      echo "title=${title}"
      echo "notes_file=${notes_file}"
    } >> "${GITHUB_OUTPUT}"
  else
    echo "tag=${tag}"
    echo "title=${title}"
    echo "notes_file=${notes_file}"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    collect-artifacts)
      collect_artifacts
      ;;
    prepare-release-metadata)
      prepare_release_metadata
      ;;
    *)
      echo "Usage: $0 collect-artifacts|prepare-release-metadata"
      exit 1
      ;;
  esac
fi
