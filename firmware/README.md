# 三星 S26 Ultra WLAN 固件（需自备）

小米原厂 peach 固件不支持 PASSTHRU vdev，本项目会话期间临时改用三星 Galaxy S26 Ultra（SM-S948B，同为 SM8850 + FastConnect 7900/peach）的 `amss20.bin`。这份固件是三星/高通的闭源文件，**本仓库和发布的安装包都不包含它**。

| 项目 | 值 |
|---|---|
| 机型 / 地区 | SM-S948B / EUX |
| 固件版本 | S948BXXS6BZK1 |
| 文件 | vendor 分区 `firmware/peach/amss20.bin`（7,364,672 字节） |
| SHA-256 | `71fc5c2eb2df048b6c4b494564cfbef730db879a3d8b4426c31ad23b5d448860` |

## 获取

- 从你合法取得的 S948BXXS6BZK1 完整固件中，解出 `vendor` 分区里的 `firmware/peach/amss20.bin`。
- 或使用 `stream_vendor.py`：通过三星官方 FUS Smart 协议流式下载该版本的 AP 包，只解出 vendor/vendor_dlkm，不下载完整 ROM。需要 [samloader](https://github.com/martinetd/samloader) 的 smart 分支（放在脚本同级的 `samloader-smart/`）以及 `pycryptodomex`、`lz4`。脚本基于 houji-airdrop 的 firmware-acquisition 工具改写。

取得后核对 SHA-256，必须与上表完全一致。

## 安装时如何使用

把文件放到手机的 `/sdcard/Download/s26u-amss20.bin`（或 `/sdcard/Download/amss20.bin`）后再安装模块。安装器校验 SHA-256 后把它复制进模块目录，之后更新模块会自动沿用已部署的副本。

固件只在 AirDrop 会话期间以 bind mount 方式覆盖 `/vendor/firmware_mnt/image/peach/amss20.bin`，会话结束或重启后即失效，不写入任何分区。
