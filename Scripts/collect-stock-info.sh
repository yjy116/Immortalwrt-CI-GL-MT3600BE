#!/usr/bin/env bash

# 原厂/现网系统信息采集脚本
#
# 适用场景：
# - 刷机前备份原厂系统关键信息
# - 对比原厂与自编译固件的网络、分区、无线和挂载差异
# - 排查“原厂正常、自编译异常”时快速导出参考信息

set -eu

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-$PWD/stock-info-$STAMP}"

mkdir -p "${OUT_DIR}"

save_cmd() {
  local name="$1"
  shift

  # 每条命令都单独存为一个文本文件，后面查问题时更容易逐项比对。
  {
    echo "# $*"
    echo
    "$@" 2>&1
  } > "${OUT_DIR}/${name}.txt" || true
}

save_cmd board ubus call system board
save_cmd dmesg dmesg
save_cmd partitions cat /proc/mtd
save_cmd mounts mount
save_cmd block block info
save_cmd packages opkg list-installed
save_cmd wireless iwinfo
save_cmd ip_addr ip addr
save_cmd ip_route ip route
save_cmd env fw_printenv

# 关键配置文件单独拷贝一份，便于做差异比较。
for path in \
  /etc/config/network \
  /etc/config/wireless \
  /etc/config/firewall \
  /etc/config/system \
  /etc/config/dhcp \
  /etc/config/fstab
do
  if [ -f "${path}" ]; then
    cp "${path}" "${OUT_DIR}/$(basename "${path}").conf"
  fi
done

echo "Saved stock information to ${OUT_DIR}"
