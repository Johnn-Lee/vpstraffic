# TrafficCop 4.1.0

极简 VPS 双向流量统计：每个整点读取 vnStat，按指定北京时间推送 Telegram 莫奈风格图片卡片，支持零点每日总结。

## 本次修改

- 普通推送汇总整个配置区间。例如 `push_hours: [8,12,20]`：08:00 推送 00:00–08:00，12:00 推送 08:00–12:00，20:00 推送 12:00–20:00。
- 图片中的 CURRENT、RX/TX 和时间标题使用同一个区间。TODAY / TOTAL 仍分别表示当日累计和安装后累计。
- 每小时继续独立写一条历史记录，推送频率不改变记账频率；区间直接从历史汇总，升级或重启不会丢失尚未推送的小时数据。
- Telegram **只发送图片**，普通推送、零点总结和测试均不附带说明文字或额外文本消息。
- 不再写入 `trafficcop.log` / `cron.log`，安装时删除这两个旧日志。手动执行时错误直接显示在终端；cron 输出丢弃，不发送 cron 邮件。
- 兼容原有配置、状态和 TSV，附带保留数据的完整重装脚本。

每日首个普通推送从当天 00:00 开始，即使昨日最后一次普通推送是 20:00，也不会把昨日 20:00–24:00 加入今天 08:00 的消息。昨日 20:00–24:00 仍正常保存，并计入零点的**前一整天总结**；关闭每日总结时，这段流量仍在历史和总累计里。

## 安装与重装

**已经安装并需要保留数据重装：先阅读 [保留数据重装指南](REINSTALL-zh-CN.md)。**

新安装：在解压后的本地项目目录运行：

```bash
bash trafficcop.sh --install
```

已有安装的原地更新（不清空目录）：

```bash
bash trafficcop.sh --install
```

完整卸载旧脚本再重装（自动备份配置、状态、历史，失败时尝试恢复旧安装）：

```bash
bash reinstall-preserve-data.sh
```

新包必须解压在 `/root/TrafficCop` **以外**的目录，例如 `/root/vpstraffic-4.1.0`。默认安装目录为 `/root/TrafficCop`。不需要用旧的 GitHub 一键下载命令；本修改包未发布到上游，使用旧链接可能重新装回旧版本。

依赖仍为 Bash、curl、jq、vnstat、iproute2、cron、util-linux，支持 apt / dnf / yum。图片渲染优先 resvg，回退 rsvg-convert。运行脚本无需 Python、Node.js、浏览器或额外数据库服务器；Python 只用于开发测试。

## 配置

`/root/TrafficCop/config.json`，权限 600：

```json
{
  "bot_token": "YOUR_BOT_TOKEN",
  "chat_id": "YOUR_CHAT_ID",
  "interface": "eth0",
  "timezone": "Asia/Shanghai",
  "machine_name": "Your VPS",
  "daily_summary": true,
  "push_hours": [8, 12, 20]
}
```

- `push_hours`：1–23 的整数数组，自动去重排序。空数组表示不做普通推送。交互面板沿用原有输入方式。
- `daily_summary`：是否在北京时间 00:00 跨天时发送前一自然日总结。0 不填入普通推送小时。
- 推送、区间和日期始终按北京时间计算，与系统时区无关。
- 旧配置缺少推送字段时继续兼容：每日总结开启，1–23 每小时推送，安装时提示补充设置。

安装时询问 Telegram 凭据、网卡、机器名、每日总结开关及推送小时。已有完整配置时直接保留，包括 Bot Token、Chat ID 和现有推送时间。

## 文件与存储

| 文件 | 用途 |
|---|---|
| `config.json` | Telegram、网卡、机器名与推送设置；需要备份 |
| `state` | 上次 vnStat RX/TX、总累计、当日累计、日期和时间基线；需要备份 |
| `hourly_traffic.tsv` | 唯一持续增长的项目历史文件；需要备份 |
| `trafficcop.lock` | 零字节并发锁，不是日志，不需要备份 |
| `trafficcop.sh` | 主程序 |
| `bin/resvg`、`fonts/` | 按需要安装的渲染器/字体，可重新安装 |

`state` 是必要的计数检查点，不能当作日志删除。已有历史却丢失 `state` 时，新版会停止重新初始化，避免默默清零。

TSV 前五列仍为 `ended_at / interval / hour_bytes / today_bytes / total_bytes`；新增 `rx_bytes / tx_bytes` 两列，单位都是原始字节。旧五列记录自动迁移，原始五列值不变，旧记录的 RX/TX 留空。如果本次区间含有这种旧记录，图片保留准确的区间总量，隐藏无法还原的 RX/TX 明细。

迁移使用临时文件加原子替换；`state` 也用原子替换。保留数据重装会在统计锁内制作一致备份。存储方案比较见 [STORAGE.md](STORAGE.md)。

## 运行方式

安装后打开交互面板：

```bash
/root/TrafficCop/trafficcop.sh
```

命令行：

```bash
/root/TrafficCop/trafficcop.sh --status         # 配置和最近落盘的累计
/root/TrafficCop/trafficcop.sh --history        # 最近 25 条小时/手动记录
/root/TrafficCop/trafficcop.sh --test-telegram  # 实时测试图片，不修改统计
/root/TrafficCop/trafficcop.sh --run            # 手动结束当前采集区间，按当前小时规则推送
```

定时任务始终只有一条：

```cron
# TrafficCop hourly traffic report
0 * * * * "/root/TrafficCop/trafficcop.sh" --run >/dev/null 2>&1
```

`--test-telegram` 沿用实时测试含义，CURRENT 是上次采样以来的实时增量，并非普通定时推送的区间预览。`--run` 会写入新记录，日常使用让 cron 自动执行即可。

首次安装不在整点时，第一段显示实际开始时间；如果 cron 中断、跨过配置边界后才补采，无法从一个合并的 vnStat 增量拆出精确边界流量，推送会显示所用历史记录的实际起点。继续沿用原有采样与日累计机制，不对缺失时段虚构分摊。

Telegram 失败不回滚已保存的流量，也不自动重发或改变后续配置区间。图片外观和零点每日总结样式保持原样。

## 测试

开发环境安装 Python 3、jq、Bash、GNU date 和 flock 后运行：

```bash
python3 tests/test_trafficcop.py
```

测试使用临时目录和模拟的系统命令、vnStat 读数、Telegram 发送；不触碰真实 crontab，不发送 Telegram 消息，不需要 VPS。
