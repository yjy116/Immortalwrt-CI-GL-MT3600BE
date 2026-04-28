#!/usr/bin/env bash

# 第三方插件处理脚本
#
# 作用：
# - 读取 Config/GENERAL.txt 顶部的 @vendor 规则
# - 把对应的第三方仓库源码同步到本地 vendor 缓存
# - 再按规则拷贝到编译树里
#
# 设计目标：
# - 日常增减第三方插件时，尽量只改 GENERAL.txt
# - 脚本本身尽量不随插件增减而频繁改动
#
# 说明：
# - 官方 feed 里已有的插件不应写在这里，例如 luci-app-homeproxy
# - Aurora 主题按参考项目做法单独处理，不走 GENERAL.txt 的 @vendor 规则
# - 其它第三方插件仍然通过 GENERAL.txt 统一声明

set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG_DIR="${CONFIG_DIR:-${PROJECT_ROOT}/Config}"
GENERAL_CONFIG_FILE="${GENERAL_CONFIG_FILE:-${CONFIG_DIR}/GENERAL.txt}"
WORK_ROOT="${WORK_ROOT:-$HOME/work}"
WRT_CONFIG="${WRT_CONFIG:-MT3600BE}"
BUILD_ROOT="${BUILD_ROOT:-${WORK_ROOT}/immortalwrt-${WRT_CONFIG,,}}"
VENDOR_ROOT="${VENDOR_ROOT:-${WORK_ROOT}/immortalwrt-vendor}"
WRT_THEME="${WRT_THEME:-aurora}"

# 判断某个插件是否在 GENERAL.txt 中被显式启用。
# 只有启用的第三方插件，才会去拉源码和拷贝。
config_package_enabled() {
  local package_name="$1"
  [[ -f "${GENERAL_CONFIG_FILE}" ]] && grep -Eq "^CONFIG_PACKAGE_${package_name}=y$" "${GENERAL_CONFIG_FILE}"
}

# 判断某个插件是否没有在 GENERAL.txt 中显式启用。
# 这里用“不是 =y”作为禁用条件，方便兼容：
# - # CONFIG_PACKAGE_xxx is not set
# - 完全没写这一项
config_package_disabled() {
  local package_name="$1"
  ! config_package_enabled "${package_name}"
}

# 去掉字符串前后的空白，避免解析配置时把空格也当成内容。
trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

# 同步第三方仓库到本地缓存目录。
# 规则和主编译树类似：首次 clone，之后只在干净工作树上更新。
sync_git_repo() {
  local repo_url="$1"
  local repo_branch="$2"
  local repo_dir="$3"

  if [[ ! -d "${repo_dir}/.git" ]]; then
    git clone --single-branch --branch "${repo_branch}" "${repo_url}" "${repo_dir}"
    return
  fi

  git -C "${repo_dir}" remote set-url origin "${repo_url}"

  if ! git -C "${repo_dir}" diff --quiet --ignore-submodules HEAD -- || ! git -C "${repo_dir}" diff --cached --quiet --ignore-submodules --; then
    echo "Vendor repo is dirty: ${repo_dir}"
    echo "Please clean tracked source changes before updating."
    exit 1
  fi

  git -C "${repo_dir}" fetch origin "${repo_branch}" --depth 1
  git -C "${repo_dir}" checkout -B "${repo_branch}" "origin/${repo_branch}"
}

# 按规则把第三方源码目录复制进 buildroot。
# 复制后会删掉 .git，避免把插件仓库的 Git 元数据带进编译树。
copy_package_dir() {
  local src_dir="$1"
  local dst_dir="$2"

  if [[ ! -d "${src_dir}" ]]; then
    echo "Package directory was not found: ${src_dir}"
    exit 1
  fi

  rm -rf "${dst_dir}"
  mkdir -p "${dst_dir}"
  cp -a "${src_dir}/." "${dst_dir}/"
  rm -rf "${dst_dir}/.git"
}

# 执行特定插件需要的附加动作。
# 当前只保留 po2lmo，主要给 OpenClash 生成语言编译工具。
run_vendor_hook() {
  local repo_dir="$1"
  local hook="${2:-}"
  local openclash_po2lmo_dir
  local openclash_po2lmo_bin
  local tailscale_makefile

  case "${hook}" in
    ""|none)
      ;;
    po2lmo)
      if command -v po2lmo >/dev/null 2>&1; then
        return
      fi

      openclash_po2lmo_dir="${repo_dir}/luci-app-openclash/tools/po2lmo"
      if [[ ! -d "${openclash_po2lmo_dir}" ]]; then
        echo "OpenClash po2lmo directory was not found: ${openclash_po2lmo_dir}"
        exit 1
      fi

      make -C "${openclash_po2lmo_dir}"
      openclash_po2lmo_bin="${openclash_po2lmo_dir}/src"
      export PATH="${openclash_po2lmo_bin}:${PATH}"
      ;;
    tailscale-compat)
      # asvow/luci-app-tailscale 会接管 tailscale 的 init/config，
      # 这里按其上游 README 的建议，先从官方 tailscale 主包里删掉同名安装项，
      # 避免 package/install 阶段出现文件覆盖冲突。
      for tailscale_makefile in \
        "${BUILD_ROOT}/feeds/packages/net/tailscale/Makefile" \
        "${BUILD_ROOT}/package/feeds/packages/tailscale/Makefile"; do
        if [[ -f "${tailscale_makefile}" ]]; then
          sed -i '\|/etc/init.d/tailscale|d;\|/etc/config/tailscale|d' "${tailscale_makefile}"
          echo "Patched tailscale package for luci-app-tailscale compatibility: ${tailscale_makefile}"
        fi
      done
      ;;
    *)
      echo "Unknown vendor hook: ${hook}"
      exit 1
      ;;
  esac
}

# 解析一条 @vendor 规则里的“复制映射”。
# 一个插件可以有多个 src:dst，对应多个目录一起拷贝。
copy_vendor_specs() {
  local repo_dir="$1"
  local copy_specs="$2"
  local spec src_rel dst_rel src_dir dst_dir

  IFS=';' read -r -a specs <<< "${copy_specs}"
  for spec in "${specs[@]}"; do
    spec="$(trim_whitespace "${spec}")"
    [[ -n "${spec}" ]] || continue

    if [[ "${spec}" != *:* ]]; then
      echo "Invalid vendor copy spec: ${spec}"
      exit 1
    fi

    src_rel="$(trim_whitespace "${spec%%:*}")"
    dst_rel="$(trim_whitespace "${spec#*:}")"

    if [[ "${src_rel}" == "." ]]; then
      src_dir="${repo_dir}"
    else
      src_dir="${repo_dir}/${src_rel}"
    fi

    dst_dir="${BUILD_ROOT}/${dst_rel}"
    copy_package_dir "${src_dir}" "${dst_dir}"
  done
}

# 主题包单独处理：
# - 做法参考你给的 AXT1800 项目
# - Aurora 主题本体和 Aurora 配置页都直接按固定仓库拉取
# - 这样主题不需要再塞进 GENERAL.txt，维护上更接近参考项目
prepare_theme_packages() {
  local theme_repo_dir
  local theme_config_repo_dir

  case "${WRT_THEME}" in
    ""|bootstrap)
      return
      ;;
    aurora)
      theme_repo_dir="${VENDOR_ROOT}/luci-theme-aurora"
      theme_config_repo_dir="${VENDOR_ROOT}/luci-app-aurora-config"

      sync_git_repo "https://github.com/eamonxg/luci-theme-aurora.git" "master" "${theme_repo_dir}"
      copy_package_dir "${theme_repo_dir}" "${BUILD_ROOT}/package/luci-theme-aurora"

      sync_git_repo "https://github.com/eamonxg/luci-app-aurora-config.git" "master" "${theme_config_repo_dir}"
      copy_package_dir "${theme_config_repo_dir}" "${BUILD_ROOT}/package/luci-app-aurora-config"
      ;;
    *)
      echo "Unsupported WRT_THEME: ${WRT_THEME}"
      echo "Currently this project only prepares Aurora automatically."
      exit 1
      ;;
  esac
}

# HomeProxy 的简中翻译需要保留，否则 LuCI 里会只显示英文。
# 早期曾遇到过中文包和主包重复安装 menu.d JSON 的冲突，
# 所以这里不再删除整个 zh_Hans 目录，只在上游源码真的带了重复 menu 文件时做精确清理。
sanitize_homeproxy_i18n_conflict() {
  local duplicate_menu_file

  if ! config_package_enabled "luci-app-homeproxy"; then
    return
  fi

  for duplicate_menu_file in \
    "${BUILD_ROOT}/feeds/luci/applications/luci-app-homeproxy/po/zh_Hans/root/usr/share/luci/menu.d/luci-app-homeproxy.json" \
    "${BUILD_ROOT}/feeds/luci/applications/luci-app-homeproxy/po/zh_Hans/usr/share/luci/menu.d/luci-app-homeproxy.json" \
    "${BUILD_ROOT}/package/feeds/luci/luci-app-homeproxy/po/zh_Hans/root/usr/share/luci/menu.d/luci-app-homeproxy.json" \
    "${BUILD_ROOT}/package/feeds/luci/luci-app-homeproxy/po/zh_Hans/usr/share/luci/menu.d/luci-app-homeproxy.json"; do
    if [[ -f "${duplicate_menu_file}" ]]; then
      rm -f "${duplicate_menu_file}"
      echo "Removed duplicate HomeProxy i18n menu file: ${duplicate_menu_file}"
    fi
  done
}

# 核心入口：
# 逐行读取 GENERAL.txt，提取启用状态下的 @vendor 规则，并完成同步与拷贝。
prepare_custom_packages() {
  local line package_name repo_url repo_branch copy_specs hook repo_dir

  mkdir -p "${VENDOR_ROOT}"
  prepare_theme_packages
  sanitize_homeproxy_i18n_conflict

  while IFS= read -r line; do
    if [[ ! "${line}" =~ ^#[[:space:]]*@vendor[[:space:]]+([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)(\|(.*))?$ ]]; then
      continue
    fi

    package_name="$(trim_whitespace "${BASH_REMATCH[1]}")"
    repo_url="$(trim_whitespace "${BASH_REMATCH[2]}")"
    repo_branch="$(trim_whitespace "${BASH_REMATCH[3]}")"
    copy_specs="$(trim_whitespace "${BASH_REMATCH[4]}")"
    hook="$(trim_whitespace "${BASH_REMATCH[6]:-}")"

    if ! config_package_enabled "${package_name}"; then
      continue
    fi

    repo_dir="${VENDOR_ROOT}/${package_name}"
    sync_git_repo "${repo_url}" "${repo_branch}" "${repo_dir}"
    copy_vendor_specs "${repo_dir}" "${copy_specs}"
    run_vendor_hook "${repo_dir}" "${hook}"
  done < "${GENERAL_CONFIG_FILE}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    prepare)
      prepare_custom_packages
      ;;
    *)
      echo "Usage: $0 prepare"
      exit 1
      ;;
  esac
fi
