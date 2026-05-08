# Immortalwrt-CI-GL-MT3600BE

这是一个专门为 `GL.iNet GL-MT3600BE` 准备的 GitHub Actions 自动编译项目。

当前默认编译源：
- 上游仓库：`VIKINGYFY/immortalwrt`
- 默认分支：`owrt`

当前设备信息：
- 机型：`GL.iNet GL-MT3600BE`
- DTS：`mt7987a-glinet-gl-mt3600be`
- 平台：`mediatek / filogic`

## 项目目标

这个项目的目标不是做成“每次加插件都要翻很多脚本”的结构，而是尽量整理成：

- 日常增删大多数插件时，优先只改 [Config/GENERAL.txt](./Config/GENERAL.txt)
- 设备本身不变时，通常不需要改 [Config/MT3600BE.txt](./Config/MT3600BE.txt)
- GitHub Actions 核心逻辑统一收敛到 [WRT-CORE.yml](./.github/workflows/WRT-CORE.yml)
- 关键脚本和配置尽量保留中文注释，后续自己维护时更容易快速回看

## 目录说明

- [README.md](./README.md)  
  项目总说明，建议先看这一份了解整体结构。
- [Config/GENERAL.txt](./Config/GENERAL.txt)  
  通用插件与功能总表。以后大多数插件增删，优先改这里。
- [Config/MT3600BE.txt](./Config/MT3600BE.txt)  
  机型绑定配置，只保留目标平台和设备选择。
- [Config/MT3600BE.kernel.txt](./Config/MT3600BE.kernel.txt)  
  单独维护和机型相关的内核 fragment，当前主要用于 `daed` 的 BPF / BTF 相关内核项。
- [Scripts/bootstrap-ubuntu.sh](./Scripts/bootstrap-ubuntu.sh)  
  安装 GitHub Runner / Ubuntu 编译依赖。
- [Scripts/build-immortalwrt.sh](./Scripts/build-immortalwrt.sh)  
  主编译入口，负责拉源码、更新 feeds、应用配置、缓存预热和完整编译。
- [Scripts/Packages.sh](./Scripts/Packages.sh)  
  解析 `GENERAL.txt` 里的 `@vendor` 规则，拉取第三方插件源码，并执行少量必要兼容修复。
- [Scripts/Settings.sh](./Scripts/Settings.sh)  
  负责 `.config` 合并、环境校验、默认设置、中文包补齐和宽松校验。
- [Scripts/Handles.sh](./Scripts/Handles.sh)  
  负责收集 artifacts、整理发布文件和 Release 元数据。
- [Scripts/collect-stock-info.sh](./Scripts/collect-stock-info.sh)  
  用于对比原厂系统信息，方便做交叉核对。
- [MT3600BE-TEST.yml](./.github/workflows/MT3600BE-TEST.yml)  
  快速验证工作流，主要检查配置、脚本和 `defconfig` 是否正常。
- [MT3600BE.yml](./.github/workflows/MT3600BE.yml)  
  正式编译工作流，可自动发布 Release。
- [Auto-Build.yml](./.github/workflows/Auto-Build.yml)  
  定时自动编译工作流，用来兜底日常手动忘跑的情况。
- [WRT-CORE.yml](./.github/workflows/WRT-CORE.yml)  
  公共核心工作流，测试和正式编译都会复用它。

## 上传到 GitHub 后首次运行注意事项

- 先到仓库 `Settings -> Actions -> General`，确认工作流权限允许写入 `contents`
- 第一次建议先跑 `MT3600BE-TEST`
- `MT3600BE-TEST` 通过后，再跑正式 `MT3600BE`
- 如果正式编译成功但 Release 上传失败，优先检查仓库里是否已经有同名 Release 资源

## 日常维护原则

### 1. 官方 feed 插件

如果插件已经在 `ImmortalWrt` 官方 `luci / packages` feed 里存在，通常只需要在 [GENERAL.txt](./Config/GENERAL.txt) 里增加：

- `CONFIG_PACKAGE_xxx=y`

这类插件一般不需要写 `@vendor` 规则。

中文语言包已经改成由 [Scripts/Settings.sh](./Scripts/Settings.sh) 自动补齐：

- `luci-i18n-base-zh-cn`
- `default-settings-chn`
- 已启用 LuCI 插件对应的可用简体中文语言包

也就是说，日常维护时一般不需要再在 `GENERAL.txt` 里手写一大串 `luci-i18n-*`。

### 2. 第三方插件

如果插件不在官方 feed 里，就需要：

1. 在 [GENERAL.txt](./Config/GENERAL.txt) 顶部新增一条 `@vendor` 规则
2. 同时增加对应的 `CONFIG_PACKAGE_xxx=y`

当前仍作为第三方接入的典型插件有：

- `luci-app-openclash`
- `luci-app-fancontrol`
- `luci-app-tailscale`
- `luci-app-iperf3`
- `luci-app-easytier`

`luci-app-easytier` 使用 EasyTier 官方 OpenWrt 仓库接入，菜单位置为 `VPN -> EasyTier`。
当前配置同时启用了 `easytier` 核心程序，因此刷机后无需再手动上传核心二进制即可直接使用。

### 3. 机型相关配置

如果只是继续给 `GL-MT3600BE` 增减插件，通常不要改 [MT3600BE.txt](./Config/MT3600BE.txt)。

只有在以下场景才考虑改它：

- 切换设备型号
- 切换 `target / subtarget`
- 更换 DTS 设备条目

## 当前默认内置能力

当前这份配置已经整理出比较稳定的一套常用能力：

- 代理与去广告：`homeproxy`、`openclash`、`adguardhome`
- 组网与远程接入：`tailscale`、`zerotier`、`wireguard`、`easytier`
- 网络管理：`ddns`、`upnp`、`sqm`、`nlbwmon`
- 系统维护：`ttyd`、`autoreboot`、`turboacc`
- 局域网与共享：`samba4`、`wolplus`
- 存储与磁盘：`mounts`、`automount`、常用分区与文件系统工具
- 设备状态：`autocore` 温度显示、`fancontrol`、`vlmcsd`
- 测速：`iperf3`、`luci-app-iperf3`
- USB / 扩展兼容：补齐了一套较完整的 USB 总线、USB 网卡和常用存储驱动

如果后面继续加插件，仍然优先只改 [Config/GENERAL.txt](./Config/GENERAL.txt)。

## daed 相关说明

这是当前项目里最值得单独记录的一块，因为它和普通 LuCI 插件不太一样。

### 1. 为什么 `daed` 不能只靠 `GENERAL.txt`

`daed` 不只是一个普通插件，它依赖：

- eBPF / BTF 相关内核能力
- LLVM BPF toolchain
- `dwarves`
- 若干内核调试信息选项

所以它除了在 [GENERAL.txt](./Config/GENERAL.txt) 里启用：

- `CONFIG_PACKAGE_daed=y`
- `CONFIG_PACKAGE_daed-geoip=y`
- `CONFIG_PACKAGE_daed-geosite=y`
- `CONFIG_PACKAGE_luci-app-daed=y`

之外，还需要在 [MT3600BE.kernel.txt](./Config/MT3600BE.kernel.txt) 里额外补齐 `daed` 需要的内核配置。

### 2. 为什么单独保留 `MT3600BE.kernel.txt`

这样做的原因有两个：

- 避免把大量内核选项直接塞进 `GENERAL.txt`，导致插件配置和内核配置混在一起
- 后续内核选项变化时，可以更清楚地只在一个地方维护 `daed` 相关 fragment

### 3. 当前 `daed` 来源是什么

当前项目已经回归上游自带 `daed`，不再引入第三方 `QiuSimons/luci-app-daed`。

也就是说现在使用的是当前编译源默认 feeds 里的：

- `immortalwrt/packages` 提供的 `daed`、`daed-geoip`、`daed-geosite`
- `immortalwrt/luci` 提供的 `luci-app-daed`

这样做的好处是：

- 结构更简单，不需要额外第三方源码同步规则
- 后续跟随上游更新时更自然
- 少掉一层 `Packages.sh` 兼容补丁，维护成本更低

### 4. 为什么还保留 `MT3600BE.kernel.txt`

即使已经回归上游自带 `daed`，也不建议把 `daed` 相关内核项重新塞回 `GENERAL.txt`。

原因很简单：

- `GENERAL.txt` 适合放普通插件开关
- `daed` 这类依赖 eBPF / BTF / LLVM toolchain 的功能，更适合单独放在内核 fragment 里
- 这样后续 Linux / Kconfig 变化时，排查范围会更清晰

另外要特别注意一件事：

- GitHub Actions / CI 编译本身不能回答交互式 Kconfig 问题
- 但当前 MT3600BE 这条 `mediatek / filogic` 线已经在 [MT3600BE.kernel.txt](./Config/MT3600BE.kernel.txt) 里明确写了 `CONFIG_KERNEL_ARM64_BRBE=y`
- 这意味着对当前项目来说，`ARM64_BRBE` 不是“没人回答的新题”，而是“已经提前给了答案”

所以当前项目**不需要**照搬某些 `qualcommax` 项目里那种“强制关闭 `ARM64_BRBE`”的修复。
只有在将来真的看到：

- `ARM64_BRBE [Y/n/?] (NEW)` 交互卡死
- 或者 `defconfig` 后这个符号被异常丢掉

才需要重新评估是否要给 `mediatek` 单独加类似修复。

### 5. 如果后面 `daed` 又编译失败，优先看哪里

优先按下面顺序排查：

1. 看 `package/daed` 是否在 feeds 中正常存在
2. 看 `luci-app-daed` 是否在 feeds 中正常存在
3. 看 `MT3600BE.kernel.txt` 里的 BPF / BTF 相关项是否仍然存在
4. 看当前上游分支是否调整了 `daed` 的依赖或内核要求
5. 再考虑是不是上游 `immortalwrt/packages` 或 `immortalwrt/luci` 本身发生了结构变化

一句话总结：

`daed` 在这个项目里已经回归为“上游自带、但仍需要额外内核能力”的插件，后续如果它再出问题，优先检查 [MT3600BE.kernel.txt](./Config/MT3600BE.kernel.txt) 和上游 feeds 状态，而不是先怀疑第三方同步脚本。

## 当前几个关键设计点

- `AdGuard Home` 按官方 feed 方式直接编入固件，并保留 LuCI 管理页
- `homeproxy` 使用官方 feed，不再额外挂第三方主包源
- `tailscale` 已切换为 `asvow/luci-app-tailscale`
- `luci-app-turboacc` 保留作为加速控制面板
- MTK 硬件加速仍依赖底层内核模块，例如 `kmod-mtk-eth-warp`、`kmod-nft-offload`
- 温度显示不再依赖 `luci-app-temp-status`，而是使用 `autocore`
- Aurora 主题由 `Packages.sh` 和 `Settings.sh` 自动处理，不需要手动反复改主题包配置
- 中文语言采用“自动补齐 + 宽松校验”策略：尽量补齐，但不会因为单个语言包缺失就阻断整个编译

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

## 定时自动编译

项目已经单独提供了 `Auto-Build` 工作流。

如果你想临时屏蔽定时运行，有两种简单办法：

- 到 GitHub Actions 页面手动 `Disable workflow`
- 或者直接把 [Auto-Build.yml](./.github/workflows/Auto-Build.yml) 里的 `schedule` 注释掉后提交

当前定时策略建议按北京时间理解，避免按 UTC 误判触发时间。

## 后续扩展建议

如果后面你还要维护更多不同机型仓库，建议继续沿用这套结构：

- 每个机型一个独立目录 / 独立 GitHub 仓库
- 机型差异放在 `Config/<机型名>.txt`
- 通用插件放在 `Config/GENERAL.txt`
- 机型特殊内核项放在 `Config/<机型名>.kernel.txt`
- 公共工作流继续复用 `WRT-CORE.yml`

这样后续要扩展到更多设备时，迁移成本会低很多。
## @vendor 规则与 hook 说明

`Config/GENERAL.txt` 里的第三方插件声明使用统一的 `@vendor` 规则，格式如下：

```txt
# @vendor <config-package>|<repo-url>|<branch>|<src-rel>:<dst-rel>[;<src-rel>:<dst-rel>...]|<hook>
```

字段含义如下：

- `config-package`：对应的 `CONFIG_PACKAGE_*` 包名，用来判断这个第三方插件是否需要参与编译
- `repo-url`：第三方插件源码仓库地址
- `branch`：需要拉取的分支
- `src-rel:dst-rel`：把仓库中的相对路径复制到编译树中的目标路径
- `hook`：可选的后处理动作名称；留空或写 `none` 表示只同步源码，不做额外修正

当前项目里常见的 hook 作用如下：

- `po2lmo`：为部分第三方 LuCI 插件补齐语言文件编译流程
- `tailscale-compat`：修正第三方 `luci-app-tailscale` 与当前编译源之间的兼容问题
- `mini-diskmanager-menu`：仅调整 `luci-app-mini-diskmanager` 的菜单位置，把它从“服务”移动到“系统”

需要新增第三方插件时，建议优先按下面顺序处理：

1. 先确认上游官方 feed 是否已经自带该插件
2. 只有上游没有时，再在 `GENERAL.txt` 里增加 `@vendor` 规则
3. 如果第三方插件只是菜单位置、语言编译、路径结构这类小问题，再通过 hook 做最小修正
4. 不要直接改插件主体源码，尽量把兼容逻辑收敛到 `Scripts/Packages.sh`

这样做的好处是：

- 结构清晰，后期迁移到其它机型时更容易复用
- 第三方改动集中，排查问题时不容易漏
- 能尽量跟随上游，减少无意义的本地分叉
