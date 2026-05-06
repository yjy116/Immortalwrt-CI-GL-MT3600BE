#!/usr/bin/env bash

# 编译前环境与配置处理脚本
#
# 负责：
# - 检查当前运行环境是否适合编译
# - 检查目标机型和 DTS 是否在上游源码中存在
# - 合并机型配置与通用插件配置到 .config
# - 参考 AXT1800 项目设置 Aurora 为默认 LuCI 主题
# - 自动给已启用的 LuCI 插件补充可用的简体中文语言包
# - 在 defconfig 后做关键符号的宽松校验
#
# 这里采用“宽松模式”：
# 如果中文基础包或默认中文设置没有进入 .config，只警告，不强制中断编译。

set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG_DIR="${CONFIG_DIR:-${PROJECT_ROOT}/Config}"
WRT_CONFIG="${WRT_CONFIG:-MT3600BE}"
WRT_CONFIG_FILE="${WRT_CONFIG_FILE:-${CONFIG_DIR}/${WRT_CONFIG}.txt}"
GENERAL_CONFIG_FILE="${GENERAL_CONFIG_FILE:-${CONFIG_DIR}/GENERAL.txt}"
KERNEL_CONFIG_FILE="${KERNEL_CONFIG_FILE:-${CONFIG_DIR}/${WRT_CONFIG}.kernel.txt}"
WORK_ROOT="${WORK_ROOT:-$HOME/work}"
BUILD_ROOT="${BUILD_ROOT:-${WORK_ROOT}/immortalwrt-${WRT_CONFIG,,}}"
DEVICE_NAME="${DEVICE_NAME:-glinet_gl-mt3600be}"
DEVICE_DTS="${DEVICE_DTS:-mt7987a-glinet-gl-mt3600be}"
WRT_THEME="${WRT_THEME:-aurora}"
LANGUAGE_CORE_PACKAGES=(
  "CONFIG_PACKAGE_luci=y"
  "CONFIG_PACKAGE_default-settings-chn=y"
  "CONFIG_PACKAGE_luci-i18n-base-zh-cn=y"
  "CONFIG_PACKAGE_luci-i18n-firewall-zh-cn=y"
)
REQUIRED_CONFIG_SYMBOLS=(
  "CONFIG_PACKAGE_luci=y"
  "CONFIG_PACKAGE_default-settings-chn=y"
  "CONFIG_PACKAGE_luci-i18n-base-zh-cn=y"
)
DAED_REQUIRED_CONFIG_SYMBOLS=(
  "CONFIG_PACKAGE_daed=y"
  "CONFIG_PACKAGE_luci-app-daed=y"
  "CONFIG_DAED_USE_KERNEL_BTF=y"
  "CONFIG_BPF_TOOLCHAIN_BUILD_LLVM=y"
  "CONFIG_KERNEL_CGROUPS=y"
  "CONFIG_KERNEL_DEBUG_INFO_BTF=y"
  "CONFIG_KERNEL_BPF_EVENTS=y"
  "CONFIG_KERNEL_CGROUP_BPF=y"
  "CONFIG_KERNEL_XDP_SOCKETS=y"
  "CONFIG_KERNEL_ARM64_BRBE=y"
  "CONFIG_PACKAGE_kmod-sched-bpf=y"
  "CONFIG_PACKAGE_kmod-sched-core=y"
  "CONFIG_PACKAGE_kmod-xdp-sockets-diag=y"
)

# OpenWrt/ImmortalWrt 在 /mnt/c 这类 Windows 挂载盘上编译非常不稳，
# 容易触发权限、性能和时间戳问题，所以这里提前拦住。
is_windows_mount_path() {
  local path="$1"
  [[ "${path}" =~ ^/mnt/[A-Za-z](/|$) ]]
}

# 避免重复写入同一行配置。
append_config_line_if_missing() {
  local line="$1"
  grep -qxF "${line}" .config || echo "${line}" >> .config
}

# 判断 GENERAL.txt 里是否显式启用了某个包。
general_config_package_enabled() {
  local package_name="$1"
  [[ -f "${GENERAL_CONFIG_FILE}" ]] && grep -Eq "^CONFIG_PACKAGE_${package_name}=y$" "${GENERAL_CONFIG_FILE}"
}

# 只对真正带简中翻译目录的 LuCI 包自动追加语言包。
# 这样即使上游改了包、删了翻译或第三方插件没有语言目录，也不会因为写死 luci-i18n 包名而报错。
source_package_has_zh_translation() {
  local package_name="$1"
  local package_dir

  while IFS= read -r -d '' package_dir; do
    if [[ -d "${package_dir}/po/zh_Hans" || -d "${package_dir}/po/zh-cn" || -d "${package_dir}/po/zh_CN" ]]; then
      return 0
    fi
  done < <(find "${BUILD_ROOT}/feeds" "${BUILD_ROOT}/package" -type d -name "${package_name}" -print0 2>/dev/null)

  return 1
}

# 预留跳过列表：如果后续遇到某个 LuCI 插件的语言包确实会破坏编译，
# 可以在这里单独跳过。当前 HomeProxy 的冲突改由 Packages.sh 精确处理，
# 因此这里默认不跳过任何可用的简中语言包。
should_skip_auto_i18n_package() {
  local package_name="$1"
  return 1
}

# 校验宿主环境是否满足最基本的编译条件。
validate_host_environment() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "This script must run inside Linux or WSL2."
    exit 1
  fi

  if is_windows_mount_path "${PWD}" || is_windows_mount_path "${PROJECT_ROOT}" || is_windows_mount_path "${WORK_ROOT}" || is_windows_mount_path "${BUILD_ROOT}"; then
    cat <<'EOF'
Do not build OpenWrt/ImmortalWrt from a Windows-mounted path such as /mnt/c.
Use a native Linux path like:
  export WORK_ROOT=$HOME/work
EOF
    exit 1
  fi

  if ! command -v git >/dev/null 2>&1; then
    echo "git is required. Run Scripts/bootstrap-ubuntu.sh first."
    exit 1
  fi

  if ! command -v make >/dev/null 2>&1; then
    echo "make is required. Run Scripts/bootstrap-ubuntu.sh first."
    exit 1
  fi

  if [[ ! -f "${WRT_CONFIG_FILE}" ]]; then
    echo "Device config not found: ${WRT_CONFIG_FILE}"
    exit 1
  fi

  if [[ ! -f "${GENERAL_CONFIG_FILE}" ]]; then
    echo "General config not found: ${GENERAL_CONFIG_FILE}"
    exit 1
  fi
}

# 校验上游源码是否真的支持当前机型。
# 这一步可以在分支切换时尽早发现“设备 profile 不存在”这类问题。
validate_device_support() {
  if ! grep -Rqs "define Device/${DEVICE_NAME}" target/linux/mediatek/image/filogic.mk; then
    echo "Device profile ${DEVICE_NAME} was not found."
    exit 2
  fi

  if [[ ! -f "target/linux/mediatek/dts/${DEVICE_DTS}.dts" ]]; then
    echo "Device DTS ${DEVICE_DTS}.dts was not found."
    exit 2
  fi
}

# Temporary upstream hotfix for VIKINGYFY/immortalwrt@owrt.
# The current target/linux/mediatek/image/filogic.mk contains a stray
# trailing backslash in the supergateway_s20m DEVICE_PACKAGES block.
# GNU make then treats the following "endef" incorrectly and aborts with:
#   filogic.mk:927: *** missing 'endef', unterminated 'define'.  Stop.
# We patch the exact known-bad line locally before defconfig/build.
hotfix_upstream_filogic_mk_parse_error() {
  local filogic_mk="target/linux/mediatek/image/filogic.mk"

  [[ -f "${filogic_mk}" ]] || return 0

  if grep -Fq "DEVICE_DTS := mt7986a-supergateway-s20m" "${filogic_mk}" && \
     grep -Fq -- "-kmod-mt7915-firmware -kmod-mt7916-firmware -kmod-mt7986-firmware -mt7986-wo-firmware \\" "${filogic_mk}"; then
    sed -i '/DEVICE_DTS := mt7986a-supergateway-s20m/,/endef/ s/-mt7986-wo-firmware \\/-mt7986-wo-firmware/' "${filogic_mk}"
    echo "Applied temporary upstream hotfix: filogic.mk supergateway_s20m endef parse issue."
  fi
}

# 在 make defconfig 之后检查关键符号是否还存在。
# 这里不强制失败，只做提醒，避免编出一版“进去之后没中文”的固件却不自知。
validate_required_config_symbols() {
  local missing=()
  local symbol
  local required_symbols=("${REQUIRED_CONFIG_SYMBOLS[@]}")

  if [[ -n "${WRT_THEME}" && "${WRT_THEME}" != "bootstrap" ]]; then
    required_symbols+=(
      "CONFIG_PACKAGE_luci-theme-${WRT_THEME}=y"
      "CONFIG_PACKAGE_luci-app-${WRT_THEME}-config=y"
    )

    if source_package_has_zh_translation "luci-app-${WRT_THEME}-config"; then
      required_symbols+=("CONFIG_PACKAGE_luci-i18n-${WRT_THEME}-config-zh-cn=y")
    fi
  fi

  for symbol in "${required_symbols[@]}"; do
    if ! grep -q "^${symbol}$" .config; then
      missing+=("${symbol}")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "WARNING: Required LuCI/i18n config symbols are missing after defconfig:"
    printf '  %s\n' "${missing[@]}"
    echo "The build will continue, but the resulting firmware may not offer Chinese in LuCI."
  fi
}

validate_daed_config_symbols() {
  local missing=()
  local symbol

  if ! general_config_package_enabled "luci-app-daed"; then
    return 0
  fi

  for symbol in "${DAED_REQUIRED_CONFIG_SYMBOLS[@]}"; do
    if ! grep -q "^${symbol}$" .config; then
      missing+=("${symbol}")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "WARNING: daed required config symbols are missing after defconfig:"
    printf '  %s\n' "${missing[@]}"
    echo "The build will continue, but luci-app-daed may fail to compile or daed may fail at runtime."
  fi
}

validate_device_profile_symbols() {
  local expected_device_symbols=()
  local symbol

  while IFS= read -r symbol; do
    [[ -n "${symbol}" ]] || continue
    expected_device_symbols+=("${symbol}")
  done < <(grep -E '^CONFIG_TARGET_.*_DEVICE_.*=y$' "${WRT_CONFIG_FILE}" || true)

  if (( ${#expected_device_symbols[@]} == 0 )); then
    return 0
  fi

  for symbol in "${expected_device_symbols[@]}"; do
    if ! grep -qxF "${symbol}" .config; then
      echo "ERROR: Device profile disappeared after defconfig: ${symbol}"
      echo "This usually means a generic target option overrode the single-device profile."
      exit 3
    fi
  done
}

# LuCI 基础中文包和默认中文设置统一在这里注入，
# 这样 GENERAL.txt 里就不用再手写这些最容易出错的基础语言项。
append_core_luci_language_packages() {
  local line

  for line in "${LANGUAGE_CORE_PACKAGES[@]}"; do
    append_config_line_if_missing "${line}"
  done
}

# 根据已启用的 LuCI 包自动推导对应的简中语言包。
# 规则：
# - luci-app-foo      -> luci-i18n-foo-zh-cn
# - luci-proto-foo    -> luci-i18n-foo-zh-cn
# 只有源码目录里真的存在 zh_Hans/zh-cn 翻译时才会启用，避免把不存在的语言包写进 .config。
append_auto_i18n_for_package() {
  local config_package="$1"
  local base_name
  local i18n_package

  if should_skip_auto_i18n_package "${config_package}"; then
    echo "Skip auto i18n for ${config_package} due to known compatibility handling."
    return
  fi

  case "${config_package}" in
    luci-app-*)
      base_name="${config_package#luci-app-}"
      ;;
    luci-proto-*)
      base_name="${config_package#luci-proto-}"
      ;;
    *)
      return
      ;;
  esac

  if ! source_package_has_zh_translation "${config_package}"; then
    return
  fi

  i18n_package="CONFIG_PACKAGE_luci-i18n-${base_name}-zh-cn=y"
  append_config_line_if_missing "${i18n_package}"
  echo "Auto-enable i18n: ${i18n_package}"
}

# 扫描 GENERAL.txt 里已经启用的 LuCI 插件与协议包，自动补齐可用的简中语言包。
append_auto_i18n_packages_to_config() {
  local line
  local package_name

  while IFS= read -r line; do
    package_name="${line#CONFIG_PACKAGE_}"
    package_name="${package_name%=y}"
    append_auto_i18n_for_package "${package_name}"
  done < <(grep -E '^CONFIG_PACKAGE_(luci-app-|luci-proto-).*=y$' "${GENERAL_CONFIG_FILE}" | sort -u)
}

# 参考 AXT1800 项目，把 LuCI 默认主题从 bootstrap 切到指定主题。
# 这样刷机后首次进入 LuCI 时就是 Aurora，不需要再手动切换。
apply_default_luci_theme() {
  local collection_makefile

  [[ -n "${WRT_THEME}" ]] || return
  [[ "${WRT_THEME}" != "bootstrap" ]] || return

  while IFS= read -r -d '' collection_makefile; do
    sed -i "s/luci-theme-bootstrap/luci-theme-${WRT_THEME}/g" "${collection_makefile}"
  done < <(find ./feeds/luci/collections/ -type f -name "Makefile" -print0 2>/dev/null)
}

# Aurora 主题和它的配置页按参考项目做法，直接由脚本写入 .config。
# 这样主题本身不需要放在 GENERAL.txt 里管理，和普通插件区分开。
append_theme_packages_to_config() {
  [[ -n "${WRT_THEME}" ]] || return
  [[ "${WRT_THEME}" != "bootstrap" ]] || return

  append_config_line_if_missing "CONFIG_PACKAGE_luci-theme-${WRT_THEME}=y"
  append_config_line_if_missing "CONFIG_PACKAGE_luci-app-${WRT_THEME}-config=y"

  if source_package_has_zh_translation "luci-app-${WRT_THEME}-config"; then
    append_config_line_if_missing "CONFIG_PACKAGE_luci-i18n-${WRT_THEME}-config-zh-cn=y"
  fi
}

# 把机型配置与通用插件配置合并为最终 .config。
# 如有额外临时配置文件，也可以通过 EXTRA_CONFIG_FILE 再附加进去。
apply_config_fragments() {
  apply_default_luci_theme
  cat "${GENERAL_CONFIG_FILE}" "${WRT_CONFIG_FILE}" > .config

  # 内核/BPF 相关配置单独放在机型 kernel fragment 里，
  # 避免把这类低频但关键的内核选项混进 GENERAL.txt。
  if [[ -f "${KERNEL_CONFIG_FILE}" ]]; then
    cat "${KERNEL_CONFIG_FILE}" >> .config
  fi

  append_core_luci_language_packages
  append_theme_packages_to_config
  append_auto_i18n_packages_to_config

  if [[ -n "${EXTRA_CONFIG_FILE:-}" && -f "${EXTRA_CONFIG_FILE}" ]]; then
    cat "${EXTRA_CONFIG_FILE}" >> .config
  fi

  make defconfig

  if [[ "${RUN_MENUCONFIG:-0}" == "1" ]]; then
    make menuconfig
  fi

  validate_device_profile_symbols
  validate_required_config_symbols
  validate_daed_config_symbols
}
