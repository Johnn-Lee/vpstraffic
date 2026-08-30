# TrafficCop

TrafficCop now does two things only: it counts bidirectional VPS traffic (RX + TX), and writes/sends one Telegram report at the top of every hour.

Telegram reports use a four-line HTML monospace card:

```text
┌ HongKong VPS · 2026-08-30 09:00–10:00
│ This interval: 1.25 GiB
│ Today total: 3.40 GiB
└ Since install: 18.72 GiB
```

At midnight, the third line identifies the completed date and shows its full-day total.

Notifications, hourly intervals, and daily resets always use Beijing time (Asia/Shanghai). The installation-time vnStat counters are the baseline, so pre-install traffic is excluded.

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Johnn-Lee/vpstraffic/main/trafficcop-manager.sh)
```

The panel asks for the Telegram Bot Token, Chat ID, network interface, and an optional machine name. Beijing time is fixed and does not depend on the VPS system timezone.

Open the panel later with:

```bash
/root/TrafficCop/trafficcop.sh
```

Files are stored under `/root/TrafficCop`: `config.json`, `state`, `hourly_traffic.tsv`, `trafficcop.log`, and `cron.log`.

Traffic is displayed in GiB (1024³ bytes). A failed Telegram request does not discard or double-count the saved traffic record.
