# owly-xosd

AWDL 协议栈来自 houji-airdrop 的 Owly（`native/owly`，MIT）与 `native/houji-runner`。本项目基于 houji-airdrop 提交 `353a076`，只改了 `houji-runner` 的两个文件，见 `pandora-owly.patch`：

- sysfs 路径从 `qca_cld3_kiwi_v2` 改为 `qca_cld3_peach_v2`。
- **对端门控**：AWDL 邻居先作为候选，只有给本机发过 TCP 单播、主动与其通过单播交互、或收发过带 `_airdrop` 的组播/单播 mDNS（含 UDP 5353）的设备才加入驱动对端表（上限 6，空闲 30 秒后可被淘汰），避免周围 Apple 设备占满驱动的 8 个槽位。`OWLY_PEER_GATE=0` 可关闭。
- 首次软件发现改发 mDNS QM 查询（避免未注册硬件对端表前对端回单播被丢），硬件槽位注册完成后再补发 QU 查询；冷却（5 秒）与操作间隔（300 ms）内命中的准入请求会进入有界等待队列自动重试。
- `max_peers` 从 8 提高到 64（`OWLY_MAX_PEERS` 可调），避免周围设备多时 owly 内部对端表反复挤出正在传输的 iPhone。
- 数据帧计入 RX 活动，用于门控的空闲判断。
- **重发 AirDrop 广播**：iPhone 打开隔空投送几秒后还没发现接收方，就会进入稀疏查询，小米互传启动时发出的两次 `_airdrop` mDNS 通告常被错过。owly 记下互传最近发出的那条组播通告，在第一次通告后的前 12 秒每秒重发一次、之后每 2 秒一次，直到收到第一个入站 TCP 连接（iPhone 的 `/Discover`）或满 30 秒（新会话重新通告时会自动重置）。只重发互传自己的报文，不伪造查询。日志里 `OWLY_T <毫秒时间戳> <事件>` 记录对端出现、硬件就绪、首次通告、每次重发和首个入站连接。

## 编译

```sh
git clone https://github.com/ha0xin/houji-airdrop && cd houji-airdrop
git checkout 353a076
find native/houji-runner/src -name '*.rs' -exec sed -i 's/\r$//' {} +   # 补丁按 LF 生成
patch -p1 < /path/to/pandora-airdrop/owly/pandora-owly.patch
cd runtime/owly-xos && ANDROID_NDK_HOME=... bash build-native.sh     # 产物 dist/owly-xosd
```

需要 rustup（目标 `aarch64-linux-android`）和 NDK r27c。`wonder-init` 直接用 houji-airdrop 提交 `100c1e0` 的 `native/wonder-init` 编译，未修改；`xos-bridge.zip` 由本仓库 `bridge/XosBridge.java` 编译。
