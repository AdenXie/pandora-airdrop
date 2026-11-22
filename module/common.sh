#!/system/bin/sh
# Shared constants and helpers for the Xiaomi 17 / 17 Pro AirDrop KSU module (sourced by customize/service/action/uninstall).
# Nothing here writes to any partition: the runtime lives in /data/local/tmp/xos, the S26U firmware is a
# bind mount made only while an AirDrop session is open, and every kernel module is insmod'ed at runtime.

NATIVE_DIR=/data/local/tmp/xos/native
RUNTIME_DIR=/data/local/tmp/xos/owly
MODULE_LOG=$NATIVE_DIR/module.log

# Xiaomi 17 Pro (pandora) and Xiaomi 17 (pudding) share the kernel, the peach WLAN firmware and the stock
# Wi-Fi driver, so one set of modules serves both (pudding support contributed in PR #1 by zytstudio).
SUPPORTED_DEVICES="pandora pudding"
EXPECTED_SDK=37
# Kernel modules are built against the 6.12.69 android16-6 GKI KMI (4k pages). Xiaomi OTAs change the build
# hash in the release string while the KMI stays the same, so only the KMI part is checked; the stock
# Wi-Fi driver/firmware hashes below still catch an OTA that really changes the Wi-Fi stack.
EXPECTED_KERNEL='6.12.69-android16-6-*-4k'
kernel_ok() {
 case "$1" in 6.12.69-android16-6-*-4k) return 0 ;; esac
 return 1
}
STOCK_AMSS=/vendor/firmware_mnt/image/peach/amss20.bin
STOCK_AMSS_SHA=8d0ac09be5489393ed23c19ace3ea9e44ceff5e29c4bb75ea3d22acf26d92e8f
STOCK_KO=/vendor_dlkm/lib/modules/qca_cld3_peach_v2.ko
BUILD_ID_PATH=/sys/module/qca_cld3_peach_v2/notes/.note.gnu.build-id
STOCK_NOTE_SHA=e2db5a4c55b3664d2aa3d5ce4dc24af67df31f58d88f4e65121fd5aa0b050ecd
# Samsung Galaxy S26 Ultra (SM-S948B, S948BXXS6BZK1) WLAN firmware. Not redistributable: users supply it.
S26U_FW_REL=firmware/s26u-amss20.bin
S26U_FW_SHA=71fc5c2eb2df048b6c4b494564cfbef730db879a3d8b4426c31ad23b5d448860
S26U_FW_SEARCH="/sdcard/Download/s26u-amss20.bin /sdcard/Download/amss20.bin /data/local/tmp/s26u-amss20.bin $RUNTIME_DIR/$S26U_FW_REL"
MISHARE_PKG=com.miui.mishare.connectivity
MISHARE_VC_TESTED="50401 50500"  # 5.4.1, 5.5.0
COMPAT_PKG=org.pandora.xoscompat

BB=""
for cand in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
 if [ -x "$cand" ]; then BB="$cand"; break; fi
done

mlog() {
 mkdir -p "$NATIVE_DIR" 2>/dev/null
 echo "$(date '+%m-%d %H:%M:%S') $*" >> "$MODULE_LOG"
}

sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# pid_from <pidfile> <cmdline substring>: print the pid only if it is alive and really is that process.
pid_from() {
 p=$(cat "$1" 2>/dev/null || true)
 case "$p" in ''|*[!0-9]*) return 1 ;; esac
 { tr '\0' ' ' < "/proc/$p/cmdline"; } 2>/dev/null | grep -q -- "$2" || return 1
 echo "$p"
}

radio_state() { cat "$NATIVE_DIR/status" 2>/dev/null || echo UNKNOWN; }

# Stop the XosBridge supervisor. On SIGTERM it stops the bridge and runs "radio.sh restore" itself (stock
# driver, stock firmware, Wi-Fi as it was), so wait for its lock to be released, up to about 60 s.
# Signal every process whose command line matches the ERE $2 (never this shell).
kill_matching() {
 /system/bin/ps -A -o PID,ARGS 2>/dev/null | while read -r pid args; do
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  [ "$pid" = "$$" ] && continue
  printf '%s\n' "$args" | grep -qE -- "$2" && kill "-$1" "$pid" 2>/dev/null
 done
 return 0
}

# Stop the supervisor and every XosBridge instance, not only the ones in the pid files: an orphaned
# XosBridge or a supervisor respawned by the service runner must not block us. TERM first (the
# supervisor's trap stops its bridge and restores Wi-Fi), KILL after about 10 s.
stop_bridge() {
 i=0
 while [ "$i" -lt 150 ]; do
  sig=TERM; [ "$i" -ge 33 ] && sig=KILL
  kill_matching "$sig" '(^|/)sh [^ ]*/bridge-supervisor[.]sh'
  kill_matching "$sig" '(^|/)app_process /system/bin XosBridge( |$)'
  # On a first install $NATIVE_DIR does not exist yet and flock cannot create the lock file there, so a
  # missing directory counts as "not locked" (fix from PR #1).
  if { [ ! -d "$NATIVE_DIR" ] || "$BB" flock -n "$NATIVE_DIR/supervisor.lock" true 2>/dev/null; } && \
     ! /system/bin/ps -A -o ARGS 2>/dev/null | grep -qE '(^|/)[a]pp_process /system/bin XosBridge( |$)'; then
   return 0
  fi
  i=$((i + 1)); sleep 0.3
 done
 return 1
}

# The previously installed module's service.sh (its runner loop restarts the supervisor every 5 s and its
# inotifyd watcher). Only the installer calls this; a reboot starts the new service.sh.
stop_old_service() {
 kill_matching TERM '/data/adb/modules/pandora_airdrop/service[.]sh'
 kill_matching TERM 'inotifyd - /data/adb/modules/pandora_airdrop( |:)'
 sleep 0.5
 return 0
}

# Restore stock Wi-Fi if a session is still recorded (no-op when already restored).
radio_restore() {
 [ -x "$RUNTIME_DIR/radio.sh" ] || [ -f "$RUNTIME_DIR/radio.sh" ] || return 0
 "$BB" nsenter -t 1 -m /system/bin/sh "$RUNTIME_DIR/radio.sh" restore >>"$MODULE_LOG" 2>&1
}

# Load the idle modules on top of stock Wi-Fi (bridge + synthetic wonder + mhi helper), so wonder_enable=1.
radio_idle() {
 j=0
 while [ "$j" -lt 30 ] && [ ! -e /sys/module/qca_cld3_peach_v2 ]; do j=$((j + 1)); sleep 1; done
 "$BB" nsenter -t 1 -m /system/bin/sh "$RUNTIME_DIR/radio.sh" idle >>"$MODULE_LOG" 2>&1
}

# Without loading anything: put back the Wi-Fi on/off setting saved by a session that a reboot cut short.
# Used when the module refuses to run (OTA changed the kernel/driver), so Wi-Fi is not left switched off.
restore_settings_only() {
 [ -f "$NATIVE_DIR/saved.env" ] || return 0
 saved_wifi=1; saved_scan=0
 . "$NATIVE_DIR/saved.env"
 setprop sys.xos.exclusive 0
 if [ "$saved_scan" = 1 ]; then cmd wifi set-scan-always-available enabled; fi
 if [ "$saved_wifi" = 1 ]; then cmd wifi set-wifi-enabled enabled; fi
 mv "$NATIVE_DIR/saved.env" "$RUNTIME_DIR/state/previous-boot.env" 2>/dev/null || rm -f "$NATIVE_DIR/saved.env"
 mlog "restored saved Wi-Fi settings only"
}

# Idle modules make /proc/sys/net/wonder/wonder_enable appear, which is what makes MIShare offer
# "与Apple设备互传". Unload them when the module is paused so the entry disappears.
unload_idle() {
 [ -e "$NATIVE_DIR/saved.env" ] && return 1
 [ -e /sys/module/qca_cld3_peach_v2/parameters/pt_activate ] && return 1
 if [ -e /sys/module/wonder ]; then rmmod wonder 2>/dev/null || return 1; fi
 if [ -e /sys/module/pandora_wonder_bridge ]; then rmmod pandora_wonder_bridge 2>/dev/null || return 1; fi
 if [ -e /sys/module/pandora_mhi_fw ]; then rmmod pandora_mhi_fw 2>/dev/null || true; fi
 return 0
}

# Copy the payload into the runtime directory when it differs (keeps state/ and logs).
sync_runtime() {
 src=$1
 if [ -f "$RUNTIME_DIR/installation.sha256" ] && cmp -s "$src/installation.sha256" "$RUNTIME_DIR/installation.sha256" && \
    (cd "$RUNTIME_DIR" && sha256sum -c installation.sha256 >/dev/null 2>&1); then
  return 0
 fi
 mkdir -p "$RUNTIME_DIR/state" "$RUNTIME_DIR/radio" "$RUNTIME_DIR/firmware" "$NATIVE_DIR" || return 1
 chmod 700 "$RUNTIME_DIR" "$RUNTIME_DIR/state" "$NATIVE_DIR"
 for f in $(awk '{print $2}' "$src/installation.sha256"); do
  cp "$src/$f" "$RUNTIME_DIR/$f.new" && mv "$RUNTIME_DIR/$f.new" "$RUNTIME_DIR/$f" || return 1
 done
 cp "$src/installation.sha256" "$RUNTIME_DIR/installation.sha256" || return 1
 chmod 700 "$RUNTIME_DIR/radio.sh" "$RUNTIME_DIR/bridge-supervisor.sh" "$RUNTIME_DIR/owly-xosd" "$RUNTIME_DIR/wonder-init"
 sync
 (cd "$RUNTIME_DIR" && sha256sum -c installation.sha256 >/dev/null)
}

# Trim a log to its last 2000 lines once it passes 512 KiB.
trim_log() {
 [ -f "$1" ] || return 0
 sz=$(wc -c < "$1" 2>/dev/null || echo 0)
 if [ "$sz" -gt 524288 ]; then tail -n 2000 "$1" > "$1.tmp" && mv "$1.tmp" "$1"; fi
}
