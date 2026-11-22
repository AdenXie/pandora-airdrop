# 技术说明

移植过程中的关键问题和结论，供想在其他机型上做类似工作的人参考。

## 1. 硬件与软件基础

- 小米 17 Pro：SM8850（canoe），WLAN 芯片 peach_v2（FastConnect 7900），GKI 内核 6.12.69（小米 OGKI，源码提交未公开）。
- 原厂驱动残留了 PASSTHRU 相关字符串，但没有可用实现；原厂 cnss2 已导出 `cnss_set_vendor_wonder_priv_data`。
- 小米互传 5.4.1 已包含完整的 AirDrop 上层（AWDL 网口接入、mDNS、HTTP `/Discover` `/Ask` `/Upload`），只要满足以下条件就会显示「与Apple设备互传」：国行 ROM、`/proc/sys/net/wonder/wonder_enable` 为 1、`IDomesticXOsComm/default` 服务存在。
- 小米 18 Pro 系列的内核（6.18）和 WLAN 芯片（fig）都不同，它的驱动和固件无法直接用于 17 Pro。

## 2. 驱动

- 基于 MiCode 公开的 `popsicle-w-oss` WLAN 源码，以 houji-airdrop 的驱动树三方合并移植 wondertap/PASSTHRU。
- 符号 CRC：必须设置 `KBUILD_GENDWARFKSYMS_STABLE=1`（Kleaf 默认开启），否则导出符号 CRC 对不上。手机 vendor 的 cfg80211/mac80211 开了 `CONFIG_NL80211_TESTMODE`，ops 结构体多出 0x10 字节，vendor 模块必须同样定义。
- 运行时更换为更大的固件会内核崩溃：cnss2 复用首次开机时按原厂固件大小分配的 FBC 缓冲区，`mhi_firmware_copy` 越界。`pandora_mhi_fw.ko` 在芯片上电时清除 `img_pre_alloc`，让下一次上电按新固件重新分配。

## 3. 固件

- 小米原厂 peach 固件没有 PASSTHRU vdev 类型。三星 S26 Ultra 的 peach 固件有，且签名链与小米相同，可以直接加载。
- 三星固件给 PASSTHRU 接收帧打的是 metadata BIT(30) 标记，与 houji 的 EZIF 约定一致（`pt_rx_ezif_marked=1`）。
- 必须给每个已注册的远端对端建立 REO 队列（`pt_remote_reo=2`），否则对端发来的单播帧（TCP 回包）会丢，只有组播/mDNS 能收到。

## 4. 数据帧发不出去

AWDL action 帧能上空口，但单播数据帧每帧重传约 16 次、对方不回 ACK。依次排除了 A-MSDU、TX bank、AST override、sw_retry、ILP/IMPS 低功耗、单信道调度等因素，最终找到两点：

- `pt_vendor_chan=1`：按三星和一加 wondertap 的顺序初始化信道，启动前先做硬件模式准备，并以 11be 模式请求信道。
- `pt_dynamic_rate=1`：由固件自动选速，而不是固定速率。

两者同时启用后单播数据正常收到 ACK。之后打开 VHT80、双流、A-MPDU 与 A-MSDU，实测接收 45–53 MB/s。

## 5. 小米互传的会话管理

- Android 17 上小米互传的 SELinux 域是 `platform_app_36`，需要额外放行它查找 XOS 服务。
- 小米原生方案在会话期间保持 STA 连接（退到 2.4G），本方案要独占芯片，必须关闭 Wi‑Fi。小米互传收到 `WIFI_STATE_CHANGED` 会立即停止 AirDrop，所以兼容模块在会话期间对它伪装 Wi‑Fi 状态，并丢弃这条广播（通过动态识别监听者，而不是写死混淆后的类名）。
- 小米互传只在「与Apple设备互传」页面打开时进入接收模式，并且要等 BLE 检测到 iPhone 打开隔空投送才申请 XOS。离开页面后，若 15 秒内没有传输就释放 XOS；页面在前台时不释放。

## 6. 多台 Apple 设备

- 驱动最多 8 个远端对端槽位。周围 Apple 设备多时，owly 会把发现的每台设备都加进驱动，槽位占满后真正要传文件的 iPhone 加不进来。owly 补丁增加了门控：只接纳给本机发过 TCP 单播、或发过 `_airdrop` 查询的设备。
- 驱动在同一 MAC 删除后立即重新添加时，DP 层会对正在拆除的旧对端操作，引发固件断言和 SSR，而且 SSR 后驱动无法重新初始化，只能重启。补丁 0007 让冲突时立即停止向该对端发送，删除重试区分"提交失败"和"确认超时"，同一 MAC 删除后 2 秒内拒绝重新添加，AUTH 状态更新在映射锁下复核。`radio.sh` 在停止 owly 前先冻结它并清空对端，清空失败时不再继续关闭无线电。

## 6.5 发现速度

从打开「与Apple设备互传」到 iPhone 列表出现小米，分三段：

- 无线电切换约 3.4 s（`radio.sh enter`）：卸载原厂驱动约 0.7 s，加载 PASSTHRU 驱动和固件约 0.85 s，激活约 0.55 s，wonder 设到 149 信道约 0.6 s，owly 约 0.2 s，其余约 0.5 s。加上互传自身开销，约 4.3 s 后 XOS 就绪。
- 小米互传 5.5.0 按官方「STA 与 AWDL 并发」设计，启动前会断开连在 5 GHz 的 Wi‑Fi 并等待最多 2 s，超时就整个重来，有时要等下一次 BLE 检测。本方案本来就关 Wi‑Fi，兼容模块让 `WifiConflictManager` 的检查直接通过，省掉 2–10 s，状态栏也不再 Wi‑Fi/5G 来回切换。
- iPhone 端：AWDL 在小米就绪后几乎立刻同步，但 iPhone 打开隔空投送一段时间没发现接收方后，要在小米首次通告后 4.5–9.5 s 才接受通告，期间会错过互传启动时的两次通告。owly 重发通告后，在 iPhone 先等 5–15 s 的情况下 9 轮全部在 10–17 s 内发现（之前 5 轮有 3 轮超过 30 s 仍未发现），多数是重发后几十毫秒内 iPhone 就发起连接。iPhone 和小米几乎同时打开时约 6 s。

尝试过的反例：在 owly 里伪造「对端查询」去催互传应答（在应答上线后补问、新对端出现后多次补问），实测更差，已放弃。

## 7. Live Photo

- iPhone 发来的是一张 JPEG 和一个 MOV，两者用 Apple 的配对 UUID 关联。兼容模块在小米互传提交文件之前，把它们合成为 Android Motion Photo 1.0（XMP 中的 `MotionPhoto`、`Container:Directory`，MP4 附在 JPEG 尾部），小米相册可识别和播放。
- MOV 重封装为 MP4：保留视频和音频轨，去掉 Apple 的 metadata 轨，重写 chunk 偏移。封面时间取自 Apple `still-image-time` 轨道（需要解析编辑列表的空编辑）。
- 前置镜头视频的显示矩阵含镜像，小米相册播放时会忽略镜像。参照小米互传 iOS 版的做法：封面保留 EXIF 方向，视频用 MediaCodec + OpenGL 按逆矩阵重新编码成无变换的画面；后置镜头视频只有旋转，原样保留。

## 8. 续航

测量时手机在充电，无法读电池电流，用 CPU 时间、线程唤醒次数和 Wi‑Fi 中断频率作为指标：

| 场景 | 结果 |
|---|---|
| 待机 10 分钟 | 模块常驻进程 CPU 为 0，唤醒 1 次 |
| 停用与启用模块各 5 分钟对比 | Wi‑Fi 中断频率无可测出的差异 |
| 会话中，未传输 | owly 约占单核 0.5%，整机 CPU 增加不到 2% |
| 传输中（约 50 MB/s） | owly 约占单核 16% |
| 锁屏 | 约 2 秒内结束会话，约 6 秒后 Wi‑Fi 重连 |

模块的守护进程都是事件驱动（binder、inotify、wait），没有轮询。

## 9. 尚未解决

- 大文件首次发送时 iPhone 会等待 30–40 秒。抓包显示 iPhone 处于 AWDL 省电的稀疏信道序列，保活 ping 无效，原因仍在排查。
- 固件断言后 SSR 重新初始化失败（-16），目前只能重启恢复。补丁 0007 消除了已知的触发路径。
- 8 个槽位全部占满的压力测试尚未在新驱动上复测。
