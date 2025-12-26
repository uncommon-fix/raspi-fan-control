# Raspberry Pi 5 Fan Control

Advanced temperature-based fan control daemon for Raspberry Pi 5, managing both CPU and NVMe fans with intelligent hysteresis to prevent oscillation.

## Features

- **Dual Fan Control**: Independent control of CPU fan (via thermal cooling device) and NVMe fan (via PWM)
- **Intelligent Hysteresis**: 3°C temperature buffer prevents rapid fan speed changes at threshold boundaries
- **Multi-Level Speed Control**:
  - CPU fan: 5 states (0-4)
  - NVMe fan: 5 levels (0%, 20%, 40%, 60%, 80%)
- **Daily Rotating Logs**: Automatic log rotation with configurable retention (default: 5 days)
- **Safety Features**:
  - Emergency cooling mode on sensor failures
  - Thermal runaway protection
  - Graceful shutdown with automatic thermal control restoration
  - Safe fan defaults on service stop
- **Systemd Integration**: Automatic startup, restart on failure, resource limits
- **Fully Configurable**: All thresholds and timings adjustable via configuration file

## Hardware Requirements

- **Raspberry Pi 5**
- **PWM-capable fan** connected to GPIO 18 (NVMe fan)
- **Standard fan** connected to Pi 5 fan header (CPU fan)
- **PWM overlay configured** in `/boot/firmware/config.txt`

## Prerequisites

### PWM Configuration

The NVMe fan requires PWM configuration. Add to `/boot/firmware/config.txt`:

```ini
[all]
dtoverlay=pwm,pin=18,func=2
```

After editing, reboot:

```bash
sudo reboot
```

Verify PWM is configured correctly:

```bash
pinctrl get 18
```

Expected output should show GPIO18 configured as PWM:
```
18: a3 pd | lo // GPIO18 = PWM0_CHAN2
```

## Quick Install from GitHub

The easiest way to install is directly from GitHub using curl:

```bash
curl -fsSL https://raw.githubusercontent.com/uncommon-fix/raspi-fan-control/main/install.sh | sudo bash
```

This will:
- Clone the repository to `/opt/raspi-fan-control`
- Verify hardware compatibility
- Install the fan control service
- Configure systemd

### Install Specific Version

To install a specific branch or tag:

```bash
curl -fsSL https://raw.githubusercontent.com/uncommon-fix/raspi-fan-control/main/install.sh | sudo BRANCH=v1.0 bash
```

### Update Existing Installation

To update to the latest version, just run the install command again:

```bash
curl -fsSL https://raw.githubusercontent.com/uncommon-fix/raspi-fan-control/main/install.sh | sudo bash
```

The installer will automatically pull the latest changes from GitHub.

## Alternative Installation Methods

### Clone and Install

If you prefer to clone the repository yourself:

```bash
git clone https://github.com/uncommon-fix/raspi-fan-control.git
cd raspi-fan-control
sudo ./install.sh
```

This method is useful if you want to:
- Review the code before installation
- Make local modifications
- Work offline

### Manual Installation

If you prefer manual installation:

```bash
# Create directories
sudo mkdir -p /etc/fan-control
sudo mkdir -p /usr/local/lib/fan-control
sudo mkdir -p /var/log/fan-control

# Copy files
sudo install -m 755 src/fan-control.sh /usr/local/bin/fan-control.sh
sudo install -m 644 src/fan-control-lib.sh /usr/local/lib/fan-control/fan-control-lib.sh
sudo install -m 644 src/fan-control.conf /etc/fan-control/fan-control.conf
sudo install -m 644 systemd/fan-control.service /etc/systemd/system/fan-control.service

# Set permissions
sudo chmod 755 /var/log/fan-control

# Reload systemd
sudo systemctl daemon-reload
```

## Post-Installation

### Enable and Start Service

```bash
# Enable service to start on boot
sudo systemctl enable fan-control

# Start service now
sudo systemctl start fan-control

# Check status
sudo systemctl status fan-control
```

### Monitor Operation

**View today's log:**
```bash
tail -f /var/log/fan-control/fan-control-$(date +%Y-%m-%d).log
```

**View systemd journal:**
```bash
journalctl -u fan-control -f
```

**Check current temperatures and fan states:**
```bash
# CPU temperature
cat /sys/class/thermal/thermal_zone0/temp

# CPU fan state
cat /sys/class/thermal/cooling_device0/cur_state

# NVMe fan duty cycle
cat /sys/class/pwm/pwmchip1/pwm0/duty_cycle
```

## Configuration

The configuration file is located at `/etc/fan-control/fan-control.conf`.

### Default Temperature Thresholds

**CPU Fan (Balanced Profile):**
- State 0 (off): < 50°C
- State 1 (low): 50-60°C
- State 2 (medium): 60-70°C
- State 3 (high): 70-80°C
- State 4 (max): ≥ 80°C

**NVMe Fan (Multi-level):**
- 0% (off): < 50°C
- 20%: 50-60°C
- 40%: 60-70°C
- 60%: 70-80°C
- 80%: ≥ 80°C

**Hysteresis:** 3°C (temperature must drop 3°C below threshold before reducing fan speed)

### Adjusting Thresholds

Edit the configuration file:

```bash
sudo nano /etc/fan-control/fan-control.conf
```

Key parameters to adjust:

```bash
# CPU fan thresholds
CPU_TEMP_STATE1=50
CPU_TEMP_STATE2=60
CPU_TEMP_STATE3=70
CPU_TEMP_STATE4=80

# NVMe fan thresholds
NVME_TEMP_LEVEL1=50
NVME_TEMP_LEVEL2=60
NVME_TEMP_LEVEL3=70
NVME_TEMP_LEVEL4=80

# Hysteresis
HYSTERESIS=3

# Loop interval (seconds)
LOOP_INTERVAL=5
```

After editing, restart the service:

```bash
sudo systemctl restart fan-control
```

### Configuration Profiles

**Conservative (Quiet, allows higher temps):**
```bash
CPU_TEMP_STATE1=55
CPU_TEMP_STATE2=65
CPU_TEMP_STATE3=75
CPU_TEMP_STATE4=85
HYSTERESIS=5
LOOP_INTERVAL=10
```

**Aggressive (Cool, more active cooling):**
```bash
CPU_TEMP_STATE1=45
CPU_TEMP_STATE2=55
CPU_TEMP_STATE3=65
CPU_TEMP_STATE4=75
HYSTERESIS=2
LOOP_INTERVAL=3
```

## Log Format

Logs are written to `/var/log/fan-control/fan-control-YYYY-MM-DD.log`.

**Format:**
```
YYYY-MM-DD HH:MM:SS | CPU: XXC (State: X) | NVMe: XXC (Duty: XXXXX/40000, XX%) | STATUS
```

**Example:**
```
2025-12-26 14:30:15 | CPU:  65C (State: 2) | NVMe:  58C (Duty:  8000/40000,  20%) | OK
2025-12-26 14:30:20 | CPU:  67C (State: 2) | NVMe:  59C (Duty:  8000/40000,  20%) | OK
2025-12-26 14:35:10 | CPU:  72C (State: 3) | NVMe:  64C (Duty: 16000/40000,  40%) | OK
```

**Status Messages:**
- `OK`: Normal operation
- `SENSOR_ERROR`: Temporary sensor read failure
- `EMERGENCY`: Emergency cooling mode active
- `THERMAL_RUNAWAY`: Critical temperature exceeded

## Troubleshooting

### Service won't start

**Check hardware:**
```bash
ls -la /sys/class/pwm/pwmchip1
ls -la /sys/class/thermal/cooling_device0
```

**Check logs:**
```bash
journalctl -u fan-control -n 50
```

**Verify PWM configuration:**
```bash
pinctrl get 18
cat /boot/firmware/config.txt | grep pwm
```

### Sensor not found

**List available sensors:**
```bash
for hwmon in /sys/class/hwmon/hwmon*; do
    echo "$hwmon: $(cat $hwmon/name 2>/dev/null)"
done
```

**Check temperatures:**
```bash
cat /sys/class/hwmon/hwmon*/temp*_input
```

### Permission denied

The service must run as root. Check systemd service configuration:

```bash
systemctl cat fan-control | grep User
```

Should not have a `User=` line (defaults to root).

### Fans not responding

**Test CPU fan manually:**
```bash
# Disable automatic control
echo disabled | sudo tee /sys/class/thermal/thermal_zone0/mode

# Test different states
echo 0 | sudo tee /sys/class/thermal/cooling_device0/cur_state  # Off
echo 2 | sudo tee /sys/class/thermal/cooling_device0/cur_state  # Medium
echo 4 | sudo tee /sys/class/thermal/cooling_device0/cur_state  # Max

# Re-enable automatic control
echo enabled | sudo tee /sys/class/thermal/thermal_zone0/mode
```

**Test NVMe fan manually:**
```bash
cd /sys/class/pwm/pwmchip1

# Export if needed
echo 0 | sudo tee export

cd pwm0
echo 0     | sudo tee enable
echo 40000 | sudo tee period
echo 8000  | sudo tee duty_cycle  # 20%
echo 1     | sudo tee enable

# Try different speeds
echo 16000 | sudo tee duty_cycle  # 40%
echo 32000 | sudo tee duty_cycle  # 80%
echo 0     | sudo tee duty_cycle  # Off
```

### High CPU usage

Check loop interval in configuration. Default is 5 seconds. Increase if needed:

```bash
LOOP_INTERVAL=10
```

### Logs growing too large

Adjust retention period in configuration:

```bash
LOG_RETENTION_DAYS=3
```

Or manually clean logs:

```bash
sudo find /var/log/fan-control -name "*.log" -mtime +3 -delete
```

## Uninstallation

To completely remove the fan control system:

```bash
sudo /opt/raspi-fan-control/uninstall.sh
```

The uninstaller will ask if you want to remove:
- **Log files**: Removes `/var/log/fan-control/` directory
- **Cached repository**: Removes `/opt/raspi-fan-control/` directory

**Note**: Keeping the cached repository allows faster reinstall and offline installation. If you remove it, you'll need to use curl to download from GitHub again.

This will:
- Stop and disable the service
- Restore automatic thermal control
- Remove all installed files from system locations

After uninstallation, your Raspberry Pi will revert to the default kernel-based fan control.

## How It Works

### Hysteresis Algorithm

Hysteresis prevents rapid fan speed changes when temperature hovers near a threshold:

1. **Temperature rising**: Fan speed increases immediately when threshold is crossed
2. **Temperature falling**: Fan speed only decreases after temperature drops HYSTERESIS degrees below the threshold

**Example with 3°C hysteresis:**
- Fan increases to State 2 at 60°C
- Temperature drops to 59°C → fan stays at State 2 (within hysteresis band)
- Temperature drops to 57°C → fan decreases to State 1 (below 60-3=57°C)

This creates a "sticky" behavior that prevents oscillation while still being responsive to significant temperature changes.

### Temperature Sensor Discovery

The system automatically discovers sensors by searching `/sys/class/hwmon/hwmon*/name`:
- **CPU**: Looks for devices named "cpu_thermal" or "thermal_zone"
- **NVMe**: Looks for devices with "nvme" in the name

Device numbers (hwmon0, hwmon1, etc.) can change between reboots, so the search ensures reliability.

### Emergency Mode

Emergency mode activates when:
- Sensor reads fail 3 consecutive times
- CPU temperature exceeds 90°C
- NVMe temperature exceeds 85°C

**Emergency actions:**
- Force fans to maximum speed
- Re-enable automatic thermal control (double safety)
- Log critical error
- Continue monitoring

### Graceful Shutdown

On service stop (SIGTERM/SIGINT):
1. Set fans to safe defaults (CPU: State 2, NVMe: 40%)
2. Re-enable automatic thermal control
3. Disable and unexport PWM
4. Log shutdown event

This ensures the system remains cooled even after the service stops.

## Architecture

```
fan-control.sh (main daemon)
├── Sources fan-control.conf (configuration)
├── Sources fan-control-lib.sh (library functions)
│   ├── Logging (setup, rotation, state logging)
│   ├── Temperature reading (hwmon discovery, validation)
│   ├── Hardware control (PWM, thermal devices)
│   ├── Control logic (hysteresis calculations)
│   └── Safety (thermal runaway, cleanup)
└── Main loop
    ├── Read temperatures
    ├── Check safety
    ├── Calculate new states (with hysteresis)
    ├── Apply changes
    ├── Log state
    └── Sleep
```

## File Locations

**Installed system:**
- Configuration: `/etc/fan-control/fan-control.conf`
- Main script: `/usr/local/bin/fan-control.sh`
- Library: `/usr/local/lib/fan-control/fan-control-lib.sh`
- Systemd service: `/etc/systemd/system/fan-control.service`
- Logs: `/var/log/fan-control/fan-control-YYYY-MM-DD.log`
- Cached repository: `/opt/raspi-fan-control/` (when installed via curl)

**Cached repository structure:**
```
/opt/raspi-fan-control/
├── src/
│   ├── fan-control.conf
│   ├── fan-control-lib.sh
│   └── fan-control.sh
├── systemd/
│   └── fan-control.service
├── install.sh
├── uninstall.sh
├── README.md
└── .installed          # Installation metadata
```

## Testing

After installation, verify operation:

**1. Check service is running:**
```bash
sudo systemctl status fan-control
```

**2. Generate CPU load:**
```bash
stress-ng --cpu 4 --timeout 60s
```

Watch logs during stress test:
```bash
tail -f /var/log/fan-control/fan-control-$(date +%Y-%m-%d).log
```

Verify CPU fan state increases as temperature rises.

**3. Test hysteresis:**

Monitor logs and observe that when temperature drops just below a threshold, the fan speed doesn't decrease immediately (hysteresis working).

**4. Test service lifecycle:**
```bash
sudo systemctl stop fan-control
sudo systemctl status fan-control
cat /sys/class/thermal/thermal_zone0/mode  # Should be "enabled"
sudo systemctl start fan-control
```

**5. Test reboot:**
```bash
sudo reboot
# After reboot
sudo systemctl status fan-control  # Should be running if enabled
```

## Performance

- **CPU Usage**: < 0.5% (typical)
- **Memory**: ~10-20 MB
- **Disk I/O**: Minimal (log writes every 5 seconds)
- **Response Time**: 5 seconds (configurable via LOOP_INTERVAL)

## Safety Features

1. **Permission Checking**: Verifies write access before starting
2. **Hardware Verification**: Ensures all required sysfs paths exist
3. **Sensor Failure Handling**: Uses last known temperature for up to 3 failures
4. **Emergency Cooling**: Activates max fans on critical conditions
5. **Thermal Runaway Protection**: Monitors for dangerous temperatures
6. **Graceful Cleanup**: Always restores automatic thermal control
7. **Safe Defaults**: Fans set to medium speed (not off) on service stop
8. **Resource Limits**: Systemd limits prevent runaway resource usage
9. **Restart Policy**: Auto-restart on failures, with backoff

## License

This project is provided as-is for Raspberry Pi 5 users. Feel free to modify and distribute.

## Contributing

Contributions welcome! Areas for improvement:
- Support for additional temperature sensors
- Web-based monitoring interface
- Email/notification alerts
- Custom temperature curves
- Profile switching via signals
- Smooth PWM ramping

## Acknowledgments

Built for the Raspberry Pi 5 community to provide advanced fan control with reliability and safety in mind.
