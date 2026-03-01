# HumanitZ Dedicated Server — Setup & Operations Guide

## Overview

This document describes the HumanitZ dedicated server setup running on an Ubuntu Linux VPS. The server is managed entirely through systemd and consists of four files.

**Server:** `MAZA [EU][Dedicated]`
**Host:** `57.129.103.224` (user: `ubuntu`)
**Game:** HumanitZ (Unreal Engine 4.27, App ID `2728330`)

---

## Architecture

```
                          ┌──────────────────────────┐
                          │  humanityz-nightly.timer │
                          │  Fires daily at 03:30    │
                          └───────────┬──────────────┘
                                      │ triggers
                          ┌───────────▼──────────────┐
                          │ humanityz-nightly.service│
                          │  (oneshot)               │
                          └───────────┬──────────────┘
                                      │ runs
                          ┌───────────▼──────────────┐
                          │  humanityz-nightly.sh    │
                          │  30-min RCON countdown   │
                          │  then: systemctl restart │
                          └───────────┬──────────────┘
                                      │ restarts
                          ┌───────────▼──────────────┐
                          │   humanityz.service      │
                          │                          │
                          │  ExecStartPre:           │
                          │   1. Backup Saved/ +     │
                          │      GameServerSettings  │
                          │   2. SteamCMD update     │
                          │                          │
                          │  ExecStart:              │
                          │   HumanitZServer binary  │
                          └──────────────────────────┘
```

---

## Files & Locations

| File | Server Path | Purpose |
|---|---|---|
| `humanityz.service` | `/etc/systemd/system/humanityz.service` | Main server service unit |
| `humanityz-nightly.sh` | `/usr/local/bin/humanityz-nightly.sh` | Nightly restart script (RCON countdown + restart) |
| `humanityz-nightly.service` | `/etc/systemd/system/humanityz-nightly.service` | Oneshot service that runs the nightly script |
| `humanityz-nightly.timer` | `/etc/systemd/system/humanityz-nightly.timer` | Systemd timer, fires daily at 03:30 UTC |
| `GameServerSettings.ini` | `/home/ubuntu/humanityz/HumanitZServer/GameServerSettings.ini` | Game server configuration |

---

## Directory Layout

```
/home/ubuntu/
├── humanityz/                          # Game install directory (SteamCMD target)
│   ├── HumanitZServer/
│   │   ├── Binaries/Linux/
│   │   │   └── HumanitZServer-Linux-Shipping   # Server binary
│   │   ├── GameServerSettings.ini               # Server config (RCON, gameplay, etc.)
│   │   └── Saved/                               # Save games, logs, engine config
│   └── ...
├── humanityz-backup/                   # Auto-backup before every update
│   ├── Saved/                          # Mirror of Saved/ directory
│   └── GameServerSettings.ini          # Copy of config
└── humanityz-stuff/                    # Deployment source files (this directory)
```

---

## How It Works

### Server Service (`humanityz.service`)

The main service runs three steps on every start (including crash recovery):

1. **Backup** — `rsync` copies `Saved/` to `/home/ubuntu/humanityz-backup/Saved/` (with `--delete` to mirror exactly), and `cp` copies `GameServerSettings.ini` to the backup directory.
2. **Update** — SteamCMD runs `app_update 2728330 -beta linuxbranch validate`. If no update is available, this completes in ~5-10 seconds.
3. **Start** — Launches the server binary on port 7777 (game), query port 27015.

Key systemd behaviors:
- `Restart=on-failure` — auto-restarts on crashes (segfault, SIGKILL, etc.)
- `RestartSec=15` — waits 15 seconds before restarting after a crash
- `RestartPreventExitStatus=1` — the game's RCON `shutdown` command exits with code 1; this prevents systemd from treating it as a crash

### Nightly Restart Flow

1. **03:30 UTC** — Timer triggers `humanityz-nightly.service`
2. The service runs `humanityz-nightly.sh`, which:
   - Sends RCON warnings at T-30, T-25, T-20, T-15, T-10, T-5 minutes
   - After the final 5-minute wait, calls `systemctl restart humanityz.service`
3. The restart triggers the service's `ExecStartPre` steps (backup → update → start)
4. **~04:01 UTC** — Server is back online with latest updates

### RCON

- **Port:** 8888 (TCP)
- **Enabled in:** `GameServerSettings.ini` (`RCONEnabled=true`, `RConPort=8888`)
- **CLI tool:** [gorcon/rcon-cli](https://github.com/gorcon/rcon-cli), installed as `rcon`
- **Usage:** `rcon -a 127.0.0.1:8888 -p '<password>' '<command>'`
- **Known commands:** `shutdown`, `admin <message>`, etc.

### Backups

A single rolling backup is maintained at `/home/ubuntu/humanityz-backup/`. It is overwritten on every server start (nightly restart, crash recovery, or manual restart). It contains:
- `Saved/` — save games, logs, engine configs
- `GameServerSettings.ini` — server settings

> **Note:** This is a single-copy backup. For point-in-time recovery, consider adding a cron job that copies the backup directory with a timestamp.

---

## Network Ports

| Port | Protocol | Purpose |
|---|---|---|
| 7777 | UDP | Game traffic |
| 27015 | UDP | Steam query |
| 8888 | TCP | RCON |

---

## Common Operations

### Manual restart
```bash
sudo systemctl restart humanityz.service
```
This will backup → update → start automatically.

### Stop the server
```bash
sudo systemctl stop humanityz.service
```

### Check server status
```bash
systemctl status humanityz.service
```

### View server logs
```bash
# Live logs
journalctl -u humanityz.service -f

# Last 100 lines
journalctl -u humanityz.service -n 100 --no-pager
```

### View nightly restart logs
```bash
# Script log file
cat /home/ubuntu/humanityz-nightly.log

# Systemd journal
journalctl -u humanityz-nightly.service -n 50 --no-pager
```

### Check timer status
```bash
systemctl list-timers humanityz-nightly.timer
```

### Send an RCON message
```bash
rcon -a 127.0.0.1:8888 -p '<password>' 'admin Hello players!'
```

### Check what exit code the server used
```bash
systemctl show humanityz.service -p ExecMainStatus,ExecMainCode,Result
```

---

## Deployment

To redeploy after editing files in `humanityz-stuff/`:

```bash
# Copy service files
sudo cp /home/ubuntu/humanityz-stuff/humanityz.service /etc/systemd/system/
sudo cp /home/ubuntu/humanityz-stuff/humanityz-nightly.service /etc/systemd/system/
sudo cp /home/ubuntu/humanityz-stuff/humanityz-nightly.timer /etc/systemd/system/

# Copy script
sudo cp /home/ubuntu/humanityz-stuff/humanityz-nightly.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/humanityz-nightly.sh

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart humanityz.service
sudo systemctl restart humanityz-nightly.timer
```

---

## Dependencies

- **SteamCMD:** `/usr/games/steamcmd`
- **rcon-cli:** `rcon` (installed in PATH) — [gorcon/rcon-cli](https://github.com/gorcon/rcon-cli)
- **rsync:** `/usr/bin/rsync` (for backups)

---

## Known Quirks

- **RCON shutdown exits with code 1:** The game's `shutdown` RCON command causes the process to exit with code 1 (not 0). `RestartPreventExitStatus=1` in the service file prevents systemd from auto-restarting after an intentional shutdown. In-game shutdown exits with code 0 and is unaffected.
- **RCON port binding:** UE4 only attempts to bind the RCON TCP port once at startup. If the port is in TIME_WAIT (from a previous instance), RCON will be unavailable for the entire session. The current setup avoids this by using `systemctl restart` which cleanly manages the lifecycle.
- **SteamCMD validate:** The `validate` flag in SteamCMD can overwrite modified game files. `GameServerSettings.ini` is backed up before each update to guard against this.
