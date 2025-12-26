# Raspberry Pi 5 Fan Control

Advanced temperature-based fan control for Raspberry Pi 5 with active cooling.

## About

This add-on provides intelligent thermal management for Raspberry Pi 5 systems running Home Assistant OS. It monitors CPU and NVMe temperatures and dynamically adjusts fan speeds based on configurable thresholds with hysteresis to prevent oscillation.

## Features

- **Dual Fan Control**: Separate control for CPU fan and NVMe fan
- **Hysteresis Algorithm**: Prevents rapid oscillation when temperature hovers near thresholds
- **Multiple Safety Layers**:
  - Sensor failure detection with automatic emergency mode
  - Thermal runaway protection
  - Graceful shutdown with safe fan states
- **Configurable Thresholds**: Adjust temperature thresholds via Home Assistant UI
- **Real-time Logging**: View fan activity and temperatures in add-on logs
- **Low Resource Usage**: <1% CPU, ~15MB RAM

## Prerequisites

### 1. Hardware Requirements

- Raspberry Pi 5 with active cooling case
- CPU fan connected to official header
- NVMe fan connected to GPIO 18 (optional, if using NVMe SSD)

### 2. PWM Device Tree Overlay Configuration

**CRITICAL:** You must configure the PWM overlay before installing this add-on.

1. SSH to your Home Assistant OS host (not the add-on container):
   ```bash
   ssh root@homeassistant.local
   ```

2. Edit the boot configuration:
   ```bash
   nano /mnt/boot/config.txt
   ```

3. Add this line to enable PWM on GPIO 18:
   ```
   dtoverlay=pwm-2chan,pin=18,func=2
   ```

4. Save the file (Ctrl+X, Y, Enter) and reboot:
   ```bash
   reboot
   ```

5. After reboot, verify PWM is available:
   ```bash
   ls /sys/class/pwm/pwmchip0
   ```
   You should see the PWM chip directory.

## Installation

1. Navigate to **Settings** → **Add-ons** → **Add-on Store**
2. Click the **⋮** menu (top right) → **Repositories**
3. Add this repository URL:
   ```
   https://github.com/uncommon-fix/raspi-fan-control
   ```
4. Find "Raspberry Pi 5 Fan Control" in the add-on store
5. Click **Install**
6. Configure options (or use defaults)
7. Click **Start**
8. Check **Logs** tab to verify "Startup test complete" appears

## Configuration

Configure the add-on via the **Configuration** tab in the add-on UI. See the **Documentation** tab for detailed parameter descriptions.

### Default Configuration

```yaml
cpu_temp_thresholds:
  state1: 50  # Low speed
  state2: 60  # Medium speed
  state3: 70  # High speed
  state4: 80  # Maximum speed
nvme_temp_thresholds:
  level1: 50  # 20% duty cycle
  level2: 60  # 40% duty cycle
  level3: 70  # 60% duty cycle
  level4: 80  # 80% duty cycle
hysteresis: 3
loop_interval: 5
debug_mode: false
startup_test_enabled: true
```

### Quick Configuration Profiles

**Silent Profile** (prioritize quiet operation):
```yaml
cpu_temp_thresholds:
  state1: 55
  state2: 65
  state3: 75
  state4: 85
hysteresis: 5
```

**Performance Profile** (prioritize cooling):
```yaml
cpu_temp_thresholds:
  state1: 45
  state2: 55
  state3: 65
  state4: 75
hysteresis: 2
```

## Usage

### Monitoring

View real-time logs via **Logs** tab in the add-on UI:

```
2025-12-26 14:30:37 | CPU:  52C (State: 1) | NVMe:  45C (Duty:  8000/40000,  20%) | OK
2025-12-26 14:30:42 | CPU:  53C (State: 1) | NVMe:  46C (Duty:  8000/40000,  20%) | OK
2025-12-26 14:30:47 | CPU:  61C (State: 2) | NVMe:  47C (Duty:  8000/40000,  20%) | OK
2025-12-26 14:30:47 | INFO: CPU fan state changed: 1 -> 2 (temp: 61C)
```

### Troubleshooting

**Add-on won't start:**
- Check PWM overlay is configured: `ls /sys/class/pwm/pwmchip0`
- Verify you're on Raspberry Pi 5: `cat /proc/device-tree/model`
- Check add-on logs for specific error messages

**Fans not spinning:**
- Check physical fan connections
- Verify fans connected to correct headers
- Enable startup test to verify hardware

**Add-on keeps restarting:**
- Check hardware compatibility (must be Pi 5)
- Review logs for repeated errors
- Verify PWM overlay configured correctly

**Temperatures seem high:**
- Verify fans are actually spinning (check audibly)
- Lower temperature thresholds in configuration
- Check thermal paste application on heatsink

## Safety Features

The add-on implements multiple safety layers to protect your hardware:

1. **Sensor Failure Detection**: After 3 consecutive sensor read failures, fans automatically go to maximum speed

2. **Thermal Runaway Protection**: If CPU exceeds 90°C or NVMe exceeds 85°C, fans go to maximum and kernel thermal control is re-enabled as backup

3. **Graceful Shutdown**: When add-on stops, fans are set to safe medium speed (not off) to maintain cooling

4. **Automatic Fallback**: On any critical error, kernel thermal control is automatically re-enabled

These safety mechanisms **cannot be disabled** - hardware protection is always active.

## Technical Details

- **PWM Frequency**: 25kHz (configurable via PWM_PERIOD)
- **Loop Interval**: Checks temperatures every 5 seconds (default)
- **Resource Usage**: <0.5% CPU, ~15 MB RAM
- **Logging**: Integrated with HAOS supervisor logs

## Support

- **Issues**: [GitHub Issues](https://github.com/uncommon-fix/raspi-fan-control/issues)
- **Documentation**: See **Documentation** tab in add-on UI
- **Source Code**: [GitHub Repository](https://github.com/uncommon-fix/raspi-fan-control)

## License

MIT License - see repository for full text

## Credits

Developed by uncommon-fix
Home Assistant Add-on adaptation: v1.0.0 (2025)
