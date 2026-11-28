#!/system/bin/sh
# KernelSU installer for Xiaomi 17 / 17 Pro AirDrop. Writes nothing to any partition.
SKIPUNZIP=0
. "$MODPATH/common.sh"

# No overlay of /system or /vendor at all.
touch "$MODPATH/skip_mount"

ui_print "=========================================="
ui_print "  小米 17 系列 / K90 Pro Max 原生 AirDrop"
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

case " $SUPPORTED_DEVICES " in *" $device "*) ;; *)
 abort "! 仅支持小米 17 系列 (pandora/pudding/popsicle) 和 REDMI K90 Pro Max (myron)，当前为 $device" ;;
esac
[ "$sdk" = "$EXPECTED_SDK" ] || abort "! 需要 Android 17 (SDK $EXPECTED_SDK)，当前为 SDK $sdk"
if ! kernel_ok "$kernel"; then
 ui_print "! 内核不匹配，驱动只适用于以下内核（GKI KMI）："
 ui_print "  $EXPECTED_KERNEL"
 abort "! 已中止，手机未做任何改动"
fi

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
case " $MISHARE_VC_TESTED " in *" $vc "*) ;; *)
 ui_print "! 小米互传版本为 $vc，本模块在 5.4.1 和 5.5.0 上测试。"
 ui_print "  AirDrop 应该可用，但 Live Photo 合成可能失效。" ;;
esac
if [ ! -d /data/adb/modules/zygisk_lsposed ] && [ ! -d /data/adb/lspd ]; then
 ui_print "! 未检测到 LSPosed。没有兼容模块时，打开互传后会话会被中断。"
fi

if [ ! -f "$MODPATH/payload/$S26U_FW_REL" ]; then
 ui_print "- 安装包不含三星固件，正在手机上查找已缓存的 amss20.bin ..."
 fw=
 for f in $S26U_FW_SEARCH; do
  if [ -f "$f" ] && [ "$(sha_of "$f")" = "$S26U_FW_SHA" ]; then fw=$f; break; fi
 done
 mkdir -p "$MODPATH/payload/firmware"
 if [ -n "$fw" ]; then
  ui_print "  使用本地缓存: $fw"
  cp "$fw" "$MODPATH/payload/$S26U_FW_REL" || abort "! 复制固件失败"
 else
  ui_print "- 本地未缓存固件，正在通过手机直连三星官方服务器获取（约 5.2 MB）..."
  ui_print "  无需电脑，请保持手机联网，预计耗时 5~15 秒..."
  fetch_log="$MODPATH/payload/firmware/.fetch.log"
  if [ -f "$MODPATH/tools/fw-fetcher.zip" ] && [ -f "$MODPATH/tools/S948BXXS6BZK1.json" ]; then
   CLASSPATH="$MODPATH/tools/fw-fetcher.zip" /system/bin/app_process /system/bin FwFetcher \
    "$MODPATH/tools/S948BXXS6BZK1.json" "$MODPATH/payload/$S26U_FW_REL" >"$fetch_log" 2>&1 || true
   while IFS= read -r line; do ui_print "  $line"; done < "$fetch_log"
   rm -f "$fetch_log"
  fi
  if [ ! -f "$MODPATH/payload/$S26U_FW_REL" ] || [ "$(sha_of "$MODPATH/payload/$S26U_FW_REL")" != "$S26U_FW_SHA" ]; then
   rm -f "$MODPATH/payload/$S26U_FW_REL"
   ui_print "! 手机自动获取三星 S26U 固件失败（请检查网络/代理后重试）。"
   ui_print "  也可在电脑运行 firmware/get_amss20.py --push 手动推送到"
   ui_print "  /sdcard/Download/s26u-amss20.bin 后重新安装。"
   abort "! 已中止，手机未做任何改动"
  fi
  cp "$MODPATH/payload/$S26U_FW_REL" /sdcard/Download/s26u-amss20.bin 2>/dev/null || true
  ui_print "  已自动缓存到 /sdcard/Download/s26u-amss20.bin，下次升级免重复下载"
 fi
fi

ui_print "- 校验模块文件..."
(cd "$MODPATH/payload" && sha256sum -c installation.sha256 >/dev/null) || abort "! 运行文件校验失败，安装包可能已损坏"
(cd "$MODPATH/apks" && sha256sum -c APKS.sha256 >/dev/null) || abort "! APK 校验失败，安装包可能已损坏"

ui_print "- 停止正在运行的旧版守护..."
stop_old_service
if ! stop_bridge; then
 ui_print "! 旧版守护未能停止。仍在运行的相关进程："
 /system/bin/ps -A -o PID,STAT,ARGS 2>/dev/null | grep -E 'bridge-supervisor|XosBridge|pandora_airdrop' | grep -v grep | \
  while read -r l; do ui_print "  $l"; done
 abort "! 请重启手机，在 KernelSU 里先关闭本模块，再重新安装"
fi
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
 case "$out" in
  *Success*) ui_print "  安装成功" ;;
  *INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
   ui_print "  兼容模块签名证书已更新，正在自动卸载旧版并重新安装..."
   pm uninstall "$COMPAT_PKG" >/dev/null 2>&1 || true
   out2=$(pm install "$stage" 2>&1)
   case "$out2" in
    *Success*)
     ui_print "  重新安装成功（因签名更换，安装后需在 LSPosed 中重新勾选启用一次）"
     first=1 ;;
    *)
     rm -f "$stage"
     ui_print "  $out2"
     abort "! 兼容模块重新安装失败" ;;
   esac ;;
  *) rm -f "$stage"; ui_print "  $out"; abort "! 兼容模块安装失败" ;;
 esac
 rm -f "$stage"
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
