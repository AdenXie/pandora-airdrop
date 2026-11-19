#!/system/bin/sh
# Runs when the module is removed. KernelSU does that early in the next boot, before system_server is up,
# so the cleanup that needs Android services (Wi-Fi settings, PackageManager) runs in a detached job that
# waits for boot_completed. The job uses only the runtime dir and system tools, never the module dir.
MODDIR=${0%/*}
. "$MODDIR/common.sh"

job='NATIVE=$1; RUNTIME=$2; PKG=$3; BB=$4
i=0
while [ "$i" -lt 300 ]; do
 [ "$(getprop sys.boot_completed)" = 1 ] && pm path android >/dev/null 2>&1 && break
 i=$((i + 1)); sleep 2
done
for f in supervisor bridge; do
 p=$(cat "$NATIVE/$f.pid" 2>/dev/null)
 case "$p" in ""|*[!0-9]*) ;; *) tr "\0" " " < /proc/$p/cmdline 2>/dev/null | grep -qE "bridge-supervisor|XosBridge" && kill -TERM "$p" ;; esac
done
sleep 3
if [ -f "$RUNTIME/radio.sh" ] && [ -n "$BB" ]; then
 "$BB" nsenter -t 1 -m /system/bin/sh "$RUNTIME/radio.sh" restore >/dev/null 2>&1
fi
if [ ! -e "$NATIVE/saved.env" ]; then
 for m in wonder pandora_wonder_bridge pandora_mhi_fw; do [ -e /sys/module/$m ] && rmmod $m 2>/dev/null; done
fi
rm -rf "$RUNTIME" "$NATIVE"
rmdir /data/local/tmp/xos 2>/dev/null
pm uninstall "$PKG"'

if [ -n "$BB" ]; then
 "$BB" setsid /system/bin/sh -c "$job" sh "$NATIVE_DIR" "$RUNTIME_DIR" "$COMPAT_PKG" "$BB" </dev/null >/dev/null 2>&1 &
else
 /system/bin/sh -c "$job" sh "$NATIVE_DIR" "$RUNTIME_DIR" "$COMPAT_PKG" "" </dev/null >/dev/null 2>&1 &
fi
