#!/usr/bin/env bash

# 用途：
#   初始化 Ubuntu / GitHub Actions Runner 的编译依赖环境。
# 适用场景：
#   1. GitHub Actions 的 “Install build dependencies” 步骤
#   2. 本地 Linux / WSL 手动准备编译环境
# 维护提示：
#   这里只负责调用上游官方初始化脚本，本仓库尽量不重复维护一大段 apt 依赖列表。

set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This bootstrap script must run inside Linux or WSL2."
  exit 1
fi

# 默认使用 ImmortalWrt 官方提供的 Ubuntu 初始化脚本。
bootstrap_url="${BOOTSTRAP_URL:-https://build-scripts.immortalwrt.org/init_build_environment.sh}"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required to download the official ImmortalWrt bootstrap script."
  exit 1
fi

# root 直接执行，普通用户则通过 sudo 提权执行。
if [[ "$(id -u)" -eq 0 ]]; then
  bash <(curl -fsSL "${bootstrap_url}")
  exit 0
fi

if command -v sudo >/dev/null 2>&1; then
  curl -fsSL "${bootstrap_url}" | sudo bash
  exit 0
fi

echo "Please run this script as root or install sudo first."
exit 1
