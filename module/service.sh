#!/system/bin/sh
# Boot-time service: safety checks, then keep the XosBridge supervisor running while the module is enabled.
# Event-driven (inotify on the module dir for disable/remove); no periodic polling, so no idle wakeups.
MODDIR=${0%/*}
. "$MODDIR/common.sh"
[ -n "$BB" ] || exit 1

BASE_DESC="小米 17 系列原生 AirDrop：iPhone 隔空投送到小米互传，Live Photo 合成动态照片。不修改系统分区。"
set_desc() {
 awk -v d="$1 $BASE_DESC" '/^description=/ { print "description=" d; next } { print }' \
  "$MODDIR/module.prop" > "$MODDIR/module.prop.tmp" && mv "$MODDIR/module.prop.tmp" "$MODDIR/module.prop"
}

i=0
while [ "$i" -lt 180 ]; do
 [ "$(getprop sys.boot_completed)" = 1 ] && pm path "$MISHARE_PKG" >/dev/null 2>&1 && break
 i=$((i + 1)); sleep 1
done

mkdir -p "$NATIVE_DIR" "$RUNTIME_DIR/state"
chmod 700 "$NATIVE_DIR"
trim_log "$MODULE_LOG"
trim_log "$RUNTIME_DIR/state/radio.log"
trim_log "$RUNTIME_DIR/state/supervisor.log"
trim_log "$NATIVE_DIR/owly-bridge.log"
mlog "boot: service start"

# Never load our driver after an OTA changed the kernel or the stock Wi-Fi driver/firmware.
case "$(uname -r)" in
"$EXPECTED_KERNEL_PREFIX"*) ;;
*)
 restore_settings_only
 mlog "kernel changed to $(uname -r); disabled"
 set_desc "[⚠ 已自动停用：内核已变更]"
 exit 0
 ;;
esac
j=0
while [ "$j" -lt 30 ] && [ ! -r "$BUILD_ID_PATH" ]; do j=$((j + 1)); sleep 1; done
if [ "$(sha_of "$BUILD_ID_PATH")" != "$STOCK_NOTE_SHA" ] || [ "$(sha_of "$STOCK_AMSS")" != "$STOCK_AMSS_SHA" ]; then
 restore_settings_only
 mlog "stock Wi-Fi driver/firmware changed; disabled"
 set_desc "[⚠ 已自动停用：原厂 Wi-Fi 驱动或固件已变更]"
 exit 0
fi

if ! sync_runtime "$MODDIR/payload"; then
 mlog "runtime sync failed"
 set_desc "[⚠ 运行文件损坏，请重新安装]"
 exit 0
fi

# A session that was open when the phone rebooted: put Wi-Fi settings back (radio.sh sees the new boot_id).
[ -e "$NATIVE_DIR/saved.env" ] && radio_restore

RUNNER=
start_runner() {
 [ -n "$RUNNER" ] && kill -0 "$RUNNER" 2>/dev/null && return 0
 (
  while :; do
   "$BB" nsenter -t 1 -m /system/bin/sh "$RUNTIME_DIR/bridge-supervisor.sh" \
    </dev/null >>"$NATIVE_DIR/owly-bridge.log" 2>&1
   echo "$(date '+%m-%d %H:%M:%S') supervisor exited rc=$?" >> "$MODULE_LOG"
   trim_log "$NATIVE_DIR/owly-bridge.log"
   sleep 5
  done
 ) &
 RUNNER=$!
 mlog "runner started ($RUNNER)"
}

stop_runner() {
 if [ -n "$RUNNER" ]; then kill -TERM "$RUNNER" 2>/dev/null; RUNNER=; fi
 stop_bridge || mlog "bridge did not stop in time"
 radio_restore
}

apply_state() {
 if [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ]; then
  stop_runner
  unload_idle || mlog "idle modules busy"
  if [ -f "$MODDIR/remove" ]; then set_desc "[🗑 将在重启后卸载]"; else set_desc "[⏸ 已停用]"; fi
  mlog "paused"
 else
  if ! radio_idle; then
   mlog "idle modules failed to load"
   set_desc "[⚠ 空闲模块加载失败，请重启]"
   return 0
  fi
  start_runner
  set_desc "[✅ 运行中]"
 fi
}

apply_state
# Block on inotify events for files created/deleted in the module dir (KSU toggles disable/remove there).
"$BB" inotifyd - "$MODDIR:nd" 2>/dev/null | while IFS="$(printf '\t')" read -r ev dir name; do
 case "$name" in disable|remove) apply_state ;; esac
done
