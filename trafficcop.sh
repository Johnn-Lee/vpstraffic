#!/usr/bin/env bash
# TrafficCop v3: hourly bidirectional traffic accounting + Telegram.
set -u
VERSION="3.1.0"
REPORT_TIMEZONE="Asia/Shanghai"
WORK_DIR="${TRAFFICCOP_WORK_DIR:-/root/TrafficCop}"
SCRIPT_PATH="$WORK_DIR/trafficcop.sh"; CONFIG_FILE="$WORK_DIR/config.json"; STATE_FILE="$WORK_DIR/state"
HISTORY_FILE="$WORK_DIR/hourly_traffic.tsv"; LOG_FILE="$WORK_DIR/trafficcop.log"; LOCK_FILE="$WORK_DIR/trafficcop.lock"
MARKER="# TrafficCop hourly traffic report"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log(){ mkdir -p "$WORK_DIR"; printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }
die(){ printf '%b错误：%s%b\n' "$RED" "$*" "$NC" >&2; log "ERROR: $*"; exit 1; }
root(){ [ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行。"; }
pause(){ printf '\n按回车键继续...'; read -r _; }

install_deps(){
  local miss=0 c; for c in curl jq vnstat ip flock crontab; do command -v "$c" >/dev/null 2>&1 || miss=1; done
  [ "$miss" -eq 0 ] && return
  printf '%b正在安装依赖...%b\n' "$YELLOW" "$NC"
  if command -v apt-get >/dev/null; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq vnstat iproute2 cron util-linux
  elif command -v dnf >/dev/null; then dnf install -y curl jq vnstat iproute cronie util-linux
  elif command -v yum >/dev/null; then yum install -y curl jq vnstat iproute cronie util-linux
  else die "无法识别包管理器，请手动安装 curl jq vnstat iproute2 cron util-linux。"; fi
}
start_vnstat(){
  if command -v systemctl >/dev/null; then systemctl enable --now vnstat >/dev/null 2>&1 || systemctl restart vnstat >/dev/null 2>&1 || true
  elif command -v service >/dev/null; then service vnstat start >/dev/null 2>&1 || true; fi
}
detect_iface(){ ip route show default 2>/dev/null | awk '/default/{print $5;exit}'; }
vn_total(){
  local j rx tx; j=$(vnstat -i "$1" --json 2>/dev/null) || return 1
  rx=$(printf %s "$j"|jq -er '.interfaces[0].traffic.total.rx') || return 1
  tx=$(printf %s "$j"|jq -er '.interfaces[0].traffic.total.tx') || return 1
  [[ "$rx" =~ ^[0-9]+$ && "$tx" =~ ^[0-9]+$ ]] || return 1; printf '%s %s\n' "$rx" "$tx"
}
ensure_iface(){
  local i; vn_total "$1" >/dev/null 2>&1 && return
  vnstat --add -i "$1" >/dev/null 2>&1 || true; start_vnstat
  for i in 1 2 3 4 5; do vn_total "$1" >/dev/null 2>&1 && return; sleep 1; done
  die "vnStat 无法读取网卡 $1。"
}

jget(){ jq -er "$1" "$CONFIG_FILE" 2>/dev/null; }
config_ok(){ [ -s "$CONFIG_FILE" ] && jq -e '(.bot_token|length>0)and(.chat_id|length>0)and(.interface|length>0)' "$CONFIG_FILE" >/dev/null 2>&1; }
save_config(){
  local tmp="$CONFIG_FILE.tmp.$$"; jq -n --arg bot_token "$1" --arg chat_id "$2" --arg interface "$3" --arg timezone "$4" --arg machine_name "$5" \
    '{bot_token:$bot_token,chat_id:$chat_id,interface:$interface,timezone:$timezone,machine_name:$machine_name}' >"$tmp" || die "配置写入失败。"
  chmod 600 "$tmp"; mv -f "$tmp" "$CONFIG_FILE"
}
configure(){
  local ot="" oc="" oi="" om="" token="" chat iface machine shown
  if config_ok; then ot=$(jget .bot_token); oc=$(jget .chat_id); oi=$(jget .interface); om=$(jget '.machine_name//""'); fi
  [ -n "$oi" ] || oi=$(detect_iface); printf '%bTelegram 与流量统计配置%b\n' "$CYAN" "$NC"
  if [ -n "$ot" ]; then shown="${ot:0:8}...${ot: -4}"; read -r -p "Bot Token [$shown，回车保留]: " token; token="${token:-$ot}"
  else while [ -z "$token" ]; do read -r -p 'Bot Token: ' token; done; fi
  read -r -p "Chat ID${oc:+ [$oc]}: " chat; chat="${chat:-$oc}"; [ -n "$chat" ] || die "Chat ID 不能为空。"
  read -r -p "统计网卡${oi:+ [$oi]}: " iface; iface="${iface:-$oi}"; ip link show "$iface" >/dev/null 2>&1 || die "网卡 $iface 不存在。"
  printf '推送与每日累计时区固定为：北京时间（Asia/Shanghai）\n'
  read -r -p "机器名称${om:+ [$om]}（可留空）: " machine; machine="${machine:-$om}"
  if [ -n "$oi" ] && [ "$iface" != "$oi" ] && [ -s "$STATE_FILE" ]; then mv -f "$STATE_FILE" "$STATE_FILE.interface-changed.$(date +%s)"; fi
  save_config "$token" "$chat" "$iface" "$REPORT_TIMEZONE" "$machine"; printf '%b配置已保存。%b\n' "$GREEN" "$NC"
}

write_state(){
  local tmp="$STATE_FILE.tmp.$$"; printf 'LAST_RX=%s\nLAST_TX=%s\nTOTAL_BYTES=%s\nTODAY_BYTES=%s\nSTATE_DATE=%s\nLAST_TIMESTAMP=%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$STATE_FILE"
}
load_state(){
  LAST_RX=0; LAST_TX=0; TOTAL_BYTES=0; TODAY_BYTES=0; STATE_DATE=""; LAST_TIMESTAMP=0
  [ -s "$STATE_FILE" ] || return 1; . "$STATE_FILE"
  [[ "$LAST_RX" =~ ^[0-9]+$ && "$LAST_TX" =~ ^[0-9]+$ && "$TOTAL_BYTES" =~ ^[0-9]+$ && "$TODAY_BYTES" =~ ^[0-9]+$ && "$LAST_TIMESTAMP" =~ ^[0-9]+$ ]] || die "状态文件损坏。"
}
init_state(){
  local pair rx tx now day; pair=$(vn_total "$1") || die "无法建立流量基线。"; read -r rx tx <<<"$pair"
  now=$(date +%s); day=$(TZ="$2" date +%F); write_state "$rx" "$tx" 0 0 "$day" "$now"
  [ -s "$HISTORY_FILE" ] || printf 'ended_at\tinterval\thour_bytes\ttoday_bytes\ttotal_bytes\n' >"$HISTORY_FILE"
  log "建立安装基线 interface=$1 rx=$rx tx=$tx"
}
install_cron(){
  local old; old=$(crontab -l 2>/dev/null || true)
  { printf '%s\n' "$old"|awk -v m="$MARKER" '$0==m{s=1;next}s{s=0;next}{print}'|sed '/^[[:space:]]*$/d'; printf '%s\n0 * * * * %s --run >> %s 2>&1\n' "$MARKER" "$SCRIPT_PATH" "$WORK_DIR/cron.log"; }|crontab -
}
remove_cron(){ crontab -l 2>/dev/null|awk -v m="$MARKER" '$0==m{s=1;next}s{s=0;next}{print}'|crontab - || true; }
gib(){ awk -v b="$1" 'BEGIN{printf "%.2f",b/1073741824}'; }
interval(){
  local sd ed; sd=$(TZ="$3" date -d "@$1" +%F); ed=$(TZ="$3" date -d "@$2" +%F)
  if [ "$sd" = "$ed" ]; then printf '%s %s–%s' "$sd" "$(TZ="$3" date -d "@$1" +%H:%M)" "$(TZ="$3" date -d "@$2" +%H:%M)"
  else printf '%s–%s' "$(TZ="$3" date -d "@$1" '+%F %H:%M')" "$(TZ="$3" date -d "@$2" '+%F %H:%M')"; fi
}
html_escape(){ printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
send_tg(){
  local r text; text="<pre>$(html_escape "$3")</pre>"
  r=$(curl -fsS --max-time 20 --data-urlencode "chat_id=$2" --data-urlencode "parse_mode=HTML" --data-urlencode "text=$text" "https://api.telegram.org/bot$1/sendMessage" 2>&1) || { log "Telegram 失败：$r"; return 1; }
  printf %s "$r"|jq -e '.ok==true' >/dev/null 2>&1 || { log "Telegram API 失败：$r"; return 1; }
}

run_report(){
  local iface zone token chat name display_name pair rx tx now rd td used total today report_day day_label sd ed span msg
  config_ok || die "尚未配置，请先打开交互面板。"
  iface=$(jget .interface); zone="$REPORT_TIMEZONE"; token=$(jget .bot_token); chat=$(jget .chat_id); name=$(jget '.machine_name//""')
  exec 9>"$LOCK_FILE"; flock -n 9 || { log "已有任务运行，本次跳过。"; return; }
  load_state || init_state "$iface" "$zone"; load_state
  pair=$(vn_total "$iface") || die "无法读取 $iface 的 vnStat 数据。"; read -r rx tx <<<"$pair"; now=$(date +%s)
  if [ "$rx" -ge "$LAST_RX" ]; then rd=$((rx-LAST_RX)); else rd=$rx; fi
  if [ "$tx" -ge "$LAST_TX" ]; then td=$((tx-LAST_TX)); else td=$tx; fi
  used=$((rd+td)); total=$((TOTAL_BYTES+used)); sd=$(TZ="$zone" date -d "@$LAST_TIMESTAMP" +%F); ed=$(TZ="$zone" date -d "@$now" +%F)
  if [ "$sd" != "$ed" ]; then
    report_day=$((TODAY_BYTES+used)); today=0; day_label="${sd} 全日累计"
  elif [ "$STATE_DATE" = "$ed" ]; then
    today=$((TODAY_BYTES+used)); report_day=$today; day_label="今日累计"
  else
    today=$used; report_day=$today; day_label="今日累计"
  fi
  span=$(interval "$LAST_TIMESTAMP" "$now" "$zone"); display_name="${name:-VPS}"
  printf -v msg '┌ %s · %s\n│ 本时段：%s GiB\n│ %s：%s GiB\n└ 安装后总计：%s GiB' "$display_name" "$span" "$(gib "$used")" "$day_label" "$(gib "$report_day")" "$(gib "$total")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(TZ="$zone" date -d "@$now" '+%F %T')" "$span" "$used" "$report_day" "$total" >>"$HISTORY_FILE"
  write_state "$rx" "$tx" "$total" "$today" "$ed" "$now"; log "$msg"; printf '%s\n' "$msg"
  send_tg "$token" "$chat" "$msg" && log "Telegram 推送成功。" || { printf 'Telegram 推送失败，详见 %s\n' "$LOG_FILE" >&2; return 1; }
}
test_tg(){
  config_ok || die "请先配置。"; local name msg; name=$(jget '.machine_name//""'); msg="${name:+[$name] }TrafficCop Telegram 推送测试成功。"
  send_tg "$(jget .bot_token)" "$(jget .chat_id)" "$msg" || die "测试失败，请查看日志。"; printf '%b测试消息发送成功。%b\n' "$GREEN" "$NC"
}
status(){
  config_ok || { echo '尚未配置。'; return; }; local total=0 today=0; load_state && { total=$TOTAL_BYTES; today=$TODAY_BYTES; }
  printf '机器：%s\n网卡：%s（接收 + 发送）\n推送时区：北京时间（Asia/Shanghai）\n今日累计：%s GiB\n安装后累计：%s GiB\n' "$(jget '.machine_name//""')" "$(jget .interface)" "$(gib "$today")" "$(gib "$total")"
}
history(){
  [ -s "$HISTORY_FILE" ] || { echo '暂无小时记录。'; return; }
  tail -n 25 "$HISTORY_FILE"|awk -F '\t' 'NR==1{print;next}{printf "%s\t%s\t%.2f GiB\t%.2f GiB\t%.2f GiB\n",$1,$2,$3/1073741824,$4/1073741824,$5/1073741824}'
}
install_all(){
  root; mkdir -p "$WORK_DIR"; install_deps || die "依赖安装失败。"
  if [ "$(readlink -f "${BASH_SOURCE[0]}")" != "$(readlink -f "$SCRIPT_PATH" 2>/dev/null || true)" ]; then cp -f "${BASH_SOURCE[0]}" "$SCRIPT_PATH"; fi
  chmod 700 "$SCRIPT_PATH"; start_vnstat; config_ok || configure
  local iface zone; iface=$(jget .interface); zone="$REPORT_TIMEZONE"; ensure_iface "$iface"; [ -s "$STATE_FILE" ] || init_state "$iface" "$zone"; install_cron
  printf '%b安装完成：每个整点统计并推送一次。%b\n' "$GREEN" "$NC"
}
menu(){
  root; mkdir -p "$WORK_DIR"
  while true; do clear 2>/dev/null || true; printf '%bTrafficCop v%s%b\n仅保留双向流量统计和 Telegram 小时推送。\n\n' "$CYAN" "$VERSION" "$NC"
    printf '1) 安装/修复小时任务\n2) 修改 Telegram 与统计配置\n3) 测试 Telegram\n4) 查看当前统计\n5) 查看小时记录\n6) 立即统计并推送\n7) 停用小时任务（保留数据）\n0) 退出\n\n'
    read -r -p '请选择 [0-7]: ' c
    case "$c" in 1) install_all;pause;; 2) install_deps;configure;install_all;pause;; 3) test_tg;pause;; 4) status;pause;; 5) history;pause;; 6) run_report;pause;; 7) remove_cron;echo '任务已停用，配置和数据仍保留。';pause;; 0) exit;; *) echo '无效选择。';sleep 1;; esac
  done
}
case "${1:-}" in --run)run_report;; --install)install_all;; --test-telegram)test_tg;; --status)status;; --history)history;; --help)printf '用法：%s [--install|--run|--test-telegram|--status|--history]\n' "$0";; "")menu;; *)die "未知参数：$1";; esac
