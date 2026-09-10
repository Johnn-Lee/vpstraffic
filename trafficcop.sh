#!/usr/bin/env bash
# TrafficCop v4: hourly bidirectional traffic accounting + Telegram photo pushes.
set -uo pipefail
VERSION="4.1.0"
REPORT_TIMEZONE="Asia/Shanghai"
WORK_DIR="${TRAFFICCOP_WORK_DIR:-/root/TrafficCop}"
SCRIPT_PATH="$WORK_DIR/trafficcop.sh"; CONFIG_FILE="$WORK_DIR/config.json"; STATE_FILE="$WORK_DIR/state"
HISTORY_FILE="$WORK_DIR/hourly_traffic.tsv"; LOCK_FILE="$WORK_DIR/trafficcop.lock"
HISTORY_HEADER=$'ended_at\tinterval\thour_bytes\ttoday_bytes\ttotal_bytes\trx_bytes\ttx_bytes'
BIN_DIR="$WORK_DIR/bin"; RESVG_BIN_FILE="$BIN_DIR/resvg"; LOCAL_FONT="$WORK_DIR/fonts/DejaVuSans.ttf"
SVG_FILE="$WORK_DIR/.card.svg"; PNG_FILE="$WORK_DIR/.card.png"
RESVG_URL="https://github.com/linebender/resvg/releases/download/v0.48.1/resvg-linux-x86_64.tar.gz"
DEJAVU_URL="https://cdn.jsdelivr.net/npm/dejavu-fonts-ttf@2.37.3/ttf"
MARKER="# TrafficCop hourly traffic report"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >&2; }
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
  for ((i=0; i<5; i++)); do vn_total "$1" >/dev/null 2>&1 && return; sleep 1; done
  die "vnStat 无法读取网卡 $1。"
}

jget(){ jq -er "$1" "$CONFIG_FILE" 2>/dev/null; }
config_ok(){ [ -s "$CONFIG_FILE" ] && jq -e '(.bot_token|length>0)and(.chat_id|length>0)and(.interface|length>0)' "$CONFIG_FILE" >/dev/null 2>&1; }
# 旧配置兼容：daily_summary / push_hours 缺失时按旧版行为迁移（每日总结开 + 全天 1-23 时推送）
get_daily_setting(){
  local r; r=$(jq -r 'if (.daily_summary|type)=="boolean" then (.daily_summary|tostring) else "" end' "$CONFIG_FILE" 2>/dev/null)
  [ "$r" = "false" ] && { printf 'false'; return; }
  printf 'true'
}
get_push_hours_json(){
  local r; r=$(jq -c '.push_hours?|select(type=="array")|map(select(type=="number" and .>=1 and .<=23 and ((.|floor)==.)))|sort|unique' "$CONFIG_FILE" 2>/dev/null)
  [ -n "$r" ] && { printf '%s' "$r"; return; }
  printf '[%s]' "$(seq -s, 1 23)"
}
push_fields_missing(){ ! jq -e 'has("daily_summary") and has("push_hours")' "$CONFIG_FILE" >/dev/null 2>&1; }
save_config(){
  local tmp="$CONFIG_FILE.tmp.$$"; jq -n --arg bot_token "$1" --arg chat_id "$2" --arg interface "$3" --arg timezone "$4" --arg machine_name "$5" \
    --argjson daily_summary "$6" --argjson push_hours "$7" \
    '{bot_token:$bot_token,chat_id:$chat_id,interface:$interface,timezone:$timezone,machine_name:$machine_name,daily_summary:$daily_summary,push_hours:$push_hours}' >"$tmp" || die "配置写入失败。"
  chmod 600 "$tmp"; mv -f "$tmp" "$CONFIG_FILE"
}
ask_push_settings(){
  # $1 当前 daily（true/false），$2 当前推送小时列表（空格分隔，可为空）
  local ans hint input ok t v sorted
  if [ "$1" = "true" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  read -r -p "是否开启每日总结？$hint: " ans || die "输入已结束。"
  case "$ans" in [yY]|[yY][eE][sS]) DAILY_NEW=true;; "") DAILY_NEW="$1";; *) DAILY_NEW=false;; esac
  while true; do
    read -r -p "请输入每天需要推送的小时（1-23，多个小时用空格隔开）${2:+ [$2]}: " input || die "输入已结束。"
    if [ -z "$input" ]; then
      if [ -n "$2" ]; then break; else printf '%b输入不能为空，请重新输入。%b\n' "$RED" "$NC"; continue; fi
    fi
    ok=1
    for t in $input; do
      if ! [[ "$t" =~ ^[0-9]+$ ]]; then printf '%b无效输入：%s（仅允许 1-23 的整数，空格分隔）%b\n' "$RED" "$t" "$NC"; ok=0; break; fi
      v=$((10#$t))
      if [ "$v" -lt 1 ] || [ "$v" -gt 23 ]; then printf '%b无效输入：%s（仅允许 1-23 的整数，0 由每日总结独立控制）%b\n' "$RED" "$t" "$NC"; ok=0; break; fi
    done
    [ "$ok" -eq 1 ] || continue
    sorted=$(for t in $input; do printf '%s\n' "$((10#$t))"; done|sort -nu|paste -sd' ' -)
    break
  done
  PUSH_LIST="${sorted:-$2}"
  PUSH_JSON="[$(printf '%s\n' $PUSH_LIST|paste -sd, -)]"
}
configure(){
  local ot="" oc="" oi="" om="" od="true" op="" token="" chat iface machine shown
  if config_ok; then ot=$(jget .bot_token); oc=$(jget .chat_id); oi=$(jget .interface); om=$(jget '.machine_name//""'); od=$(get_daily_setting); op=$(get_push_hours_json|jq -r 'join(" ")'); fi
  [ -n "$oi" ] || oi=$(detect_iface); printf '%bTelegram 与流量统计配置%b\n' "$CYAN" "$NC"
  if [ -n "$ot" ]; then shown="${ot:0:8}...${ot: -4}"; read -r -p "Bot Token [$shown，回车保留]: " token; token="${token:-$ot}"
  else while [ -z "$token" ]; do read -r -p 'Bot Token: ' token; done; fi
  read -r -p "Chat ID${oc:+ [$oc]}: " chat; chat="${chat:-$oc}"; [ -n "$chat" ] || die "Chat ID 不能为空。"
  read -r -p "统计网卡${oi:+ [$oi]}: " iface; iface="${iface:-$oi}"; ip link show "$iface" >/dev/null 2>&1 || die "网卡 $iface 不存在。"
  printf '推送与每日累计时区固定为：北京时间（Asia/Shanghai）\n'
  read -r -p "机器名称${om:+ [$om]}（可留空）: " machine; machine="${machine:-$om}"
  if [ -n "$oi" ] && [ "$iface" != "$oi" ] && [ -s "$STATE_FILE" ]; then mv -f "$STATE_FILE" "$STATE_FILE.interface-changed.$(date +%s)"; fi
  ask_push_settings "$od" "$op"
  save_config "$token" "$chat" "$iface" "$REPORT_TIMEZONE" "$machine" "$DAILY_NEW" "$PUSH_JSON"; printf '%b配置已保存。%b\n' "$GREEN" "$NC"
}
configure_push(){
  # 旧配置升级：仅补充每日总结与推送时间，不触碰其它字段
  local od op token chat iface tz machine
  printf '%b检测到旧版配置，补充推送时间设置（回车保留旧版每小时推送行为）%b\n' "$YELLOW" "$NC"
  od=$(get_daily_setting); op=$(get_push_hours_json|jq -r 'join(" ")')
  token=$(jget .bot_token); chat=$(jget .chat_id); iface=$(jget .interface); tz=$(jget '.timezone//""'); machine=$(jget '.machine_name//""')
  [ -n "$tz" ] || tz="$REPORT_TIMEZONE"
  ask_push_settings "$od" "$op"
  save_config "$token" "$chat" "$iface" "$tz" "$machine" "$DAILY_NEW" "$PUSH_JSON"; printf '%b配置已更新。%b\n' "$GREEN" "$NC"
}

write_state(){
  local tmp="$STATE_FILE.tmp.$$"; printf 'LAST_RX=%s\nLAST_TX=%s\nTOTAL_BYTES=%s\nTODAY_BYTES=%s\nSTATE_DATE=%s\nLAST_TIMESTAMP=%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >"$tmp" || die "状态写入失败。"
  chmod 600 "$tmp" && mv -f "$tmp" "$STATE_FILE" || die "状态保存失败。"
}
load_state(){
  LAST_RX=0; LAST_TX=0; TOTAL_BYTES=0; TODAY_BYTES=0; STATE_DATE=""; LAST_TIMESTAMP=0
  [ -s "$STATE_FILE" ] || return 1
  # 旧版 KEY=value 状态按数据读取，不执行文件中的 shell 内容。
  local key value seen="|"
  while IFS='=' read -r key value; do
    [[ "$seen" != *"|$key|"* ]] || die "状态字段重复。"
    case "$key" in
      LAST_RX|LAST_TX|TOTAL_BYTES|TODAY_BYTES|LAST_TIMESTAMP)
        [[ "$value" =~ ^[0-9]+$ ]] || die "状态文件损坏。"; printf -v "$key" '%s' "$value";;
      STATE_DATE) [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "状态日期损坏。"; STATE_DATE="$value";;
      *) die "状态文件包含未知字段。";;
    esac
    seen+="$key|"
  done <"$STATE_FILE"
  for key in LAST_RX LAST_TX TOTAL_BYTES TODAY_BYTES STATE_DATE LAST_TIMESTAMP; do
    [[ "$seen" == *"|$key|"* ]] || die "状态文件不完整。"
  done
}
ensure_history(){
  # 原五列数值不变；旧记录未知的 RX/TX 留空，新记录补充两列以支持区间汇总。
  local header tmp="$HISTORY_FILE.tmp.$$"
  if [ ! -s "$HISTORY_FILE" ]; then
    printf '%s\n' "$HISTORY_HEADER" >"$HISTORY_FILE" || die "无法创建小时记录。"
  else
    IFS= read -r header <"$HISTORY_FILE"
    if [ "$header" = $'ended_at\tinterval\thour_bytes\ttoday_bytes\ttotal_bytes' ]; then
      { printf '%s\n' "$HISTORY_HEADER"; tail -n +2 "$HISTORY_FILE" | awk '{printf "%s\t\t\n",$0}'; } >"$tmp" || die "历史数据迁移失败。"
      chmod 600 "$tmp" && mv -f "$tmp" "$HISTORY_FILE" || die "历史数据保存失败。"
    elif [ "$header" != "$HISTORY_HEADER" ]; then
      die "无法识别 hourly_traffic.tsv 表头，已停止以保护历史数据。"
    fi
  fi
  chmod 600 "$HISTORY_FILE"
}
init_state(){
  if [ -s "$HISTORY_FILE" ] && [ "$(wc -l <"$HISTORY_FILE")" -gt 1 ]; then
    die "存在历史记录但缺少 state；请同时恢复 state，避免累计值归零。"
  fi
  local pair rx tx now day; pair=$(vn_total "$1") || die "无法建立流量基线。"; read -r rx tx <<<"$pair"
  now=$(date +%s); day=$(TZ="$2" date +%F); write_state "$rx" "$tx" 0 0 "$day" "$now"
  ensure_history
  log "建立安装基线 interface=$1 rx=$rx tx=$tx"
}
install_cron(){
  local old; old=$(crontab -l 2>/dev/null || true)
  { printf '%s\n' "$old"|awk -v m="$MARKER" '$0==m{s=1;next}s{s=0;next}{print}'|sed '/^[[:space:]]*$/d'; printf '%s\n0 * * * * "%s" --run >/dev/null 2>&1\n' "$MARKER" "$SCRIPT_PATH"; }|crontab - || die "定时任务安装失败。"
}
remove_cron(){ crontab -l 2>/dev/null|awk -v m="$MARKER" '$0==m{s=1;next}s{s=0;next}{print}'|crontab - || true; }
gib(){ awk -v b="$1" 'BEGIN{printf "%.2f",b/1073741824}'; }
interval(){
  local sd ed; sd=$(TZ="$3" date -d "@$1" +%F); ed=$(TZ="$3" date -d "@$2" +%F)
  if [ "$sd" = "$ed" ]; then printf '%s %s–%s' "$sd" "$(TZ="$3" date -d "@$1" +%H:%M)" "$(TZ="$3" date -d "@$2" +%H:%M)"
  else printf '%s–%s' "$(TZ="$3" date -d "@$1" '+%F %H:%M')" "$(TZ="$3" date -d "@$2" '+%F %H:%M')"; fi
}

push_window(){
  # 当日首段从零点开始，其余从上一个配置时点开始，与上次发送成功与否无关。
  local now="$1" day hour previous start end result first first_epoch
  day=$(TZ="$REPORT_TIMEZONE" date -d "@$now" +%F)
  hour=$((10#$(TZ="$REPORT_TIMEZONE" date -d "@$now" +%H)))
  previous=$(printf '%s' "$2" | jq -r --argjson h "$hour" '[.[]|select(.<$h)]|max//0')
  printf -v start '%s %02d:00' "$day" "$previous"
  end=$(TZ="$REPORT_TIMEZONE" date -d "@$now" '+%F %H:%M')
  # 按分钟比较：08:00:01 的整点记录属于结束于 08:00 的上一段。
  result=$(awk -F '\t' -v start="$start" -v end="$end" '
    NR>1 && substr($1,1,16)>start && substr($1,1,16)<=end {
      if (!count++) first=substr($2,1,16)
      used+=$3
      if ($6 ~ /^[0-9]+$/ && $7 ~ /^[0-9]+$/) {rx+=$6; tx+=$7} else unknown=1
    }
    END {printf "%.0f %.0f %.0f %d %s\n",used,rx,tx,unknown,first}
  ' "$HISTORY_FILE") || die "无法读取推送区间历史。"
  read -r PUSH_USED PUSH_RX PUSH_TX PUSH_UNKNOWN first <<<"$result"
  # 首次部分小时或任务中断时，显示实际记录起点；兼容旧记录的 19.00 格式。
  if [ -n "$first" ]; then
    first="${first//./:}"
    first_epoch=$(TZ="$REPORT_TIMEZONE" date -d "$first" +%s) || die "无法识别历史区间起点。"
    start="$first_epoch"
  else
    start=$(TZ="$REPORT_TIMEZONE" date -d "$start" +%s)
  fi
  PUSH_SPAN=$(interval "$start" "$now" "$REPORT_TIMEZONE")
}

# ---------- 图片渲染（Monet 风格 SVG → PNG → Telegram sendPhoto） ----------
find_renderer(){
  RESVG_BIN=""; RSVG_BIN=""
  if [ -x "$RESVG_BIN_FILE" ] && "$RESVG_BIN_FILE" --version >/dev/null 2>&1; then RESVG_BIN="$RESVG_BIN_FILE"
  elif command -v resvg >/dev/null 2>&1 && resvg --version >/dev/null 2>&1; then RESVG_BIN="$(command -v resvg)"; fi
  command -v rsvg-convert >/dev/null 2>&1 && RSVG_BIN="$(command -v rsvg-convert)"
  [ -n "$RESVG_BIN" ] || [ -n "$RSVG_BIN" ]
}
system_font_found(){
  find /usr/share/fonts /usr/local/share/fonts -type f \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' \) -print -quit 2>/dev/null|grep -q .
}
pkg_install(){
  if command -v apt-get >/dev/null; then apt-get update >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  elif command -v dnf >/dev/null; then dnf install -y "$@"
  elif command -v yum >/dev/null; then yum install -y "$@"
  else return 1; fi
}
install_render_dep(){
  printf '%b正在配置图片渲染组件...%b\n' "$YELLOW" "$NC"
  if ! find_renderer; then
    if [ "$(uname -m)" = "x86_64" ]; then
      mkdir -p "$BIN_DIR"; printf '正在下载 resvg 静态渲染器（约 2 MB，无额外依赖）...\n'
      if curl -fsSL --max-time 90 "$RESVG_URL" -o "$BIN_DIR/resvg.tar.gz" 2>/dev/null && tar -xzf "$BIN_DIR/resvg.tar.gz" -C "$BIN_DIR" 2>/dev/null \
        && chmod 755 "$RESVG_BIN_FILE" && "$RESVG_BIN_FILE" --version >/dev/null 2>&1; then
        printf '%bresvg 渲染器安装完成。%b\n' "$GREEN" "$NC"
      else rm -f "$BIN_DIR/resvg" "$BIN_DIR/resvg.tar.gz" 2>/dev/null; fi
    fi
    if ! find_renderer; then
      printf '尝试通过包管理器安装 rsvg-convert...\n'
      if command -v apt-get >/dev/null; then pkg_install librsvg2-bin
      else pkg_install librsvg2-tools; fi || true
    fi
  fi
  if ! system_font_found && [ ! -s "$LOCAL_FONT" ]; then
    printf '正在安装轻量字体（DejaVu）...\n'
    if command -v apt-get >/dev/null; then pkg_install fonts-dejavu-core
    else pkg_install dejavu-sans-fonts; fi || true
    if ! system_font_found; then
      mkdir -p "$WORK_DIR/fonts"
      if curl -fsSL --max-time 60 "$DEJAVU_URL/DejaVuSans.ttf" -o "$LOCAL_FONT" 2>/dev/null \
        && curl -fsSL --max-time 60 "$DEJAVU_URL/DejaVuSans-Bold.ttf" -o "$WORK_DIR/fonts/DejaVuSans-Bold.ttf" 2>/dev/null; then
        printf '%b字体下载完成。%b\n' "$GREEN" "$NC"
      else rm -f "$LOCAL_FONT" "$WORK_DIR/fonts/DejaVuSans-Bold.ttf" 2>/dev/null; fi
    fi
  fi
  if find_renderer; then
    system_font_found || [ -s "$LOCAL_FONT" ] || { printf '%b警告：未找到系统字体，图片文字可能无法显示。%b\n' "$YELLOW" "$NC"; log "WARN: 未找到字体文件"; }
    return 0
  fi
  printf '%b警告：未安装 SVG 渲染器，图片推送暂不可用（流量统计不受影响，可重新安装修复）。%b\n' "$YELLOW" "$NC"
  log "WARN: SVG 渲染器安装失败"
  return 1
}
xml_escape(){ printf '%s' "$1"|sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"; }
build_card_svg(){
  # 内容通过 CARD_* 全局变量传入；$1 为输出文件
  local name header_r row1l row1v row2l row2v row3l row3v tag
  name=$(xml_escape "${CARD_NAME:-VPS}"); header_r=$(xml_escape "${CARD_HEADER_R:-}")
  row1l=$(xml_escape "${CARD_ROW1_L:-CURRENT}"); row1v=$(xml_escape "${CARD_ROW1_V:-}")
  row2l=$(xml_escape "${CARD_ROW2_L:-TODAY}"); row2v=$(xml_escape "${CARD_ROW2_V:-}")
  row3l=$(xml_escape "${CARD_ROW3_L:-TOTAL}"); row3v=$(xml_escape "${CARD_ROW3_V:-}")
  if [ "${CARD_MODE:-normal}" = "daily" ]; then tag="
  <rect x=\"256\" y=\"56\" width=\"196\" height=\"38\" rx=\"19\" fill=\"#a996cf\" opacity=\"0.88\"/>
  <text x=\"354\" y=\"82\" text-anchor=\"middle\" font-size=\"18\" font-weight=\"bold\" fill=\"#ffffff\" letter-spacing=\"2\">DAILY SUMMARY</text>"
  else tag=""; fi
  cat >"$1" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="550" viewBox="0 0 1000 550" font-family="DejaVu Sans, Liberation Sans, Arial, sans-serif">
 <defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
   <stop offset="0" stop-color="#eef6f2"/><stop offset="0.38" stop-color="#d4e9e4"/>
   <stop offset="0.66" stop-color="#c2d7ec"/><stop offset="1" stop-color="#e7dcef"/>
  </linearGradient>
  <radialGradient id="g1"><stop offset="0" stop-color="#9ed5c6" stop-opacity="0.55"/><stop offset="1" stop-color="#9ed5c6" stop-opacity="0"/></radialGradient>
  <radialGradient id="g2"><stop offset="0" stop-color="#c2b6e8" stop-opacity="0.5"/><stop offset="1" stop-color="#c2b6e8" stop-opacity="0"/></radialGradient>
  <radialGradient id="g3"><stop offset="0" stop-color="#f4cad6" stop-opacity="0.55"/><stop offset="1" stop-color="#f4cad6" stop-opacity="0"/></radialGradient>
  <radialGradient id="g4"><stop offset="0" stop-color="#a9cbea" stop-opacity="0.5"/><stop offset="1" stop-color="#a9cbea" stop-opacity="0"/></radialGradient>
 </defs>
 <rect width="1000" height="550" fill="url(#bg)"/>
 <ellipse cx="800" cy="150" rx="380" ry="240" fill="url(#g1)"/>
 <ellipse cx="130" cy="120" rx="320" ry="200" fill="url(#g2)"/>
 <ellipse cx="880" cy="470" rx="360" ry="220" fill="url(#g3)"/>
 <ellipse cx="220" cy="500" rx="330" ry="200" fill="url(#g4)"/>
 <g stroke="#ffffff" fill="none" stroke-linecap="round">
  <path d="M 70 402 q 45 -14 90 0 t 90 0" stroke-width="4" opacity="0.35"/>
  <path d="M 700 118 q 40 -12 80 0 t 80 0" stroke-width="3" opacity="0.3"/>
  <path d="M 560 96 q 32 -10 64 0 t 64 0" stroke-width="3" opacity="0.25"/>
 </g>
 <ellipse cx="150" cy="512" rx="95" ry="26" fill="#69ab97" opacity="0.34"/>
 <ellipse cx="150" cy="512" rx="60" ry="15" fill="#7fc0aa" opacity="0.3"/>
 <ellipse cx="855" cy="500" rx="120" ry="30" fill="#69ab97" opacity="0.3"/>
 <ellipse cx="855" cy="500" rx="72" ry="17" fill="#8cc9b2" opacity="0.28"/>
 <ellipse cx="330" cy="536" rx="55" ry="14" fill="#7fc0aa" opacity="0.26"/>
 <ellipse cx="680" cy="540" rx="45" ry="12" fill="#69ab97" opacity="0.24"/>
 <ellipse cx="520" cy="512" rx="30" ry="8" fill="#8cc9b2" opacity="0.22"/>
 <ellipse cx="252" cy="478" rx="17" ry="11" fill="#f0b3cd" opacity="0.85" transform="rotate(-12 252 478)"/>
 <ellipse cx="252" cy="478" rx="8" ry="5" fill="#fbe3ee" opacity="0.95" transform="rotate(-12 252 478)"/>
 <ellipse cx="777" cy="462" rx="15" ry="10" fill="#cbb3e6" opacity="0.85" transform="rotate(10 777 462)"/>
 <ellipse cx="777" cy="462" rx="7" ry="4" fill="#ece1f7" opacity="0.95" transform="rotate(10 777 462)"/>
 <rect x="44" y="162" width="912" height="344" rx="26" fill="#fbfdfe" opacity="0.55"/>
 <rect x="44" y="162" width="912" height="344" rx="26" fill="none" stroke="#ffffff" stroke-width="1.5" opacity="0.7"/>
 <text x="64" y="86" font-size="28" font-weight="bold" fill="#2f6b7a" letter-spacing="1">TrafficCop</text>$tag
 <text x="936" y="86" text-anchor="end" font-size="22" fill="#54798a">$header_r</text>
 <text x="64" y="134" font-size="38" font-weight="bold" fill="#1d3d49">$name</text>
 <text x="96" y="252" font-size="21" letter-spacing="3" fill="#497382">$row1l</text>
 <text x="904" y="274" text-anchor="end" font-size="54" font-weight="bold" fill="#123f4c">$row1v</text>
 <line x1="96" y1="316" x2="904" y2="316" stroke="#8fb6c0" stroke-width="1" opacity="0.4"/>
 <text x="96" y="368" font-size="21" letter-spacing="3" fill="#497382">$row2l</text>
 <text x="904" y="374" text-anchor="end" font-size="54" font-weight="bold" fill="#123f4c">$row2v</text>
 <line x1="96" y1="428" x2="904" y2="428" stroke="#8fb6c0" stroke-width="1" opacity="0.4"/>
 <text x="96" y="472" font-size="21" letter-spacing="3" fill="#497382">$row3l</text>
 <text x="904" y="478" text-anchor="end" font-size="54" font-weight="bold" fill="#123f4c">$row3v</text>
</svg>
EOF
}
render_png(){
  # $1 SVG 文件，$2 PNG 输出
  if [ -n "$RESVG_BIN" ]; then
    if [ -s "$LOCAL_FONT" ]; then "$RESVG_BIN" --quiet --use-font-file "$LOCAL_FONT" "$1" "$2" >&2
    else "$RESVG_BIN" --quiet "$1" "$2" >&2; fi
  elif [ -n "$RSVG_BIN" ]; then "$RSVG_BIN" -w 1000 -o "$2" "$1" >&2
  else return 1; fi
}
send_photo(){
  local r; r=$(curl -fsS --max-time 30 -F "chat_id=$2" -F "photo=@$3;type=image/png" "https://api.telegram.org/bot$1/sendPhoto" 2>&1) || { log "Telegram sendPhoto 失败：$r"; return 1; }
  printf %s "$r"|jq -e '.ok==true' >/dev/null 2>&1 || { log "Telegram API 失败：$r"; return 1; }
}
send_card(){
  # 只发送图片，不附加 caption 或额外文本。依赖调用方局部变量 $token $chat。
  local rc=1
  find_renderer || { log "未找到 SVG 渲染器，图片推送跳过（统计已保存）。"; return 1; }
  if build_card_svg "$SVG_FILE" && render_png "$SVG_FILE" "$PNG_FILE"; then
    send_photo "$token" "$chat" "$PNG_FILE" && rc=0
  else
    log "图片生成失败，本次推送跳过（统计已保存）。"
  fi
  rm -f "$SVG_FILE" "$PNG_FILE" 2>/dev/null
  return "$rc"
}

run_report()(
  local iface zone token chat name display_name pair rx tx now rd td used total today report_day day_label sd ed span msg bh daily_on ph_json do_daily do_push
  config_ok || die "尚未配置，请先打开交互面板。"
  iface=$(jget .interface); zone="$REPORT_TIMEZONE"; token=$(jget .bot_token); chat=$(jget .chat_id); name=$(jget '.machine_name//""')
  exec 9>"$LOCK_FILE"; flock -n 9 || { log "已有任务运行，本次跳过。"; return; }
  load_state || init_state "$iface" "$zone"; load_state; ensure_history
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
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(TZ="$zone" date -d "@$now" '+%F %T')" "$span" "$used" "$report_day" "$total" "$rd" "$td" >>"$HISTORY_FILE" || die "小时记录写入失败，未更新状态。"
  write_state "$rx" "$tx" "$total" "$today" "$ed" "$now"
  # ---- 推送决策：统计每整点照常，仅按北京时间与配置决定是否发送 ----
  bh=$((10#$(TZ="$zone" date -d "@$now" +%H)))
  daily_on=$(get_daily_setting); ph_json=$(get_push_hours_json)
  do_daily=0; do_push=0
  if [ "$bh" -eq 0 ]; then
    [ "$sd" != "$ed" ] && [ "$daily_on" = "true" ] && do_daily=1
  else
    printf '%s' "$ph_json"|jq -e --argjson h "$bh" 'index($h)!=null' >/dev/null 2>&1 && do_push=1
  fi
  if [ "$do_push" -eq 1 ]; then
    push_window "$now" "$ph_json"
    span="$PUSH_SPAN"
    printf -v msg '┌ %s · %s\n│ 本时段：%s GiB\n│ %s：%s GiB\n└ 安装后总计：%s GiB' "$display_name" "$span" "$(gib "$PUSH_USED")" "$day_label" "$(gib "$report_day")" "$(gib "$total")"
  fi
  printf '%s\n' "$msg"
  if [ "$do_daily" -eq 1 ]; then
    CARD_MODE="daily"; CARD_NAME="$display_name"; CARD_HEADER_R="$sd"
    CARD_ROW1_L="DAILY TRAFFIC"; CARD_ROW1_V="$(gib "$report_day") GiB"
    CARD_ROW2_L="AVG / HOUR"; CARD_ROW2_V="$(awk -v b="$report_day" 'BEGIN{printf "%.2f",b/24/1073741824}') GiB"
    CARD_ROW3_L="TOTAL"; CARD_ROW3_V="$(gib "$total") GiB"
    send_card && log "每日总结推送成功。" || { printf 'Telegram 推送失败，流量已保存；可手动运行 --test-telegram 查看错误。\n' >&2; return 1; }
  elif [ "$do_push" -eq 1 ]; then
    CARD_MODE="normal"; CARD_NAME="$display_name"; CARD_HEADER_R="${span//–/-}"
    CARD_ROW1_L="CURRENT"; CARD_ROW1_V="$(gib "$PUSH_USED") GiB"
    if [ "$sd" != "$ed" ]; then CARD_ROW2_L="PREV DAY"; else CARD_ROW2_L="TODAY"; fi
    CARD_ROW2_V="$(gib "$report_day") GiB"; CARD_ROW3_L="TOTAL"; CARD_ROW3_V="$(gib "$total") GiB"
    send_card && log "Telegram 推送成功。" || { printf 'Telegram 推送失败，流量已保存；可手动运行 --test-telegram 查看错误。\n' >&2; return 1; }
  else
    log "整点 $bh 未命中推送时间，仅统计。"
  fi
)
test_tg(){
  config_ok || die "请先配置。"
  local token chat name span="" iface pair rx=0 tx=0 rd=0 td=0 used=0 today=0 total=0 now
  token=$(jget .bot_token); chat=$(jget .chat_id); name=$(jget '.machine_name//""')
  find_renderer || install_render_dep
  # 展示真实数据：基于当前 state 基线与 vnStat 实时读数（不落盘，不影响整点统计）
  iface=$(jget .interface); now=$(date +%s)
  if pair=$(vn_total "$iface"); then read -r rx tx <<<"$pair"; fi
  if load_state; then
    if [ "$rx" -ge "$LAST_RX" ]; then rd=$((rx-LAST_RX)); else rd=$rx; fi
    if [ "$tx" -ge "$LAST_TX" ]; then td=$((tx-LAST_TX)); else td=$tx; fi
    used=$((rd+td)); total=$((TOTAL_BYTES+used)); today=$((TODAY_BYTES+used))
    span="$(interval "$LAST_TIMESTAMP" "$now" "$REPORT_TIMEZONE")"
  fi
  [ -n "$span" ] || span="no baseline yet - $(TZ="$REPORT_TIMEZONE" date -d "@$now" '+%F %H:%M')"
  CARD_MODE="normal"; CARD_NAME="${name:-VPS}"; CARD_HEADER_R="${span//–/-}"
  CARD_ROW1_L="CURRENT"; CARD_ROW1_V="$(gib "$used") GiB"
  CARD_ROW2_L="TODAY"; CARD_ROW2_V="$(gib "$today") GiB"; CARD_ROW3_L="TOTAL"; CARD_ROW3_V="$(gib "$total") GiB"
  send_card || die "测试失败，请查看上方错误。"
  printf '%b测试图片发送成功。%b\n' "$GREEN" "$NC"
}
format_push_hours(){
  local j n; j=$(get_push_hours_json); n=$(printf '%s' "$j"|jq -r 'length')
  if [ "$n" -eq 0 ]; then printf '（未设置）'
  elif [ "$n" -eq 23 ]; then printf '全部整点（01:00–23:00）'
  else printf '%s' "$j"|jq -r 'map((tostring|(if length==1 then "0"+. else . end))+":00")|join(", ")'; fi
}
status(){
  config_ok || { echo '尚未配置。'; return; }; local total=0 today=0
  load_state && { total=$TOTAL_BYTES; today=$TODAY_BYTES; }
  local ds hs; if [ "$(get_daily_setting)" = "true" ]; then ds="开启"; else ds="关闭"; fi; hs=$(format_push_hours)
  printf '机器：%s\n网卡：%s（接收 + 发送）\n推送时区：北京时间（Asia/Shanghai）\n每日总结：%s\n普通推送时间：%s\n今日累计：%s GiB\n安装后累计：%s GiB\n' "$(jget '.machine_name//""')" "$(jget .interface)" "$ds" "$hs" "$(gib "$today")" "$(gib "$total")"
}
history(){
  [ -s "$HISTORY_FILE" ] || { echo '暂无小时记录。'; return; }
  printf '结束时间\t统计区间\t区间流量\t当日累计\t安装后累计\n'
  tail -n +2 "$HISTORY_FILE" | tail -n 25 | awk -F '\t' '{printf "%s\t%s\t%.2f GiB\t%.2f GiB\t%.2f GiB\n",$1,$2,$3/1073741824,$4/1073741824,$5/1073741824}'
}
install_all()(
  root; mkdir -p "$WORK_DIR"; install_deps || die "依赖安装失败。"
  if [ "$(readlink -f "${BASH_SOURCE[0]}")" != "$(readlink -f "$SCRIPT_PATH" 2>/dev/null || true)" ]; then cp -f "${BASH_SOURCE[0]}" "$SCRIPT_PATH" || die "脚本安装失败。"; fi
  chmod 700 "$SCRIPT_PATH"; start_vnstat; config_ok || configure
  config_ok && push_fields_missing && configure_push
  exec 9>"$LOCK_FILE"; flock 9 || die "无法获取安装锁。"
  local iface zone; iface=$(jget .interface); zone="$REPORT_TIMEZONE"; ensure_iface "$iface"; load_state || init_state "$iface" "$zone"; ensure_history
  chmod 600 "$CONFIG_FILE" "$STATE_FILE" || die "无法设置数据文件权限。"
  install_cron
  rm -f -- "$WORK_DIR/trafficcop.log" "$WORK_DIR/cron.log"
  install_render_dep || true
  printf '%b安装完成：每整点统计一次流量，并按配置的北京时间推送 Telegram 图片。%b\n' "$GREEN" "$NC"
)
menu(){
  root; mkdir -p "$WORK_DIR"
  while true; do clear 2>/dev/null || true; printf '%bTrafficCop v%s%b\n双向流量统计 + 按配置时间推送 Telegram 图片卡片。\n\n' "$CYAN" "$VERSION" "$NC"
    printf '1) 安装/修复小时任务\n2) 修改 Telegram 与统计配置\n3) 测试 Telegram 图片推送\n4) 查看当前统计\n5) 查看小时记录\n6) 立即统计一次（按当前推送规则）\n7) 停用小时任务（保留数据）\n0) 退出\n\n'
    read -r -p '请选择 [0-7]: ' c
    case "$c" in 1) install_all;pause;; 2) install_deps;configure;install_all;pause;; 3) test_tg;pause;; 4) status;pause;; 5) history;pause;; 6) run_report;pause;; 7) remove_cron;echo '任务已停用，配置和数据仍保留。';pause;; 0) exit;; *) echo '无效选择。';sleep 1;; esac
  done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
case "${1:-}" in --run)run_report;; --install)install_all;; --test-telegram)test_tg;; --status)status;; --history)history;; --help)printf '用法：%s [--install|--run|--test-telegram|--status|--history]\n' "$0";; "")menu;; *)die "未知参数：$1";; esac
fi
