# TrafficCop

一个极简 VPS 流量统计脚本，只有以下功能：

- 统计指定网卡的双向流量（接收 RX + 发送 TX）。
- 每个整点写入上一统计区间的用量，并发送一条 Telegram 消息。
- 保存“今天累计”和“从本脚本安装时开始的总累计”。
- 提供 Telegram、网卡和机器名称的交互式配置面板；推送时间固定为北京时间。

推送示例：

```text
[HongKong VPS] 2026-08-29 9.00-10.00消耗1.25G流量，今天到现在一共消耗了3.40G流量，总消耗18.72G流量
```

## 工作方式

脚本以安装时的 vnStat RX/TX 累计值为基线，之后只累计新增流量，因此不会把安装前的流量算入“总消耗”。所有推送、小时区间和每日归零统一使用北京时间（Asia/Shanghai）。若首次安装不在整点，第一条记录会显示实际的部分小时，例如 `2026-08-29 9.37-10.00`；之后为完整小时。

流量单位按 GiB 计算（1 G = 1024³ 字节），结果保留两位小数。统计对象是所选网卡；容器虚拟网卡、内网专用网卡等不会自动合并。

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Johnn-Lee/vpstraffic/main/trafficcop-manager.sh)
```

根据面板填写：

1. Telegram Bot Token
2. Telegram Chat ID
3. VPS 的主网卡（通常会自动检测，例如 `eth0`）
4. 可选的机器名称（推送时间固定为北京时间）

依赖 `curl`、`jq`、`vnstat`、`iproute2`、`cron` 和 `util-linux`，脚本支持 apt、dnf 和 yum 自动安装。

## 交互式面板

安装后随时运行：

```bash
/root/TrafficCop/trafficcop.sh
```

面板可以安装/修复定时任务、修改 Telegram 配置、测试推送、查看累计量、查看最近小时记录、立即统计一次，以及停用定时任务。

## 文件位置

- 配置：`/root/TrafficCop/config.json`（权限 600）
- 持久状态：`/root/TrafficCop/state`
- 小时记录：`/root/TrafficCop/hourly_traffic.tsv`
- 运行日志：`/root/TrafficCop/trafficcop.log`
- cron 输出：`/root/TrafficCop/cron.log`

## 命令行

```bash
/root/TrafficCop/trafficcop.sh --status
/root/TrafficCop/trafficcop.sh --history
/root/TrafficCop/trafficcop.sh --test-telegram
/root/TrafficCop/trafficcop.sh --run
```

`--run` 会立即结束当前统计区间并发送推送，通常只应由每小时 cron 调用。手动执行后，下一个整点统计的是从手动执行时刻到整点的流量。

## 注意

- 请勿删除 `state`，否则会从删除后的首次运行重新建立“安装基线”。
- 修改统计网卡后应视为一套新计数；面板会重新建立基线。
- Telegram 推送失败时，流量记录仍会落盘，避免下一小时重复累计。
