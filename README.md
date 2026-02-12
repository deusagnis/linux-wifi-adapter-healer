# 🌐 Linux Wi-Fi Adapter Healer

> Automatic recovery for frozen MediaTek MT7921U-based Wi-Fi adapters on Linux - no reboot required.

---

## 🔧 The Problem

**Fenvi AX1800** (and similar USB Wi-Fi 6 adapters based on **MediaTek MT7921U/MT7922U** chipsets) suffer from a well-known Linux driver issue:

- After **~12–48 hours** of continuous operation, the adapter silently freezes
- NetworkManager shows "connected" state, but **all traffic stops**
- `dmesg` reveals kernel warnings like:
  ```
  mt7921e 0000:01:00.0: Message 00000002 (seq 1) timeout
  mt7921e 0000:01:00.0: Failed to get patch semaphore
  ```
- Physical reconnection or full system reboot required to restore connectivity

This affects Ubuntu 22.04/24.04 and other distributions using kernel 5.15+ with the `mt7921u` driver.

---

## 💡 The Solution

Instead of rebooting the entire system, this tool **automatically recovers the adapter** by:

1. Detecting loss of connectivity (not just "disconnected" state)
2. Gracefully unloading the kernel module (`mt7921u`)
3. Performing hardware reset via USB subsystem
4. Reloading the driver and restoring NetworkManager state

✅ **No physical reconnection needed**  
✅ **No system reboot required**  
✅ **Connection restored in ~10 seconds**  
✅ **Works for any adapter with similar freeze patterns** (configurable via `MODULE_CODE`)

---

## ⚙️ Installation

### Prerequisites
```bash
# Required packages
sudo apt update
sudo apt install -y curl systemd
```

### Quick Setup
```bash
# 1. Clone or download the project
cd /opt
sudo git clone https://github.com/yourname/linux-wifi-adapter-healer.git
cd linux-wifi-adapter-healer

# 2. Make installer executable
sudo chmod +x install.bash

# 3. Run installer (default: heal-wifi.bash in current dir, 1-minute interval)
sudo ./install.bash

# 4. Verify installation
systemctl list-timers | grep wifi-adapter-healer
```

### Custom Installation
```bash
# Specify custom script path and interval
sudo ./install.bash \
  --script /w/linux-wifi-adapter-healer.sh \
  --interval 2min
```

### Installation Options
| Flag | Description | Default |
|------|-------------|---------|
| `-s`, `--script` | Path to healer script | `./heal-wifi.bash` |
| `-i`, `--interval` | Check interval (`30s`, `1min`, `5m`) | `1min` |

---

## 🔍 Verification

```bash
# Check timer status
systemctl status wifi-adapter-healer.timer

# Watch real-time logs
journalctl -u wifi-adapter-healer.service -f

# Manual trigger (for testing)
sudo systemctl start wifi-adapter-healer.service
```

Sample log output:
```
[2026-02-10T14:23:17Z] [WARN] Wi-Fi disconnected - starting recovery sequence for chipset 7921
[2026-02-10T14:23:21Z] [INFO] Wi-Fi recovery successful - connection restored (chipset 7921, script v1.4)
```

---

## 📊 Monitoring (Optional)

The healer automatically sends structured logs to **OpenTelemetry Collector** (`localhost:4318`):

| Attribute | Example Value          |
|-----------|------------------------|
| `service.name` | `wifi-adapter-healer`  |
| `script.version` | e.g. `1.4`             |
| `module.code` | e.g `7921`             |
| `interface.name` | e.g. `wlx90de8095e115` |

Visualize recovery events in **SigNoz** or **Grafana**:
- Recovery frequency over time
- Average restoration time
- Adapter stability trends

> ℹ️ Collector not required - script works standalone. OTLP transmission is non-blocking and fails gracefully.

---

## 🛠️ Uninstallation

```bash
# Stop and disable timer
sudo systemctl disable --now wifi-adapter-healer.timer

# Remove systemd units
sudo rm -f /etc/systemd/system/wifi-adapter-healer.{service,timer}

# Reload systemd
sudo systemctl daemon-reexec
```

---

## 📜 License

MIT License - free to use, modify, and distribute.

---

> 💡 **Pro Tip**: This tool saved 17+ reboots/month on a headless Ubuntu server with Fenvi AX1800. Recovery happens silently in the background - you'll only notice it worked when your SSH session stays alive after 48 hours! 😌