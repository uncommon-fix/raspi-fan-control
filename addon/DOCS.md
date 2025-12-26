# Configuration Documentation

Detailed reference for all configuration options in the Raspberry Pi 5 Fan Control add-on.

## Temperature Thresholds

### CPU Fan Thresholds (°C)

The CPU fan has 5 discrete states (0-4) controlled by the thermal cooling device. Higher states mean faster fan speeds.

| Parameter | Description | Default | Range |
|-----------|-------------|---------|-------|
| `cpu_temp_thresholds.state1` | Temperature to activate low speed | 50°C | 30-70°C |
| `cpu_temp_thresholds.state2` | Temperature to activate medium speed | 60°C | 40-80°C |
| `cpu_temp_thresholds.state3` | Temperature to activate high speed | 70°C | 50-90°C |
| `cpu_temp_thresholds.state4` | Temperature to activate maximum speed | 80°C | 60-100°C |

**How it works:**
- Below 50°C: Fan off (state 0)
- 50-59°C: Low speed (state 1)
- 60-69°C: Medium speed (state 2)
- 70-79°C: High speed (state 3)
- 80°C+: Maximum speed (state 4)

**Hysteresis effect:**
With default hysteresis of 3°C, once the fan increases to state 2 at 60°C, it won't decrease back to state 1 until temperature drops below 57°C (60 - 3).

### NVMe Fan Thresholds (°C)

The NVMe fan uses PWM (Pulse Width Modulation) for variable speed control. Duty cycle ranges from 0% (off) to 80% (maximum).

| Parameter | Description | Default | Range |
|-----------|-------------|---------|-------|
| `nvme_temp_thresholds.level1` | Temperature for 20% duty cycle | 50°C | 30-70°C |
| `nvme_temp_thresholds.level2` | Temperature for 40% duty cycle | 60°C | 40-80°C |
| `nvme_temp_thresholds.level3` | Temperature for 60% duty cycle | 70°C | 50-90°C |
| `nvme_temp_thresholds.level4` | Temperature for 80% duty cycle | 80°C | 60-100°C |

**How it works:**
- Below 50°C: Fan off (0%)
- 50-59°C: 20% duty cycle (quiet)
- 60-69°C: 40% duty cycle (moderate)
- 70-79°C: 60% duty cycle (active)
- 80°C+: 80% duty cycle (maximum)

**Note:** The NVMe fan never goes to 100% to preserve fan longevity and reduce noise. 80% provides sufficient cooling for NVMe drives.

**If no NVMe drive:** The add-on will detect this and disable NVMe fan control automatically. This is normal and expected.

---

## Hysteresis

**Parameter:** `hysteresis`
**Default:** 3°C
**Range:** 1-10°C

### What is Hysteresis?

Hysteresis prevents the fan from rapidly switching between speeds when temperature hovers near a threshold boundary. It creates a "dead zone" between increasing and decreasing fan speed.

### How It Works

**Without hysteresis:**
```
59°C → state 1
60°C → state 2  (fan increases)
59°C → state 1  (fan decreases)
60°C → state 2  (fan increases again)
```
This rapid oscillation is annoying and reduces fan lifespan.

**With 3°C hysteresis:**
```
59°C → state 1
60°C → state 2  (fan increases)
59°C → state 2  (stays, within hysteresis band)
58°C → state 2  (stays, within hysteresis band)
57°C → state 1  (fan decreases, outside band)
```

### Choosing the Right Value

- **Lower values (1-2°C)**: More responsive, faster reaction to temperature changes
  - Good for performance-oriented setups
  - May oscillate more near thresholds

- **Higher values (4-5°C)**: More stable, fewer speed changes
  - Good for noise-sensitive setups
  - Less responsive to quick temperature spikes

- **Default (3°C)**: Balanced approach for most use cases

---

## Loop Interval

**Parameter:** `loop_interval`
**Default:** 5 seconds
**Range:** 1-60 seconds

Determines how often the add-on checks temperatures and adjusts fan speeds.

### Performance Impact

| Interval | CPU Usage | Responsiveness | Recommended For |
|----------|-----------|----------------|-----------------|
| 1-2s | ~0.8-1.0% | Very responsive | Performance setups, overclocking |
| 3-5s | ~0.4-0.6% | Responsive | **Default, most users** |
| 10-15s | ~0.2-0.3% | Moderate | Power-saving, stable loads |
| 30-60s | <0.1% | Slow | Minimal overhead, very stable loads |

**Recommendation:** Use default 5 seconds unless you have specific needs. Lower values don't significantly improve thermal management for typical workloads.

---

## Debug Mode

**Parameter:** `debug_mode`
**Default:** false
**Values:** true or false

### When Disabled (default)

Logs show:
- Temperature and fan state every 5 seconds
- Fan speed changes
- Errors and warnings

### When Enabled

Additionally logs:
- Each temperature sensor read operation
- Hysteresis calculations and decisions
- Threshold comparisons
- Detailed hardware interface operations

### When to Enable

- Troubleshooting fan behavior
- Tuning temperature thresholds
- Understanding why fan speeds change
- Debugging unexpected behavior

### Example Debug Output

```
2025-12-26 14:30:37 | DEBUG: Reading temperature from /sys/class/hwmon/hwmon2/temp1_input
2025-12-26 14:30:37 | DEBUG: CPU temperature: 52C
2025-12-26 14:30:37 | DEBUG: CPU hysteresis active: temp=52, threshold=60, staying at state 1
2025-12-26 14:30:37 | DEBUG: CPU fan state set to 1
```

**Note:** Debug mode increases log verbosity significantly. Disable after troubleshooting to reduce log size.

---

## Startup Test

**Parameter:** `startup_test_enabled`
**Default:** true
**Values:** true or false

### Purpose

Runs a 30-second high-speed fan test when the add-on starts. This provides immediate visual/audible confirmation that:
- Both fans are connected properly
- Fans respond to control commands
- Hardware configuration is correct

### When Enabled (default)

```
log: Running 30-second startup test...
log: Fans will spin at high speed to verify system is working
log: Startup test running... (30 seconds)
[Both fans spin at high speed for 30 seconds]
log: Startup test complete - switching to temperature-based control
```

### When Disabled

The add-on skips the startup test and begins temperature-based control immediately.

### When to Disable

- You've already verified fans work
- Noise during add-on restarts is unacceptable
- Running in a noise-sensitive environment
- You restart the add-on frequently

**Recommendation:** Keep enabled for initial setup and verification. Can be disabled after confirming hardware works correctly.

---

## Configuration Examples

### Example 1: Quiet Home Office Setup

Prioritize silence over cooling performance:

```yaml
cpu_temp_thresholds:
  state1: 55
  state2: 65
  state3: 75
  state4: 85
nvme_temp_thresholds:
  level1: 55
  level2: 65
  level3: 75
  level4: 85
hysteresis: 5
loop_interval: 10
debug_mode: false
startup_test_enabled: false
```

**Result:** Fans rarely activate, very quiet operation. CPU may run warmer (60-70°C typical).

### Example 2: Performance/Overclocking Setup

Prioritize cooling over noise:

```yaml
cpu_temp_thresholds:
  state1: 40
  state2: 50
  state3: 60
  state4: 70
nvme_temp_thresholds:
  level1: 45
  level2: 55
  level3: 65
  level4: 75
hysteresis: 2
loop_interval: 2
debug_mode: false
startup_test_enabled: true
```

**Result:** Aggressive cooling, fans activate early and often. CPU stays very cool (40-55°C typical).

### Example 3: Balanced Default

Good for most users:

```yaml
cpu_temp_thresholds:
  state1: 50
  state2: 60
  state3: 70
  state4: 80
nvme_temp_thresholds:
  level1: 50
  level2: 60
  level3: 70
  level4: 80
hysteresis: 3
loop_interval: 5
debug_mode: false
startup_test_enabled: true
```

**Result:** Good balance of noise and cooling. CPU stays comfortable (50-65°C typical).

### Example 4: Troubleshooting

Debug configuration issues:

```yaml
cpu_temp_thresholds:
  state1: 50
  state2: 60
  state3: 70
  state4: 80
nvme_temp_thresholds:
  level1: 50
  level2: 60
  level3: 70
  level4: 80
hysteresis: 3
loop_interval: 5
debug_mode: true    # Enable verbose logging
startup_test_enabled: true
```

**Result:** Verbose logging for troubleshooting. Review logs to understand fan behavior.

---

## Validation Rules

The add-on validates your configuration before starting:

### Temperature Thresholds Must Be Ascending

❌ **Invalid:**
```yaml
cpu_temp_thresholds:
  state1: 60
  state2: 60  # Equal to state1 - NOT ALLOWED
  state3: 55  # Less than state2 - NOT ALLOWED
  state4: 80
```

✅ **Valid:**
```yaml
cpu_temp_thresholds:
  state1: 50
  state2: 60  # Greater than state1
  state3: 70  # Greater than state2
  state4: 80  # Greater than state3
```

The add-on will refuse to start with invalid configuration and show an error message.

### Range Limits

All parameters have enforced ranges (see tables above). Values outside these ranges will be rejected.

---

## Hardware Paths Reference

For advanced users, these are the sysfs paths the add-on uses:

### PWM Control (NVMe Fan)
```
/sys/class/pwm/pwmchip0/export
/sys/class/pwm/pwmchip0/pwm2/enable
/sys/class/pwm/pwmchip0/pwm2/period
/sys/class/pwm/pwmchip0/pwm2/duty_cycle
```

### CPU Fan Control
```
/sys/class/thermal/cooling_device0/cur_state
/sys/class/thermal/cooling_device0/max_state
```

### Thermal Zone
```
/sys/class/thermal/thermal_zone0/mode
/sys/class/thermal/thermal_zone0/temp
```

### Temperature Sensors
```
/sys/class/hwmon/hwmon*/name
/sys/class/hwmon/hwmon*/temp1_input
```

---

## Need Help?

- **Can't find a setting**: Check the Configuration tab in add-on UI
- **Validation errors**: Review this documentation for valid ranges
- **Unexpected behavior**: Enable debug mode and review logs
- **Hardware issues**: See README.md troubleshooting section

For additional support, visit the [GitHub repository](https://github.com/uncommon-fix/raspi-fan-control).
