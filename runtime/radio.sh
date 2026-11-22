#!/system/bin/sh
# Xiaomi 17 Pro / 17 (pandora / pudding) xos0 radio backend for native MIShare, adapted from houji-airdrop runtime/owly-xos/radio.sh.
# Runtime only: nothing is written to any partition; the Samsung S26U amss20.bin is a bind mount (gone on reboot).
# Actions: idle | enter | restore | status
#   idle   : stock Wi-Fi + pandora_wonder_bridge + wonder(synthetic) loaded, so /proc/sys/net/wonder/wonder_enable
#            exists (MIShare AirDropAvailability needs it to offer "与Apple设备互传").
#   enter  : exclusive AirDrop radio: stock driver -> our PT driver + S26U firmware + wonder + owly-xosd (xos0).
#   restore: back to stock driver + stock firmware + Wi-Fi as it was, then idle.
set -eu

R=/data/local/tmp/xos/owly
STATE=$R/state
RADIO=$R/radio
NATIVE=/data/local/tmp/xos/native
BB=""
for cand in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
 if test -x "$cand"; then BB="$cand"; break; fi
done
test -n "$BB"
W=/sys/module/qca_cld3_peach_v2
BRIDGE=pandora_wonder_bridge
REL=/sys/module/$BRIDGE/parameters/pt_release
MF=/sys/module/pandora_mhi_fw/parameters/realloc
AMSS=/vendor/firmware_mnt/image/peach/amss20.bin
STOCK=/vendor_dlkm/lib/modules/qca_cld3_peach_v2.ko
PCI=/sys/bus/pci/devices/0000:01:00.0/power/control
ORIG=8d0ac09be5489393ed23c19ace3ea9e44ceff5e29c4bb75ea3d22acf26d92e8f       # stock amss20.bin
CANDIDATE=71fc5c2eb2df048b6c4b494564cfbef730db879a3d8b4426c31ad23b5d448860  # S26U S948BXXS6BZK1 amss20.bin
CANDIDATE_SIZE=7364672
NOTE=e2db5a4c55b3664d2aa3d5ce4dc24af67df31f58d88f4e65121fd5aa0b050ecd       # stock driver build-id note
# Same GKI KMI check as module/common.sh: stock 6.12.69-android16-6-*-4k, or a locally
# rebuilt 6.12.69 kernel that still carries the -4k page-size tag (e.g. 6.12.69-4k-g...-dirty).
kernel_ok() {
 case "${1%-dirty}" in
 6.12.69-4k|6.12.69-4k-*|6.12.69-*-4k|6.12.69-*-4k-*) return 0 ;;
 esac
 return 1
}

TABLE=10074
IFACE=xos0
# S26U peach firmware marks PASSTHRU RX with metadata BIT(30) (seen meta=40000000) = houji's EZIF contract, so
# pt_rx_ezif_marked=1. pt_remote_reo=2 sets up REO for each registered remote peer: without it unicast RX from a
# peer (TCP replies) was lost while multicast/mDNS worked (2026-11-18 first MIShare test).
# Defaults = the "fast" config verified on 2026-11-19 (VHT80 2SS MCS9 SGI, A-MSDU, BA, TX A-MPDU, vendor channel
# schedule, dynamic rate; 45-53 MB/s iPhone -> pandora). Each can still be overridden from the environment.
PT_PARAMS="${PANDORA_PT_PARAMS:-pt_exclusive=1 pt_zero_serial=1 pt_rx_metadata=1 pt_rx_msdu_buf=1 pt_rx_ezif_marked=1 pt_remote_multi=1 pt_remote_assoc=0 pt_remote_ast_override=1 pt_remote_hash_override=1 pt_remote_reo=2 pt_remote_rx_window=256 pt_rate_observe=1 pt_single_ring=1 pt_sync_lmac=1 pt_vendor_chan=1 pt_dynamic_rate=1 pt_vht80=1 pt_vht80_2ss=1 pt_tx_ampdu=1 pt_rx_capacity_4224=1}"
PROFILE="${PANDORA_PROFILE:-vht80-2ss-mcs9-sgi}"
OWLY_MODE="${PANDORA_OWLY_MODE:-amsdu ack}"   # owly-xosd: single|amsdu ack|noack

test "$(id -u)" = 0
if test "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)"; then
 exec "$BB" nsenter -t 1 -m /system/bin/sh "$R/radio.sh" "$@"
fi
mkdir -p "$STATE" "$NATIVE"

bounded() { "$BB" timeout -s TERM -k 2 25 "$@"; }
check() { echo "$1  $2" | sha256sum -c - >/dev/null; }
log() { echo "$*"; echo "$(date '+%m-%d %H:%M:%S') $*" >> "$STATE/radio.log"; }

setstate() {
 echo "$1" > "$STATE/status"; echo "$1" > "$NATIVE/status"; log "RADIO_STATE=$1"
 case "$1" in
  ENTERING|XOS_READY) setprop sys.xos.exclusive 1 ;;
  STOCK_RESTORED) setprop sys.xos.exclusive 0 ;;
 esac
}

wifi_connected() { cmd wifi status 2>/dev/null | grep -q 'Wifi is connected to'; }
wait_wifi() {
 test "$(settings get global wifi_on)" = 1 || return 0
 for i in $(seq 1 30); do
  if wifi_connected; then log WIFI_CONNECTED; return 0; fi
  if test "$i" = 3 || test "$i" = 12; then cmd wifi start-scan >/dev/null 2>&1 || true; fi
  sleep 1
 done
 log WIFI_RECONNECT_TIMEOUT
 return 0
}

verify_files() {
 cd "$R"
 sha256sum -c installation.sha256 >/dev/null
 grep -qx "$CANDIDATE  firmware/s26u-amss20.bin" installation.sha256
 kernel_ok "$(uname -r)"
}

load_idle_modules() {
 # Stock driver must be running; wonder with the synthetic provider only registers a wiphy (step 1 tested).
 test -e "$W" || return 1
 test -e /sys/module/$BRIDGE || insmod "$R/$BRIDGE.ko"
 test -e /sys/module/wonder || insmod "$R/wonder.ko" synthetic_provider=1
 test -e "$MF" || insmod "$R/pandora_mhi_fw.ko"
 test "$(cat /proc/sys/net/wonder/wonder_enable 2>/dev/null)" = 1
}

stock_environment() {
 test ! -e "$NATIVE/saved.env"
 test ! -e /sys/class/net/"$IFACE"
 test ! -e /sys/class/net/wondertap0
 ! grep -q " $AMSS " /proc/1/mountinfo
 check "$ORIG" "$AMSS"
}

clean_routes() {
 for priority in 10980 10981 10982; do
  while ip -6 rule del priority "$priority" 2>/dev/null; do :; done
 done
 ip -6 route flush table "$TABLE" 2>/dev/null || true
}

routes() {
 clean_routes
 addr=$(ip -6 -o addr show dev "$IFACE" scope link 2>/dev/null | grep -vE 'tentative|dadfailed' | awk '$3=="inet6"{sub(/\/.*/, "", $4); print $4; exit}')
 case "$addr" in fe80:*) ;; *) return 1 ;; esac
 ip -6 route replace fe80::/64 dev "$IFACE" table "$TABLE"
 ip -6 route replace ff00::/8 dev "$IFACE" table "$TABLE"
 ip -6 rule add priority 10980 to fe80::/64 oif "$IFACE" uidrange 0-0 lookup "$TABLE"
 ip -6 rule add priority 10981 to ff00::/8 oif "$IFACE" uidrange 0-0 lookup "$TABLE"
 ip -6 rule add priority 10982 from "$addr/128" lookup "$TABLE"
}

runner_alive() {
 pid=$(cat "$STATE/runner.pid" 2>/dev/null || true)
 case "$pid" in ''|*[!0-9]*) return 1 ;; esac
 kill -0 "$pid" 2>/dev/null || return 1
 tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "owly-xosd $IFACE "
}

clear_pt_peers() {
 local ctl="$W/parameters/pt_remote_peer_ctl" i summary
 test -e "$ctl" || return 0
 for i in 1 2 3 4 5; do
  # Budget time for five attempts within the bridge's 120-second command timeout.
  "$BB" timeout -s TERM -k 2 20 sh -c 'echo clear > "$1"' sh "$ctl" 2>/dev/null || true
  summary=$(head -n 1 "$ctl" 2>/dev/null) || summary=unavailable
  case "$summary" in 'active=0 '*) log "pt peers cleared (try $i)"; return 0 ;; esac
  sleep 0.2
 done
 log "pt peer clear incomplete: $summary"
 return 1
}

stop_runner() {
 if runner_alive; then
  # Once the runtime starts closing, it rejects the peer clear with ESHUTDOWN.
  if ! kill -STOP "$pid" 2>/dev/null; then
   log "could not pause owly runner $pid before clearing PT peers"
   return 1
  fi
 else
  pid=
 fi
 if ! clear_pt_peers; then
  # Keep the runner and saved state available for another restore attempt.
  if test -n "$pid"; then kill -CONT "$pid" 2>/dev/null || true; fi
  return 1
 fi
 if test -n "$pid"; then
  kill -TERM "$pid" 2>/dev/null || true
  kill -CONT "$pid" 2>/dev/null || true
  for i in $(seq 1 15); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  kill -KILL "$pid" 2>/dev/null || true
  sleep 0.3
 fi
 rm -f "$STATE/runner.pid"
 for i in $(seq 1 15); do test -e "/sys/class/net/$IFACE" || break; sleep 0.2; done
 if test -e /sys/class/net/wonder0; then iw dev wonder0 del 2>/dev/null || true; fi
 clean_routes
}

restore_service() {
 if test "$(getprop "init.svc.$1")" != "$2"; then
  case "$2" in running) start "$1" ;; stopped) stop "$1" ;; *) return 1 ;; esac
 fi
 for i in $(seq 1 12); do test "$(getprop "init.svc.$1")" = "$2" && return 0; sleep 1; done
 return 1
}

restore_stock_settings() {
 echo "$saved_pci" > "$PCI" || true
 restore_service vendor.cnd "$saved_cnd" || true
 restore_service vendor.wifi_hal_legacy "$saved_hal" || true
 setprop sys.xos.exclusive 0
 if test "$saved_scan" = 1; then cmd wifi set-scan-always-available enabled; else cmd wifi set-scan-always-available disabled; fi
 if test "${saved_wifi:-1}" = 1; then cmd wifi set-wifi-enabled enabled; wait_wifi; else cmd wifi set-wifi-enabled disabled; fi
}

snapshot() {
 test ! -e "$NATIVE/saved.env"
 case "$(getprop sys.xos.exclusive)" in ''|0) ;; *) return 1 ;; esac
 stock_environment
 check "$NOTE" "$W/notes/.note.gnu.build-id"
 wifi=$(settings get global wifi_on)
 scan=$(settings get global wifi_scan_always_enabled)
 cnd=$(getprop init.svc.vendor.cnd)
 hal=$(getprop init.svc.vendor.wifi_hal_legacy)
 pci=$(cat "$PCI")
 case "$wifi" in 0|1) ;; *) return 1 ;; esac
 case "$scan" in 0|1) ;; *) scan=0 ;; esac
 umask 077
 printf 'saved_wifi=%s\nsaved_scan=%s\nsaved_cnd=%s\nsaved_hal=%s\nsaved_pci=%s\nsaved_boot=%s\n' \
  "$wifi" "$scan" "$cnd" "$hal" "$pci" "$(cat /proc/sys/kernel/random/boot_id)" > "$STATE/snapshot.tmp"
 mv "$STATE/snapshot.tmp" "$NATIVE/saved.env"
}

# The stock cnss2/mhi keep the first boot's FBC firmware buffer; the larger S26U image overflows it (kernel panic).
# Clear img_pre_alloc while the chip is powered so the next power cycle re-sizes it (once per boot).
mhi_prepare() {
 test -e "$MF" || insmod "$R/pandora_mhi_fw.ko"
 st=$(cat "$MF")
 case "$st" in pre_alloc=*) ;; *) log "mhi state unusable: $st"; return 1 ;; esac
 cap=$(echo "$st" | sed -n 's/.*fbc_capacity=\([0-9]*\).*/\1/p')
 sbl=$(echo "$st" | sed -n 's/.*sbl_size=\([0-9]*\).*/\1/p')
 need=$((CANDIDATE_SIZE - ${sbl:-0}))
 if test "${cap:-0}" -ge "$need"; then MHI_CLEARED=0; return 0; fi
 if ! ip link show wlan0 2>/dev/null | grep -q 'UP'; then
  log "FBC buffer too small and chip may be off: powering Wi-Fi up once to re-size it"
  cmd wifi set-wifi-enabled enabled
  for i in $(seq 1 30); do ip link show wlan0 2>/dev/null | grep -q 'UP' && break; sleep 0.5; done
  ip link show wlan0 2>/dev/null | grep -q 'UP' || return 1
  sleep 1
 fi
 echo 1 > "$MF"
 MHI_CLEARED=1
 log "mhi: img_pre_alloc cleared (capacity $cap < need $need)"
}

release_pt() {
 if test -e "$REL" && test -e "$W/parameters/pt_activate"; then
  for i in $(seq 1 15); do
   bounded sh -c "echo 1 > $REL" 2>/dev/null || true
   grep -qx 'armed=0 releasing=0 released=1 result=0' "$REL" && return 0
   sleep 0.2
  done
  log "pt_release failed: $(cat "$REL")"
  return 1
 fi
 return 0
}

unload_experimental() {
 if test -e /sys/module/wonder; then
  test -z "$(ls -A /sys/module/wonder/holders)" || return 1
  bounded rmmod wonder || return $?
 fi
 if test -e "$W/parameters/pt_activate"; then
  release_pt || return $?
  test "$(cat "$W/refcnt")" = 0 || return 1
  bounded rmmod qca_cld3_peach_v2 || return $?
 fi
 if test -e /sys/module/$BRIDGE; then bounded rmmod $BRIDGE || return $?; fi
}

restore() {
 if test ! -e "$NATIVE/saved.env"; then
  if test -e "$W/parameters/pt_activate"; then log "PT driver loaded without saved state"; return 1; fi
  load_idle_modules || true
  setstate STOCK_RESTORED
  return 0
 fi
 . "$NATIVE/saved.env"
 setstate RESTORING
 if test "${saved_boot:-}" != "$(cat /proc/sys/kernel/random/boot_id)"; then
  # Rebooted mid-session: everything runtime is already gone.
  clean_routes
  restore_stock_settings
  mv "$NATIVE/saved.env" "$STATE/previous-boot.env"
  load_idle_modules || true
  setstate STOCK_RESTORED
  return 0
 fi
 if ! stop_runner; then
  setstate RESTORE_FAILED
  return 1
 fi
 unload_experimental || return $?
 while grep -q " $AMSS " /proc/1/mountinfo; do umount "$AMSS" || return $?; done
 check "$ORIG" "$AMSS" || return $?
 if test ! -e "$W"; then bounded insmod "$STOCK" || return $?; fi
 check "$NOTE" "$W/notes/.note.gnu.build-id" || return $?
 restore_stock_settings
 mv "$NATIVE/saved.env" "$STATE/last-restored.env"
 load_idle_modules || log "idle modules not reloaded"
 setstate STOCK_RESTORED
}

start_xos() {
 rm -f "$STATE/runner.log"
 (
  for fd in 3 4 5 6 7 8 9; do eval "exec $fd>&-" 2>/dev/null || true; done
  exec "$BB" setsid env \
   HOUJI_OWLY_OUTGOING_VHT="${PANDORA_OWLY_OUTGOING_VHT:-2}" \
   HOUJI_OWLY_ACCEPT_ADDBA="${PANDORA_OWLY_ACCEPT_ADDBA:-2}" \
   HOUJI_OWLY_TX_ADDBA="${PANDORA_OWLY_TX_ADDBA:-1}" \
   OWLY_COALESCE_US=1000 \
   "$R/owly-xosd" "$IFACE" $OWLY_MODE </dev/null >"$STATE/runner.log" 2>&1
 ) &
 echo $! > "$STATE/runner.pid"
 ready=0
 for i in $(seq 1 300); do
  if grep -q "^OWLY_READY iface=$IFACE " "$STATE/runner.log" 2>/dev/null && \
     ip -6 -o addr show dev "$IFACE" scope link 2>/dev/null | grep -vE 'tentative|dadfailed' | grep -q 'fe80:'; then
   ready=1; break
  fi
  runner_alive
  sleep 0.05
 done
 test "$ready" = 1
 routes
 setstate XOS_READY
}

enter() {
 if test -e "$NATIVE/saved.env"; then
  if ! grep -qx RESTORE_FAILED "$STATE/status" 2>/dev/null && \
     grep -q 'phase=3 error=0 closing=0' "$W/parameters/pt_activate" 2>/dev/null && runner_alive && \
     ip -6 -o addr show dev "$IFACE" scope link 2>/dev/null | grep -vE 'tentative|dadfailed' | grep -q 'fe80:'; then
   routes; setstate XOS_READY; return 0
  fi
  log "Unhealthy existing session; restoring first"
  restore
 fi
 verify_files
 snapshot
 trap 'rc=$?; trap - EXIT; if test "$rc" != 0; then log "ENTER_FAILED=$rc"; restore || setstate RESTORE_FAILED; fi; exit "$rc"' EXIT
 setstate ENTERING
 MHI_CLEARED=0
 mhi_prepare
 cmp -s "$R/firmware/s26u-amss20.bin" "$RADIO/amss20.bin" 2>/dev/null || cp "$R/firmware/s26u-amss20.bin" "$RADIO/amss20.bin"
 chown system:system "$RADIO/amss20.bin"; chmod 440 "$RADIO/amss20.bin"; chcon u:object_r:firmware_file:s0 "$RADIO/amss20.bin"
 check "$CANDIDATE" "$RADIO/amss20.bin"
 sync

 # wonder (idle, synthetic) must be re-bound to the PT provider: drop it before the swap.
 if test -e /sys/module/wonder; then bounded rmmod wonder; fi
 cmd wifi set-scan-always-available disabled >/dev/null 2>&1 || true
 cmd wifi set-wifi-enabled disabled >/dev/null 2>&1 || true
 for i in $(seq 1 80); do cmd wifi status 2>/dev/null | grep -q 'Wifi is disabled' && break; sleep 0.1; done
 stop vendor.cnd
 stop vendor.wifi_hal_legacy
 for i in $(seq 1 240); do
  test "$(getprop init.svc.vendor.cnd):$(getprop init.svc.vendor.wifi_hal_legacy)" = stopped:stopped && test "$(cat "$W/refcnt")" = 0 && break
  if test $((i % 20)) = 0; then stop vendor.wifi_hal_legacy; fi
  sleep 0.05
 done
 test "$(cat "$W/refcnt")" = 0
 bounded rmmod qca_cld3_peach_v2
 if test "$MHI_CLEARED" = 1; then
  grep -q 'fbc_entries=0 ' "$MF" || { log "FBC buffer not freed: $(cat "$MF")"; return 1; }
 fi
 if test -e /sys/module/$BRIDGE; then bounded rmmod $BRIDGE; fi   # fresh broker per session

 mount --bind "$RADIO/amss20.bin" "$AMSS"
 check "$CANDIDATE" "$AMSS"
 insmod "$R/$BRIDGE.ko"
 echo on > "$PCI"
 # shellcheck disable=SC2086
 bounded insmod "$R/qca_cld3_peach_v2.ko" $PT_PARAMS
 activated=0
 for i in $(seq 1 100); do
  if sh -c "echo 1 > $W/parameters/pt_activate" 2>/dev/null && grep -q 'published=1' "$W/parameters/pt_activate"; then
   activated=1; break
  fi
  sleep 0.1
 done
 test "$activated" = 1
 insmod "$R/wonder.ko" synthetic_provider=1
 phy=$(iw phy | awk '$0 == "Wiphy wonder" { found=1; next } found && $1 == "wiphy" && $2 == "index:" { print $3; exit }')
 case "$phy" in ''|*[!0-9]*) return 1 ;; esac
 country=$(sed -n 's/^saved_country=//p' "$NATIVE/saved.env" 2>/dev/null); country=${country:-CN}
 bounded "$R/wonder-init" create "$phy"
 bounded "$R/wonder-init" cache "$phy" "$(cat /sys/class/net/wonder0/ifindex)" "$PROFILE" "$country" 149
 ip link set dev wonder0 mtu 8192 2>/dev/null || true
 bounded ip link set dev wonder0 up
 iw dev wonder0 info | grep -q 'channel 149 (5745 MHz)' || bounded iw dev wonder0 set channel 149 HT20
 iw dev wonder0 info | grep -q 'channel 149 (5745 MHz)'
 for i in $(seq 1 40); do grep -q 'phase=3 error=0 closing=0 handle=1 freq=5745 ' "$W/parameters/pt_activate" && break; sleep 0.05; done
 grep -q 'phase=3 error=0 closing=0 handle=1 freq=5745 ' "$W/parameters/pt_activate"
 start_xos
 trap - EXIT
}

case "${1:-status}" in
 idle) load_idle_modules && echo IDLE_READY ;;
 enter) enter ;;
 restore) restore ;;
 status)
  cat "$STATE/status" 2>/dev/null || echo UNKNOWN
  echo "wonder_enable=$(cat /proc/sys/net/wonder/wonder_enable 2>/dev/null || echo missing)"
  cat "$W/parameters/pt_activate" 2>/dev/null || true
  cmd wifi status 2>/dev/null | head -2 || true ;;
 *) exit 2 ;;
esac
