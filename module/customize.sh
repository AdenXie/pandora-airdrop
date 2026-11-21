#!/system/bin/sh
# KernelSU installer for Xiaomi 17 / 17 Pro AirDrop. Writes nothing to any partition.
SKIPUNZIP=0
. "$MODPATH/common.sh"

# No overlay of /system or /vendor at all.
touch "$MODPATH/skip_mount"

ui_print "=========================================="
ui_print "  小米 17 系列 原生 AirDrop"
ui_print "  $(grep '^version=' "$MODPATH/module.prop" | cut -d= -f2)  不修改任何系统分区"
ui_print "=========================================="

[ -n "$BB" ] || abort "! 未找到 KernelSU 自带的 busybox"

device=$(getprop ro.product.device)
sdk=$(getprop ro.build.version.sdk)
os=$(getprop ro.mi.os.version.incremental)
kernel=$(uname -r)
ui_print "- 设备: $(getprop ro.product.marketname) ($device)"
ui_print "- 系统: HyperOS $os (SDK $sdk)"
ui_print "- 内核: $kernel"

case " $SUPPORTED_DEVICES " in
*" $device "*) ;;
*) abort "! 仅支持小米 17 / 17 Pro (pudding / pandora)，当前为 $device" ;;
esac
[ "$sdk" = "$EXPECTED_SDK" ] || abort "! 需要 Android 17 (SDK $EXPECTED_SDK)，当前为 SDK $sdk"
case "$kernel" in
"$EXPECTED_KERNEL_PREFIX"*) ;;
*)
 ui_print "! 内核不匹配，驱动只针对 6.12.69 系列内核校验过："
 ui_print "  当前 $kernel"
 abort "! 已中止，手机未做任何改动"
 ;;
esac

if [ -e "$NATIVE_DIR/saved.env" ] || [ -e /sys/class/net/xos0 ] || \
   [ -e /sys/module/qca_cld3_peach_v2/parameters/pt_activate ]; then
 abort "! AirDrop 会话正在进行，请先关闭「与Apple设备互传」再安装"
fi
if grep -q " $STOCK_AMSS " /proc/1/mountinfo; then
 abort "! 原厂 Wi-Fi 固件正被替换中，请先重启手机再安装"
fi
[ "$(sha_of "$STOCK_AMSS")" = "$STOCK_AMSS_SHA" ] || abort "! 原厂 Wi-Fi 固件版本不匹配（系统可能已更新）"
[ -r "$BUILD_ID_PATH" ] || abort "! 原厂 Wi-Fi 驱动未加载，请打开一次 Wi-Fi 后重试"
[ "$(sha_of "$BUILD_ID_PATH")" = "$STOCK_NOTE_SHA" ] || abort "! 原厂 Wi-Fi 驱动版本不匹配（系统可能已更新）"

vc=$(dumpsys package "$MISHARE_PKG" 2>/dev/null | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -n 1)
[ -n "$vc" ] || abort "! 未找到小米互传 ($MISHARE_PKG)"
if [ "$vc" != "$MISHARE_VC" ]; then
 ui_print "! 小米互传版本为 $vc，本模块在 $MISHARE_VC (5.4.1) 上测试。"
 ui_print "  AirDrop 应该可用，但 Live Photo 合成可能失效。"
fi
if [ ! -d /data/adb/modules/zygisk_lsposed ] && [ ! -d /data/adb/lspd ]; then
 ui_print "! 未检测到 LSPosed。没有兼容模块时，打开互传后会话会被中断。"
fi

if [ ! -f "$MODPATH/payload/$S26U_FW_REL" ]; then
 ui_print "- 安装包不含三星固件，正在手机上查找 amss20.bin ..."
 fw=
 for f in $S26U_FW_SEARCH; do
  if [ -f "$f" ] && [ "$(sha_of "$f")" = "$S26U_FW_SHA" ]; then fw=$f; break; fi
 done
 if [ -z "$fw" ]; then
  ui_print "! 没找到三星 S26 Ultra 的 WLAN 固件。请把 amss20.bin"
  ui_print "  （SM-S948B S948BXXS6BZK1，SHA-256 以 71fc5c2e 开头）"
  ui_print "  放到 /sdcard/Download/s26u-amss20.bin 后重新安装。"
  ui_print "  获取方法见项目 firmware/README.md。"
  abort "! 已中止，手机未做任何改动"
 fi
 ui_print "  使用 $fw"
 mkdir -p "$MODPATH/payload/firmware"
 cp "$fw" "$MODPATH/payload/$S26U_FW_REL" || abort "! 复制固件失败"
fi

ui_print "- 校验模块文件..."
(cd "$MODPATH/payload" && sha256sum -c installation.sha256 >/dev/null) || abort "! 运行文件校验失败，安装包可能已损坏"
(cd "$MODPATH/apks" && sha256sum -c APKS.sha256 >/dev/null) || abort "! APK 校验失败，安装包可能已损坏"

ui_print "- 停止正在运行的旧版守护..."
stop_bridge || abort "! 旧版守护未能停止，请重启手机后再安装"
[ "$(radio_state)" = RESTORE_FAILED ] && abort "! 上次 Wi-Fi 恢复失败，请先重启手机再安装"

ui_print "- 部署运行文件到 $RUNTIME_DIR ..."
sync_runtime "$MODPATH/payload" || abort "! 运行文件部署失败"
rm -f "$RUNTIME_DIR/state/sepolicy.boot_id"

ui_print "- 安装 LSPosed 兼容模块 ($COMPAT_PKG)..."
apk="$MODPATH/apks/Pandora-XOS-Compat.apk"
cur=$(pm path "$COMPAT_PKG" 2>/dev/null | sed -n 's/^package://p' | head -n 1)
if [ -n "$cur" ] && [ "$(sha_of "$cur")" = "$(sha_of "$apk")" ]; then
 ui_print "  已是最新版，保留现有的 LSPosed 启用状态"
 first=0
else
 [ -n "$cur" ] && first=0 || first=1
 # system_server can only read the APK from a location like /data/local/tmp under SELinux Enforcing.
 stage=/data/local/tmp/pandora-airdrop-compat.apk
 cp "$apk" "$stage" && chmod 644 "$stage"
 out=$(pm install -r "$stage" 2>&1)
 rm -f "$stage"
 case "$out" in
  *Success*) ui_print "  安装成功" ;;
  *INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
   abort "! 已装有不同签名的 $COMPAT_PKG，请先卸载它再安装本模块" ;;
  *) ui_print "  $out"; abort "! 兼容模块安装失败" ;;
 esac
 am force-stop "$MISHARE_PKG" >/dev/null 2>&1 || true
fi

set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
mlog "installed $(grep '^version=' "$MODPATH/module.prop")"

ui_print " "
while IFS= read -r line; do ui_print "$line"; done < "$MODPATH/README.txt"
ui_print " "
ui_print "=========================================="
if [ "$first" = 1 ]; then
 ui_print "✅ 安装完成。请先在 LSPosed 里启用兼容模块，然后重启手机。"
else
 ui_print "✅ 安装完成，重启手机后生效。"
fi
ui_print "=========================================="
