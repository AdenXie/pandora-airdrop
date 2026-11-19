#!/system/bin/sh
# KernelSU "action" button: end any AirDrop session and bring stock Wi-Fi back.
MODDIR=${0%/*}
. "$MODDIR/common.sh"

echo "当前状态: $(radio_state)"
if [ -f "$MODDIR/disable" ]; then
 echo "模块已停用。"
fi
echo "正在结束 AirDrop 会话并恢复 Wi-Fi，最多需要约 1 分钟..."
mlog "action: reset requested (state $(radio_state))"

# The supervisor restores Wi-Fi when it stops; the boot service restarts it about 5 s later.
if ! stop_bridge; then
 echo "守护进程没有按时退出。"
fi
radio_restore

state=$(radio_state)
pt=0
[ -e /sys/module/qca_cld3_peach_v2/parameters/pt_activate ] && pt=1
echo "恢复后状态: $state"
if [ "$state" = STOCK_RESTORED ] && [ "$pt" = 0 ]; then
 if [ "$(settings get global wifi_on)" = 1 ]; then
  if cmd wifi status 2>/dev/null | grep -q 'Wifi is connected to'; then
   echo "✅ Wi-Fi 已恢复并已连接。"
  else
   echo "✅ 已回到原厂 Wi-Fi，正在重新连接网络。"
  fi
 else
  echo "✅ 已回到原厂 Wi-Fi（会话前 Wi-Fi 是关着的，保持关闭）。"
 fi
 mlog "action: restored"
else
 echo "❌ 自动恢复失败。"
 echo "请直接重启手机：本模块不修改任何分区，重启后 Wi-Fi 会自动恢复正常。"
 tail -n 5 "$RUNTIME_DIR/state/radio.log" 2>/dev/null
 mlog "action: restore failed (state $state, pt=$pt)"
fi
