# Immortalwrt-CI-GL-MT3600BE

这是一个专门给 `GL.iNet GL-MT3600BE` 使用的 GitHub Actions 自动编译项目。

当前项目默认基于：

- `VIKINGYFY/immortalwrt`
- 分支：`owrt`

当前设备信息：

- 机型：`GL.iNet GL-MT3600BE`
- DTS：`mt7987a-glinet-gl-mt3600be`
- 平台：`mediatek / filogic`

## 项目目标

这个仓库的目标不是做成“每次都要翻很多脚本才能改”的项目，而是尽量整理成：

- 日常增减插件时，优先只改 [Config/GENERAL.txt](./Config/GENERAL.txt)
- 机型本身不变时，通常不需要改 [Config/MT3600BE.txt](./Config/MT3600BE.txt)
- GitHub Actions 的逻辑由 [WRT-CORE.yml](./.github/workflows/WRT-CORE.yml) 统一管理
- 所有关键脚本和配置文件都带中文说明，后期快速回看时不容易忘

## 目录说明

- [README.md](./README.md)
  项目总说明，适合先看这一份了解整体结构。
- [Config/GENERAL.txt](./Config/GENERAL.txt)
  通用插件总表。以后新增、删除大多数插件时，优先改这里。
- [Config/MT3600BE.txt](./Config/MT3600BE.txt)
  机型绑定配置，只保留目标平台和设备选择。
- [Scripts/bootstrap-ubuntu.sh](./Scripts/bootstrap-ubuntu.sh)
  安装 Ubuntu/Runner 编译依赖。
- [Scripts/build-immortalwrt.sh](./Scripts/build-immortalwrt.sh)
  主编译入口，负责拉源码、更新 feeds、应用配置、预热缓存和完整编译。
- [Scripts/Packages.sh](./Scripts/Packages.sh)
  解析 `GENERAL.txt` 里的 `@vendor` 规则，拉取第三方插件源码。
- [Scripts/Settings.sh](./Scripts/Settings.sh)
  做环境校验、机型校验、`.config` 合并和中文相关的宽松检查。
- [Scripts/Handles.sh](./Scripts/Handles.sh)
  负责收集 artifacts 和准备 Release 元数据。
- [Scripts/collect-stock-info.sh](./Scripts/collect-stock-info.sh)
  从原厂/现网设备导出信息，方便做对照。
- [MT3600BE-TEST.yml](./.github/workflows/MT3600BE-TEST.yml)
  快速验证工作流，主要检查配置、脚本和 defconfig 是否正常。
- [MT3600BE.yml](./.github/workflows/MT3600BE.yml)
  正式编译工作流，可以自动发布 Release。
- [WRT-CORE.yml](./.github/workflows/WRT-CORE.yml)
  公共核心工作流，TEST 和正式编译都会复用它。

## 日常维护原则

### 1. 官方 feed 插件

如果插件已经在 `ImmortalWrt` 官方 `luci/packages` feed 里存在，那么通常只需要在 [GENERAL.txt](./Config/GENERAL.txt) 里增删：

- `CONFIG_PACKAGE_xxx=y`

这类插件不需要写 `@vendor` 规则。

中文语言包现在改成由 [Scripts/Settings.sh](./Scripts/Settings.sh) 自动处理：

- `luci-i18n-base-zh-cn`
- `default-settings-chn`
- 已启用 LuCI 插件对应的可用简中语言包

也就是说，日常维护时一般不再需要在 `GENERAL.txt` 里手写一长串 `luci-i18n-*`。

### 2. 第三方插件

如果插件不在官方 feed 里，就需要：

1. 在 [GENERAL.txt](./Config/GENERAL.txt) 顶部新增一条 `@vendor` 规则
2. 同时添加对应的 `CONFIG_PACKAGE_xxx=y`

当前仍保留为第三方接入的典型插件有：

- `luci-app-openclash`
- `luci-app-fancontrol`
- `luci-app-tailscale`

### 3. 机型相关配置

如果只是给 `GL-MT3600BE` 增减插件，通常不要改 [MT3600BE.txt](./Config/MT3600BE.txt)。

只有在以下场景才考虑改它：

- 切换设备型号
- 切换 target/subtarget
- 更换 DTS 机型条目

## 当前默认内置能力

当前这份 `GENERAL.txt` 已经按 `VIKINGYFY/OpenWRT-CI` 的思路补齐了插件层和一部分底层工具层，默认会编入这些常用能力：

- 代理与去广告：`homeproxy`、`openclash`、`adguardhome`
- 网络管理：`ddns`、`upnp`、`zerotier`、`tailscale`、`wireguard`
- 维护工具：`ttyd`、`autoreboot`、`nlbwmon`、`sqm`、`turboacc`
- 局域网与共享：`samba4`、`wolplus`
- 存储与磁盘：`luci-app-mounts`、`automount`、常用分区/文件系统工具
- 设备与状态：`fancontrol`、`autocore` 温度显示、`vlmcsd`
- USB / 扩展兼容：补齐了较完整的 USB 总线、USB 网卡和部分蜂窝拨号相关驱动，方便后续接扩展设备

如果后面你继续加插件，仍然优先只改 [Config/GENERAL.txt](./Config/GENERAL.txt)。

## 当前几个关键设计点

- `AdGuard Home` 已按官方 feed 方式直接编入固件，同时包含 LuCI 管理页面。
- `homeproxy` 已经回归官方 feed 管理，不再额外挂第三方源码。
- `tailscale` 已从 `luci-app-tailscale-community` 切换到 `asvow/luci-app-tailscale`。
- `luci-app-turboacc` 作为加速控制面板保留。
- 真正的 MTK 硬件加速仍依赖底层内核模块和驱动，例如 `kmod-mtk-eth-warp`、`nft offload` 等。
- 温度显示不再依赖 `luci-app-temp-status`，而是改用 `VIKINGYFY/immortalwrt@owrt` 自带的 `autocore` 机制。
- Aurora 主题按参考仓库思路接入：
  `Scripts/Packages.sh` 负责拉取 `luci-theme-aurora` 和 `luci-app-aurora-config`，
  `Scripts/Settings.sh` 负责把默认 LuCI 主题切到 `aurora`。
- `luci-app-aurora-config` 就是 Aurora 的“主题设置 / 版本管理”页面来源。
- 中文语言采用“自动补齐 + 宽松校验”策略：
  `Settings.sh` 会尽量自动补齐可用的简中语言包，
  但不会因为某个语言包缺失而在 defconfig 阶段强制阻断编译。

## 推荐使用方式

### 改插件前

优先编辑：

- [Config/GENERAL.txt](./Config/GENERAL.txt)

### 先验证

先跑：

- `MT3600BE-TEST`

### 验证通过后正式编译

再跑：

- `MT3600BE`

## 后续扩展建议

如果后面你还要维护更多不同机型仓库，最推荐继续沿用这一套结构：

- 每个机型一个独立目录/独立 GitHub 仓库
- 机型差异放在 `Config/<机型名>.txt`
- 通用插件放在 `Config/GENERAL.txt`
- 公共工作流继续复用 `WRT-CORE.yml`

这样后续加新机型时，你只需要复制这一套结构，再换设备配置即可。
