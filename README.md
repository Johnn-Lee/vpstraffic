# TrafficCop

极简 VPS 流量统计工具：每整点统计一次流量，按你设定的北京时间通过 Telegram 推送**莫奈风格图片卡片**，并支持每日总结。

## 特性

- **每整点统计**：每小时整点读取 vnStat 数据并更新统计，一次不落
- **按需推送**：Telegram 图片推送只在你设定的小时发生，其余整点只统计、不打扰
- **每日总结**：北京时间 00:00 推送前一自然日的完整流量总结（可开关）
- **图片卡片**：莫奈印象派风格图片，本地生成，数字清晰醒目
- **极简依赖**：bash + vnstat + curl + jq + 轻量 SVG 渲染器（resvg 或 rsvg-convert）
- 不引入 Python / Node.js / Chromium / Playwright，不运行后台进程或 Web 服务

## 统计与推送的关系

| 事项 | 行为 |
|------|------|
| 流量统计（vnStat 读取、state 累计、hourly_traffic.tsv 记录） | **每个整点都会执行**，与推送设置无关 |
| 普通推送 | 仅在 `push_hours` 列出的小时（北京时间）推送 |
| 每日总结 | 北京时间 00:00 跨天时推送（`daily_summary` 开启时） |

推送时间一律按**北京时间（Asia/Shanghai）**判断，与 VPS 本地时区无关。

## 快速开始

```bash
bash <(curl -sL https://raw.githubusercontent.com/Johnn-Lee/vpstraffic/main/trafficcop-manager.sh)
```

或使用本地脚本：

```bash
bash trafficcop.sh --install
```

安装时会依次询问：

1. Bot Token / Chat ID（同旧版）
2. 网卡 / 时区 / 机器名（同旧版）
3. `是否开启每日总结？[y/N]` — 北京时间 00:00 推送前一日总结
4. `请输入每天需要推送的小时（1-23，多个小时用空格隔开）` — 例如 `1 9 22`

输入的小时会自动去重、升序排列；`0` 不可输入（00:00 由每日总结开关控制）。

## 配置文件

`/root/TrafficCop/config.json`：

```json
{
  "bot_token": "123456789:AAEh...",
  "chat_id": "123456789",
  "interface": "eth0",
  "timezone": "Asia/Shanghai",
  "machine_name": "Your VPS",
  "daily_summary": true,
  "push_hours": [1, 9, 22]
}
```

| 字段 | 说明 |
|------|------|
| `daily_summary` | 每日总结开关。`true` 时北京时间 00:00 跨天推送前一日总结 |
| `push_hours` | 普通推送的小时列表（1-23 整数，北京时间）。不在列表内的整点只统计、不推送 |

**旧版本升级兼容**：从旧版升级后（重新运行安装脚本即可），若 `config.json` 缺少这两个字段，首次会提示补填；补填前按旧版行为执行（每日总结开启、1-23 全天每小时推送）。原有的 `bot_token`、`chat_id`、`interface`、`timezone`、`machine_name` 不会丢失。

## 图片推送方式

- 图片在 VPS 本地由 bash 生成 SVG，再用轻量渲染器（优先 [resvg](https://github.com/linebender/resvg) 单文件版本，回退 rsvg-convert）转成 PNG，通过 Telegram Bot API `sendPhoto` 直接上传
- 渲染器与字体在安装时自动检测/安装（x86_64 优先下载 resvg 静态二进制；aarch64 或下载失败时安装系统 rsvg-convert；字体优先使用系统自带，其次安装 DejaVu，最后从 CDN 下载到本地）
- 卡片为英文标签（CURRENT / TODAY / TOTAL / DAILY SUMMARY / RX / TX），机器名保留你的原配置（含中文）
- 临时图片文件（`.card.svg` / `.card.png`）每次生成后立即删除，不留残留
- 图片生成或发送失败时只写日志，**不影响统计与 state 持久化**，也不会导致下一小时重复计数

## 文件位置

安装目录：`/root/TrafficCop`

| 文件 | 用途 |
|------|------|
| `config.json` | 配置文件 |
| `state` | 统计状态（累计值、今日值、上次读取基准） |
| `hourly_traffic.tsv` | 每小时流量历史（结束时间、时段、本时段字节、今日累计、安装后累计） |
| `trafficcop.log` | 推送与错误日志 |
| `bin/resvg` | resvg 渲染器（仅 x86_64 且下载成功时存在） |
| `fonts/` | 本地字体（仅系统无字体且 CDN 下载成功时存在） |

定时任务：单条 cron 条目 `0 * * * * /root/TrafficCop/trafficcop.sh --run`，每整点触发一次；是否推送由脚本根据配置（北京时间 + `config.json`）自行判断，不使用多条 cron。

## CLI 用法

```bash
bash trafficcop.sh --install        # 安装/重新配置（含依赖与推送时间设置）
bash trafficcop.sh --run            # 手动统计一次（按当前推送规则决定是否推送）
bash trafficcop.sh --test-telegram  # 发送测试图片（基于实时流量数据，不落盘）
bash trafficcop.sh --status         # 查看状态
bash trafficcop.sh --history        # 查看最近 25 条统计
```

`--status` 会显示每日总结开关与普通推送时间，例如：

```
每日总结：开启
普通推送时间：01:00, 09:00, 22:00
```
