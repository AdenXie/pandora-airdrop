# 小米 17 系列 / REDMI K90 Pro Max 原生 AirDrop

中文 | [English](README.en.md)

让小米 17 系列（`pandora` / `pudding` / `popsicle`）与 REDMI K90 Pro Max（`myron`）的小米互传直接与 iPhone / iPad / Mac 原生双向隔空投送。不需要 Mac、不需要小米互传 iOS 版；Apple 端照常点「隔空投送」即可收发。

灵感来源于 [houji-airdrop](https://github.com/ha0xin/houji-airdrop)（小米 14 的同类项目）移植到小米 17 Pro 的硬件与系统上。

## 当前状态

| 功能 | 状态 |
|---|---|
| iPhone → 小米 接收 | ✅ 可用，大文件实测 45–53 MB/s |
| Live Photo | ✅ 自动合成为小米动态照片。前置镜头视频按小米互传 iOS 版的做法转码去镜像；后置无损（互传 5.5.0 起由互传自己合成，前置仍由本模块接管，修正 5.5.0 的转向和镜像问题） |
| 小米 → iPhone 发送 | ✅ 可用（iPhone 17 Pro Max，iOS 27.3 实测） |
| HEIC 格式的 Live Photo | ❌ 不合成，收到照片和视频两个文件 |
| 大文件首次发送 | iPhone 可能显示"等待中"30–40 秒才弹出接收，原因在 iPhone 端，尚未解决 |

## 适用范围

只支持以下组合，不符合时安装器会直接中止，不做任何改动：

- 小米 17 Pro（`pandora`）、小米 17（`pudding`）、小米 17 Pro Max（`popsicle`）或 REDMI K90 Pro Max（`myron`），Android 17（SDK 37）。17 Pro 已在 HyperOS OS4.0.6.0 和 OS4.0.8.0 上测试；17 由社区在 OS4.0.6.0 上实测（[#1](https://github.com/AdenXie/pandora-airdrop/pull/1)）；同平台机型共享内核、WLAN 固件与原厂驱动，共用同一套模块
- 内核 6.12.69 android16-6 GKI（4K 页），原厂或自编译内核均可（如 `6.12.69-4k-g…`）。OTA 只要不换内核版本即可；原厂 Wi‑Fi 驱动或固件变了会拒绝安装、自动停用
- KernelSU（已在 LKM 模式下测试）+ LSPosed
- 小米互传 5.4.1 或 5.5.0（其他版本 AirDrop 应可用，Live Photo 合成可能失效）

## 原理

小米互传本身已经包含 AirDrop 的上层代码，缺的是能跑 AWDL 的无线电。本项目只在你打开「与Apple设备互传」、且附近 iPhone 打开隔空投送时，临时把 Wi‑Fi 切换成 AirDrop 模式：

1. 关闭普通 Wi‑Fi，卸载原厂 WLAN 驱动；
2. 以 bind mount 方式换上三星 S26 Ultra 的 WLAN 固件（小米原厂固件不支持 PASSTHRU）；
3. 加载带 PASSTHRU 的驱动和 wonder，由 owly-xosd 在 149 信道上跑 AWDL，并通过 XosBridge 把 `xos0` 网口提供给小米互传；
4. 会话结束（关闭界面或锁屏）后，几秒内恢复原厂驱动、原厂固件和原来的 Wi‑Fi。

LSPosed 兼容模块在会话期间对小米互传隐藏 Wi‑Fi 被关闭的事实，避免它中断会话；同时负责 Live Photo 合成和相册分享跳转修复。

**不修改任何分区**：所有内核模块都是运行时加载，固件替换是临时 bind mount，运行文件在 `/data/local/tmp/xos`。系统 OTA 改变内核或原厂驱动后，模块会自动停用，不影响开机。

## 安装

1. 保持手机联网，直接在 KernelSU 中安装发布页的 `pandora-airdrop-vX.Y.Z.zip`：
   - 安装包**不含三星闭源固件**；若手机 `/sdcard/Download/s26u-amss20.bin` 尚未缓存固件，安装器会通过内置的零依赖 Java 拉取器（`firmware/android/FwFetcher.java`）直连三星官方服务器下载约 5.2 MB 切片，在本地还原并校验 SHA-256 后自动缓存到 `/sdcard/Download/s26u-amss20.bin`。
   - 若手机网络访问三星服务器较慢，也可在电脑运行 `python firmware/get_amss20.py --push` 手动推送到手机后再安装。详见 [firmware/README.md](firmware/README.md)。
2. 安装器会校验机型、内核、原厂驱动和固件，并自动安装 LSPosed 兼容模块。
3. 首次安装（或升级提示证书更新时）：在 LSPosed 中启用「Pandora XOS 小米互传兼容」，作用域保持默认（小米互传、系统分享），然后重启。

## 使用

- 打开控制中心的小米互传，进入「与Apple设备互传」。iPhone 打开隔空投送后，几秒内就能看到这台手机。
- 会话期间 Wi‑Fi 暂时关闭，改用移动数据；关闭界面或锁屏后几秒自动恢复。
- 掉 Wi‑Fi 时：先关闭界面等 10 秒；仍不行就在 KernelSU 里点本模块的「操作」按钮；再不行就重启手机，重启后一定恢复原厂 Wi‑Fi。
- 在 KernelSU 里关闭模块会立即结束会话并隐藏入口；卸载模块会一并卸载 LSPosed 兼容模块。

## 续航

实测（详见 [docs/TECHNICAL.md](docs/TECHNICAL.md)）：

- 待机时模块进程 CPU 占用为 0，不影响原厂 Wi‑Fi。
- 只开界面、附近没有 iPhone 投送时，不会开启 AirDrop 无线电。
- 会话期间不传输时 owly 约占单核 0.5%，传输中约 16%；锁屏后 2 秒内结束会话。
- 界面开着且亮屏时会一直保持 AirDrop 模式（与小米原生设计一致），传完随手关掉界面即可。

## 从源码构建

| 目录 | 内容 |
|---|---|
| [driver/](driver/README.md) | WLAN 驱动补丁、wonder、bridge、MHI 辅助模块及编译要点 |
| [owly/](owly/README.md) | owly-xosd 补丁（对端门控与发现修复等） |
| `compat/` | LSPosed 模块源码，`build.sh` 需要 Android SDK 的 android.jar 与 build-tools |
| `bridge/` | 双锁分离版 `XosBridge` 源码，`build.sh` 需要 android.jar 与 d8 |
| `runtime/` | 会话控制脚本 `radio.sh` 与守护 `bridge-supervisor.sh` |
| `module/` | KernelSU 模块脚本与打包脚本 |
| [firmware/](firmware/README.md) | 固件获取说明、电脑端脚本与手机端 `FwFetcher` |
| `tools/` | 内核模块 CRC 核对等辅助工具 |

打包：把编译好的 9 个文件放进一个目录（文件名见 `module/package.py` 开头），然后运行

```sh
python module/package.py --inputs <目录>
```

得到不含固件的 `dist/pandora-airdrop-vX.Y.Z.zip`。脚本会把每个文件的 SHA-256 与实机验证过的版本对比，不同则给出警告（`--strict` 时报错）。

## 许可

根目录的 [LICENSE](LICENSE)（GPL-2.0）不覆盖整个仓库，各部分许可如下：

- 驱动补丁、wonder、bridge、MHI 辅助模块，以及 KernelSU 模块脚本、兼容模块的自有部分、辅助工具和文档：GPL-2.0，见 [LICENSE](LICENSE)。
- 基于 houji-airdrop 的运行脚本、owly 补丁、兼容模块中的移植部分和固件下载脚本：已取得 houji-airdrop 作者许可在此发布，与上游一致，不授予开源许可。

详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 致谢

- [houji-airdrop](https://github.com/ha0xin/houji-airdrop)：wondertap/PASSTHRU 驱动、wonder、Owly AWDL 协议栈、XosBridge 与整体方案
- 小米 MiCode 开源的 WLAN 与内核源码

## 免责声明

本项目与小米、苹果、三星、高通无关。替换无线驱动与固件存在风险，请在了解原理后自行决定是否使用。
