# 许可与第三方来源

本仓库汇集不同来源的代码，不用一个根目录许可证覆盖全部内容。文件内的 SPDX 或版权声明优先。公开本仓库不表示所有内容都取得相同许可。

## 各目录的来源与许可

| 目录 / 文件 | 来源 | 许可 |
|---|---|---|
| `driver/patches/` | 对 MiCode `vendor_qcom_opensource_wlan`（高通 qcacld-3.0 / qca-wifi-host-cmn）的修改；0001 含 houji-airdrop 驱动树的移植代码 | 沿用被修改文件的许可（高通文件为 ISC/GPL-2.0 双许可，见各文件头）；houji 驱动部分为 GPL-2.0 |
| `driver/wonder/` | houji-airdrop `driver/wonder`，加了 `wonder_enable` sysctl | GPL-2.0（SPDX） |
| `driver/bridge/`、`driver/mhi_fw/` | 本项目 | GPL-2.0-only（SPDX） |
| `owly/pandora-owly.patch` | 对 houji-airdrop `native/houji-runner`（提交 353a076）的修改 | 已获 houji-airdrop 作者许可在本仓库发布；与上游一致，未授予开源许可（见下文） |
| `runtime/radio.sh`、`runtime/bridge-supervisor.sh` | 由 houji-airdrop `runtime/owly-xos` 的同名脚本改写（适配 pandora、MHI 缓冲区重分配、对端清理、失败即停的恢复流程等） | 已获 houji-airdrop 作者许可在本仓库发布；与上游一致，未授予开源许可（见下文） |
| `compat/` | 本项目的 LSPosed 模块；其中相册分享跳转修复移植自 houji-airdrop 的 `org.houji.xoscompat` | 移植部分同上；其余为本项目代码，GPL-2.0-only |
| `compat/stubs/` | Xposed API 的编译期桩（只含接口签名，不打包进 APK） | Apache-2.0（XposedBridge API） |
| `module/` | 本项目的 KernelSU 模块脚本，结构参考 houji-airdrop 的 `runtime/owly-xos/ksu` | 本项目代码，GPL-2.0-only |
| `firmware/stream_vendor.py` | 改写自 houji-airdrop `firmware-acquisition/acquire-ap.py`，运行时调用 samloader | 已获 houji-airdrop 作者许可在本仓库发布；与上游一致，未授予开源许可；运行时调用的 samloader 为 GPL-3.0+，不随本仓库分发 |
| `firmware/get_amss20.py`、`firmware/make_recipe.py`、`firmware/recipe/` | 本项目（独立实现三星 FUS 协议，不含 samloader 代码；位置文件只有偏移和长度，不含三星数据） | 本项目代码，GPL-2.0-only |
| `tools/`、`docs/` | 本项目 | 本项目代码，GPL-2.0-only |

## 安装包中的二进制

| 文件 | 构建来源 |
|---|---|
| `qca_cld3_peach_v2.ko` | MiCode 源码 + `driver/patches/`（GPL-2.0 部分须随附源码，即本仓库） |
| `wonder.ko`、`pandora_wonder_bridge.ko`、`pandora_mhi_fw.ko` | `driver/` 下的源码（GPL-2.0） |
| `owly-xosd` | houji-airdrop 353a076 + `owly/pandora-owly.patch`；Owly 协议栈为 MIT |
| `xos-bridge.zip`、`wonder-init` | houji-airdrop 100c1e0 原样编译；`wonder-init` 为 GPL-2.0-only，XosBridge 同上，未授予开源许可 |
| `Pandora-XOS-Compat.apk` | `compat/` |

## 不随本仓库分发的闭源组件

三星 S26 Ultra WLAN 固件 `amss20.bin`、小米 ROM、原厂驱动与小米互传 APK 都不包含在本仓库或发布的安装包里。固件需用户自备，见 `firmware/README.md`。

## houji-airdrop 衍生部分

houji-airdrop 的说明写明，其自有新增文件"暂未另行授予统一开源许可"。本仓库中基于这些文件的部分：

- `runtime/radio.sh`、`runtime/bridge-supervisor.sh`
- `owly/pandora-owly.patch`
- `compat/` 中移植的相册分享跳转修复（`Hook.java` 的 `hookIntentResolver` 方法）
- `firmware/stream_vendor.py`
- 安装包里的 `xos-bridge.zip`，以及 `owly-xosd` 中 houji-runner 的部分

均已取得 houji-airdrop 作者许可在此发布。与上游保持一致，这些部分不授予开源许可。如需在本项目之外复制、修改或再分发，请先联系 houji-airdrop 作者。

## 本项目自有代码

`module/`、`compat/` 的非移植部分、`firmware/` 下除 `stream_vendor.py` 以外的脚本与位置文件、`tools/`、`docs/` 以 GPL-2.0-only 发布，与驱动部分一致，全文见根目录 [LICENSE](LICENSE)。根目录 LICENSE 只覆盖这些部分和其他标明 GPL-2.0 的文件，不覆盖上面的 houji-airdrop 衍生部分。
