# Native AirDrop for Xiaomi 17 / 17 Pro

[中文](README.md) | English

Lets Xiaomi Share (小米互传) on the Xiaomi 17 Pro (pandora) and Xiaomi 17 (pudding) receive AirDrop directly from an iPhone. No Mac and no Xiaomi Share iOS app needed: on the iPhone, tap AirDrop as usual and pick this phone.

Inspired by [houji-airdrop](https://github.com/ha0xin/houji-airdrop), a similar project for the Xiaomi 14, and ported to the Xiaomi 17 Pro's hardware and system.

## Status

| Feature | Status |
|---|---|
| iPhone → Xiaomi receive | ✅ Works, 45–53 MB/s measured on large files |
| Live Photo | ✅ Merged into a Xiaomi motion photo automatically. Front-camera video is re-encoded to remove mirroring, the way the Xiaomi Share iOS app does it; rear-camera video is kept lossless (from Xiaomi Share 5.5.0 it merges Live Photos itself; front-camera ones are still taken over here, fixing 5.5.0's sideways and mirrored result) |
| Xiaomi → iPhone send | ✅ Works (tested with iPhone 17 Pro Max, iOS 27.3) |
| Live Photos in HEIC | ❌ Not merged; you receive the photo and the video as two files |
| First large-file send | The iPhone may show "Waiting" for 30–40 s before the transfer prompt appears. The cause is on the iPhone side and is not solved yet |

## Supported setup

Only this exact combination is supported. If anything differs, the installer aborts without changing anything:

- Xiaomi 17 Pro (`pandora`) or Xiaomi 17 (`pudding`), Android 17 (SDK 37). The 17 Pro is tested on HyperOS OS4.0.6.0 and OS4.0.8.0; the 17 was tested by the community on OS4.0.6.0 ([#1](https://github.com/AdenXie/pandora-airdrop/pull/1)). Both share the kernel, WLAN firmware and stock driver, so one set of modules serves both
- Kernel 6.12.69 android16-6 GKI (4K pages). OTAs that keep this kernel version are fine; if the stock Wi‑Fi driver or firmware changes, the installer refuses and the module disables itself
- KernelSU (tested in LKM mode) + LSPosed
- Xiaomi Share 5.4.1 or 5.5.0 (AirDrop should work on other versions; Live Photo merging may not)

## How it works

Xiaomi Share already contains the upper AirDrop layers. What it lacks is a radio that can run AWDL. This project switches Wi‑Fi into AirDrop mode only while you have "Share with Apple devices" (与Apple设备互传) open and a nearby iPhone has AirDrop open:

1. Turn off normal Wi‑Fi and unload the stock WLAN driver.
2. Swap in the Samsung S26 Ultra WLAN firmware with a bind mount (Xiaomi's stock firmware does not support PASSTHRU).
3. Load the PASSTHRU-enabled driver and wonder. owly-xosd runs AWDL on channel 149, and XosBridge provides the `xos0` interface to Xiaomi Share.
4. When the session ends (you close the page or lock the screen), the stock driver, stock firmware and your previous Wi‑Fi come back within a few seconds.

During a session, the LSPosed compat module hides from Xiaomi Share the fact that Wi‑Fi is off, so it does not end the session. It also merges Live Photos and fixes the AirDrop entry in the gallery share sheet.

**No partition is modified.** All kernel modules are loaded at runtime, the firmware swap is a temporary bind mount, and runtime files live in `/data/local/tmp/xos`. If an OTA changes the kernel or the stock driver, the module disables itself and boot is unaffected.

## Install

1. Get the Samsung S26 Ultra WLAN firmware (not provided here) and put it on the phone at `/sdcard/Download/s26u-amss20.bin`. The easiest way is to run `python firmware/get_amss20.py --push` on a computer: it downloads only a few MB from Samsung's official server, rebuilds and verifies the file, and pushes it with adb. See [firmware/README.md](firmware/README.md).
2. Install `pandora-airdrop-vX.Y.Z.zip` from the releases page in KernelSU. The installer checks the device, kernel, stock driver and firmware, and installs the LSPosed compat module for you.
3. First install only: enable "Pandora XOS 小米互传兼容" in LSPosed, keep the default scope (Xiaomi Share and the system share sheet), then reboot.

## Usage

- Open Xiaomi Share from Control Center and go to "Share with Apple devices". Once the iPhone opens AirDrop, this phone shows up within a few seconds.
- Wi‑Fi is off during a session and mobile data is used instead. It comes back a few seconds after you close the page or lock the screen.
- If Wi‑Fi does not come back: close the page and wait 10 s. If that fails, tap the module's Action button in KernelSU. If that still fails, reboot; a reboot always restores stock Wi‑Fi.
- Disabling the module in KernelSU ends any session at once and hides the entry. Uninstalling the module also uninstalls the LSPosed compat module.

## Battery

Measured results (details in [docs/TECHNICAL.md](docs/TECHNICAL.md), in Chinese):

- On standby the module's processes use 0 CPU and do not affect stock Wi‑Fi.
- With the page open but no iPhone sending, the AirDrop radio is not started.
- During a session owly uses about 0.5% of one core when idle and about 16% while transferring. Locking the screen ends the session within 2 s.
- While the page is open and the screen is on, AirDrop mode stays on (the same as Xiaomi's own design). Close the page when you are done.

## Building from source

| Directory | Contents |
|---|---|
| [driver/](driver/README.md) | WLAN driver patches, wonder, bridge, the MHI helper module, and build notes |
| [owly/](owly/README.md) | owly-xosd patch (peer gating and more) |
| `compat/` | LSPosed module source; `build.sh` needs android.jar and build-tools from the Android SDK |
| `runtime/` | Session control script `radio.sh` and the `bridge-supervisor.sh` daemon |
| `module/` | KernelSU module scripts and the packaging script |
| [firmware/](firmware/README.md) | How to get the firmware, and a download script |
| `tools/` | Helpers such as the kernel module CRC checker |

The READMEs in the subdirectories are in Chinese.

To package, put the 8 built files in one directory (file names are listed at the top of `module/package.py`) and run

```sh
python module/package.py --inputs <dir>
```

This produces `dist/pandora-airdrop-vX.Y.Z.zip` without firmware. The script compares each file's SHA-256 against the versions verified on the device and warns on a mismatch (an error with `--strict`).

## License

The root [LICENSE](LICENSE) (GPL-2.0) does not cover the whole repository:

- Driver patches, wonder, bridge, the MHI helper module, the KernelSU module scripts, this project's own part of the compat module, the tools and the docs: GPL-2.0, see [LICENSE](LICENSE).
- The runtime scripts, the owly patch, the ported part of the compat module and the firmware download script are based on houji-airdrop. They are published here with the houji-airdrop author's permission and, as upstream, no open-source license is granted for them.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) (in Chinese) for details.

## Credits

- [houji-airdrop](https://github.com/ha0xin/houji-airdrop): the wondertap/PASSTHRU driver, wonder, the Owly AWDL stack, XosBridge and the overall approach
- Xiaomi MiCode's open-source WLAN and kernel code

## Disclaimer

This project is not affiliated with Xiaomi, Apple, Samsung or Qualcomm. Replacing the wireless driver and firmware carries risk; understand how it works before deciding to use it.
