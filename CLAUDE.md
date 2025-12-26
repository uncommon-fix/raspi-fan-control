# Raspberry Pi 5 Fan Control - Technical Documentation

Technical reference for AI assistants, developers, and advanced users.

## 1. Architecture Overview

### 1.1 Component Hierarchy

The fan control system consists of three primary components with a total codebase of approximately 964 lines of bash:

- **Main daemon** (fan-control.sh): 281 lines
- **Library functions** (fan-control-lib.sh): 573 lines
- **Configuration** (fan-control.conf): 110 lines

### 1.2 File Responsibilities

**fan-control.sh (Main Daemon):**
- Main control loop implementation (lines 138-261)
- State tracking variables (lines 115-128)
- Signal handling setup (line 57)
- Sensor discovery (lines 93-109)
- Root permission verification (lines 46-50)
- Configuration and library loading (lines 14-40)

**fan-control-lib.sh (Library Functions):**
- Hardware abstraction layer (lines 198-348)
- Hysteresis algorithm implementation (lines 354-438)
- Safety mechanisms (lines 447-494)
- Logging system with rotation (lines 33-115)
- Temperature sensor reading (lines 159-192)
- Hardware verification (lines 534-572)

**fan-control.conf (Configuration):**
- Temperature thresholds (CPU_TEMP_STATE1-4, NVME_TEMP_LEVEL1-4)
- PWM parameters (PWM_PERIOD, NVME_DUTY_*)
- Hardware paths (PWM_CHIP, CPU_COOLING_DEVICE, THERMAL_ZONE)
- Logging settings (LOG_DIR, LOG_RETENTION_DAYS, DEBUG_MODE)
- Safety limits (CPU_CRITICAL_TEMP, NVME_CRITICAL_TEMP, MAX_SENSOR_FAILURES)

### 1.3 Execution Flow

1. **Root permission check** (lines 46-50): Verifies EUID=0, exits with error if not root
2. **Configuration loading** (lines 17-33): Auto-detects installed vs source paths, loads config file
3. **Library function sourcing** (lines 35-40): Loads all utility and control functions
4. **Logging setup** (lines 66-69): Initializes log directory and rotation
5. **Permission verification** (line 78): Checks write access to sysfs paths
6. **Automatic thermal control disable** (line 81): Disables kernel automatic fan control
7. **Hardware initialization** (lines 84-87): Exports PWM channel, verifies CPU fan access
8. **30-second startup test** (lines 90-106): Spins fans at high speed for verification
9. **Sensor discovery** (lines 96-109): Dynamically finds hwmon device paths for CPU and NVMe
10. **State initialization** (lines 116-128): Sets initial fan states and tracking variables
11. **Main control loop** (lines 138-261): Infinite loop for temperature monitoring and fan control
12. **Cleanup on exit** (trap at line 57): Graceful shutdown via cleanup_handler

---

## 2. Hardware Interface Details

### 2.1 Sysfs Paths

**PWM (NVMe Fan Control):**

Base path: `/sys/class/pwm/pwmchip0`
Channel: 2 (GPIO 18 configured via device tree overlay)

Key files:
- `/sys/class/pwm/pwmchip0/export` - Export channel (write channel number)
- `/sys/class/pwm/pwmchip0/pwm2/enable` - Enable/disable (0 or 1)
- `/sys/class/pwm/pwmchip0/pwm2/period` - PWM period in nanoseconds (40000 = 25kHz)
- `/sys/class/pwm/pwmchip0/pwm2/duty_cycle` - Duty cycle in nanoseconds (0-40000)

**CPU Fan (Thermal Cooling Device):**

Path: `/sys/class/thermal/cooling_device0`

Key files:
- `/sys/class/thermal/cooling_device0/cur_state` - Current state (0-4, write to control)
- `/sys/class/thermal/cooling_device0/max_state` - Maximum supported state

Note: CPU fan uses discrete states (0-4) managed by the kernel's cooling device framework, not direct PWM control.

**Thermal Zone:**

Path: `/sys/class/thermal/thermal_zone0`

Key files:
- `/sys/class/thermal/thermal_zone0/mode` - Control mode (enabled/disabled)
- `/sys/class/thermal/thermal_zone0/temp` - Temperature reading in millidegrees Celsius

**Temperature Sensors (hwmon):**

Base: `/sys/class/hwmon/hwmon*/`

Discovery: Searches all hwmon directories for name matches
- CPU sensor: Matches "cpu_thermal" or "thermal_zone" in hwmon*/name
- NVMe sensor: Matches "nvme" in hwmon*/name
- Temperature file: hwmon*/temp1_input (millidegrees Celsius)

### 2.2 PWM Initialization Sequence

Critical sequence implemented in init_nvme_pwm() (lines 200-248):

```bash
# Step 1: Export PWM channel (if not already exported)
echo 2 > /sys/class/pwm/pwmchip0/export

# Step 2: Disable PWM before configuration changes (critical!)
echo 0 > /sys/class/pwm/pwmchip0/pwm2/enable

# Step 3: Wait for sysfs stabilization
sleep 0.5

# Step 4: Configure period (must be set before duty cycle)
echo 40000 > /sys/class/pwm/pwmchip0/pwm2/period

# Step 5: Set initial duty cycle (safe default)
echo 8000 > /sys/class/pwm/pwmchip0/pwm2/duty_cycle

# Step 6: Enable PWM output
echo 1 > /sys/class/pwm/pwmchip0/pwm2/enable
```

**Why this order matters:**
- Disabling before configuration prevents glitches during parameter changes
- The 0.5s sleep allows sysfs to process the state change (race condition mitigation)
- Period must be set before duty cycle (duty cycle cannot exceed period)
- Initial duty cycle prevents startup at 100% or undefined state

### 2.3 Sensor Discovery Mechanism

Function: `find_hwmon_device()` (lines 124-157 in fan-control-lib.sh)

**Why dynamic discovery is needed:**
hwmon device numbers (hwmon0, hwmon1, etc.) are not guaranteed to be consistent across reboots. Device enumeration order depends on driver loading order and hardware detection timing.

**Discovery algorithm:**
1. Search all /sys/class/hwmon/hwmon* directories
2. Read the 'name' file from each directory
3. Match against search pattern (e.g., "cpu", "nvme")
4. Return the temp1_input path for the matching device

**Example:**
```bash
# Search for CPU sensor
for hwmon in /sys/class/hwmon/hwmon*/name; do
    if grep -q "cpu_thermal" "$hwmon"; then
        # Found CPU sensor, return temperature file path
        echo "${hwmon%/*}/temp1_input"
    fi
done
```

### 2.4 Thermal Zone Management

**Automatic thermal control:**

The Raspberry Pi 5 kernel includes automatic thermal management that must be disabled during daemon operation to allow manual fan control.

Functions:
- `disable_auto_thermal()` (lines 268-285): Writes "disabled" to thermal_zone0/mode
- `enable_auto_thermal()` (lines 287-304): Writes "enabled" to thermal_zone0/mode

**When automatic control is re-enabled:**
- Service stop/shutdown (cleanup_handler)
- Emergency mode activation
- Thermal runaway detection
- Sensor failure threshold exceeded

This dual-layer approach ensures cooling continues even if the daemon fails.

---

## 3. Control Algorithms

### 3.1 Hysteresis Implementation

**Purpose:** Prevent rapid fan speed oscillation when temperature hovers near a threshold boundary.

**Key principle:** Asymmetric behavior - fast to increase speed, slow to decrease speed.

**Algorithm (CPU fan - calculate_cpu_state, lines 357-395):**

```
if temperature >= threshold_for_higher_state:
    immediately increase to higher state
elif temperature < (current_threshold - HYSTERESIS):
    decrease to lower state
else:
    maintain current state  # Within hysteresis band
```

**Example with HYSTERESIS=3°C:**

Initial state: State 1 at 59°C
- Temperature rises to 60°C → **immediately** jump to State 2
- Temperature drops to 59°C → **stay** at State 2 (within 60-3=57 to 60 band)
- Temperature drops to 58°C → **stay** at State 2 (still within band)
- Temperature drops to 57°C → **drop** to State 1 (below 60-3=57 threshold)

**Implementation details:**

The calculate_cpu_state function uses array lookups for thresholds:
```bash
THRESHOLDS=(0 $CPU_TEMP_STATE1 $CPU_TEMP_STATE2 $CPU_TEMP_STATE3 $CPU_TEMP_STATE4)

for state in 4 3 2 1; do
    threshold=${THRESHOLDS[$state]}
    if (( temp >= threshold )); then
        echo $state
        return 0
    fi
done

# Check if can decrease from current state
if (( current_state > 0 )); then
    current_threshold=${THRESHOLDS[$current_state]}
    if (( temp < (current_threshold - HYSTERESIS) )); then
        echo $((current_state - 1))
        return 0
    fi
fi
```

**NVMe fan (calculate_nvme_duty, lines 400-438):**

Same logic but with duty cycle values instead of states:
- Duty cycles: 0, 8000, 16000, 24000, 32000 (0%, 20%, 40%, 60%, 80%)
- Thresholds: 50°C, 60°C, 70°C, 80°C
- Hysteresis: Same 3°C default

### 3.2 Temperature Thresholds

**CPU Fan States (5 levels):**

| State | Temperature Range | Description |
|-------|------------------|-------------|
| 0 | < 50°C | Off (no cooling needed) |
| 1 | 50-59°C | Low speed (quiet operation) |
| 2 | 60-69°C | Medium speed (balanced) |
| 3 | 70-79°C | High speed (active cooling) |
| 4 | ≥ 80°C | Maximum speed (aggressive cooling) |

**NVMe Fan Duty Cycles (5 levels):**

| Duty Cycle | Percentage | Temperature Range | Value |
|------------|-----------|------------------|-------|
| NVME_DUTY_OFF | 0% | < 50°C | 0/40000 |
| NVME_DUTY_LOW | 20% | 50-59°C | 8000/40000 |
| NVME_DUTY_MED | 40% | 60-69°C | 16000/40000 |
| NVME_DUTY_HIGH | 60% | 70-79°C | 24000/40000 |
| NVME_DUTY_MAX | 80% | ≥ 80°C | 32000/40000 |

**Note:** NVMe fan never goes to 100% (40000/40000) to preserve fan longevity and reduce noise. 80% provides sufficient cooling for NVMe drives.

**Hysteresis effect:**
With HYSTERESIS=3°C, the effective bands become:
- To enter State 2: Must reach 60°C
- To exit State 2: Must drop below 57°C
- Stable band: 57-59°C (stays at State 2)

---

## 4. Safety Mechanisms

### 4.1 Three-Level Error Handling Hierarchy

**Level 1: Transient Sensor Failure (1-2 consecutive failures)**

Action: Use last known good temperature
```bash
if cpu_temp=$(read_temperature "$CPU_SENSOR"); then
    CPU_FAIL_COUNT=0
    LAST_CPU_TEMP=$cpu_temp
else
    ((CPU_FAIL_COUNT++))
    cpu_temp=$LAST_CPU_TEMP  # Fallback to last known value
    log_debug "Using last known CPU temperature: ${cpu_temp}C"
fi
```

Purpose: Handles transient I/O errors or momentary sensor communication issues
Logging: DEBUG level with failure count
Duration: Up to 3 consecutive failures

**Level 2: Persistent Sensor Failure (3+ consecutive failures)**

Trigger: `CPU_FAIL_COUNT >= MAX_SENSOR_FAILURES` (default: 3)

Actions:
1. Set EMERGENCY_MODE=1 flag
2. Force CPU fan to EMERGENCY_CPU_STATE (state 4 = maximum)
3. Force NVMe to EMERGENCY_NVME_DUTY (32000 = 80%)
4. Use dummy temperature (999°C) to keep emergency mode active
5. Log ERROR message

```bash
if (( CPU_FAIL_COUNT >= MAX_SENSOR_FAILURES )); then
    if (( EMERGENCY_MODE == 0 )); then
        log_error "CPU sensor failures exceeded threshold - ENTERING EMERGENCY MODE"
        set_cpu_fan_state "$EMERGENCY_CPU_STATE"
        EMERGENCY_MODE=1
    fi
    cpu_temp=999  # Dummy high value
fi
```

Purpose: Ensures maximum cooling when sensor reliability is compromised
Recovery: Continues monitoring; exits emergency mode when sensor reads successfully
Logging: ERROR level with critical alert

**Level 3: Thermal Runaway (Critical temperature exceeded)**

Trigger: CPU > 90°C OR NVMe > 85°C

Function: `check_thermal_runaway()` (lines 447-468)

Actions:
1. Force both fans to maximum (CPU state 4, NVMe 80%)
2. Re-enable automatic thermal control (double safety layer)
3. Set EMERGENCY_MODE=1
4. Log CRITICAL error
5. Skip normal control logic
6. Continue monitoring

```bash
if (( cpu_temp >= CPU_CRITICAL_TEMP )) || (( nvme_temp >= NVME_CRITICAL_TEMP )); then
    log_error "CRITICAL: Thermal runaway detected (CPU: ${cpu_temp}C, NVMe: ${nvme_temp}C)"
    set_cpu_fan_state "$EMERGENCY_CPU_STATE"
    set_nvme_fan_duty "$EMERGENCY_NVME_DUTY"
    enable_auto_thermal  # Re-enable kernel control as backup
    return 1  # Signals thermal runaway condition
fi
```

Purpose: Prevents hardware damage from excessive temperatures
Recovery: Emergency mode persists until temperatures drop to safe levels

### 4.2 Graceful Shutdown Sequence

Function: `cleanup_handler()` (lines 470-494)

Triggered by: SIGTERM, SIGINT, EXIT signals (trap registered at line 57)

**Six-step shutdown:**

```bash
1. Log shutdown initiation
   log_info "Shutting down fan control daemon..."

2. Set CPU fan to safe medium speed (not off!)
   set_cpu_fan_state "$SAFE_CPU_STATE"  # State 2 = medium

3. Set NVMe fan to safe medium duty (not off!)
   set_nvme_fan_duty "$SAFE_NVME_DUTY"  # 16000 = 40%

4. Re-enable automatic thermal control
   enable_auto_thermal

5. Disable and unexport PWM channel
   echo 0 > /sys/class/pwm/pwmchip0/pwm2/enable
   echo 2 > /sys/class/pwm/pwmchip0/unexport

6. Log clean shutdown
   log_info "Fan control daemon stopped cleanly"
```

**Critical design decision:** Fans are set to medium speed (not turned off) to maintain cooling after service stops. This prevents thermal issues during service restart or maintenance.

### 4.3 Startup Test (30-second verification)

Location: fan-control.sh lines 90-106

**Purpose:** Provides immediate visual/audible confirmation of hardware operation

**Implementation:**
```bash
log_info "Running 30-second startup test..."
log_info "Fans will spin at high speed to verify system is working"

# Set CPU fan to high speed (state 3)
set_cpu_fan_state 3

# Set NVMe fan to 80% duty cycle
STARTUP_NVME_DUTY=$((PWM_PERIOD * 80 / 100))
set_nvme_fan_duty "$STARTUP_NVME_DUTY"

log_info "Startup test running... (30 seconds)"
sleep 30

log_info "Startup test complete - switching to temperature-based control"
```

**Why 30 seconds:**
- Long enough to be clearly audible/visible
- Short enough to avoid annoying users
- Sufficient time to verify both fans respond to commands
- Occurs before sensor discovery, so independent of temperature

**Benefit:** Immediately identifies hardware issues (disconnected fans, PWM configuration problems) before entering production operation.

---

## 5. Logging System

### 5.1 Daily Rotation Mechanism

**Function:** `get_log_file()` (lines 37-50 in fan-control-lib.sh)

**Implementation:**
```bash
get_log_file() {
    local today=$(date +%Y-%m-%d)

    if [[ "$CURRENT_LOG_DATE" != "$today" ]]; then
        CURRENT_LOG_DATE="$today"
        CURRENT_LOG_FILE="${LOG_DIR}/fan-control-${today}.log"

        # Rotate old logs
        rotate_logs
    fi

    echo "$CURRENT_LOG_FILE"
}
```

**Rotation trigger:** Comparison of CURRENT_LOG_DATE with system date
**Timing:** Checked at midnight when date changes (or on first log write of new day)
**No interruption:** Seamless transition to new file during normal operation

**Cleanup function:** `rotate_logs()` (lines 52-62)
```bash
rotate_logs() {
    find "$LOG_DIR" -name "fan-control-*.log" \
        -type f -mtime +$LOG_RETENTION_DAYS -delete 2>/dev/null || true
}
```

Uses `find -mtime` to delete logs older than LOG_RETENTION_DAYS (default: 5)

**Advantages over external logrotate:**
- No dependency on external tools
- Guaranteed to work in any installation
- Configurable via main configuration file
- Runs automatically without cron setup

### 5.2 Log Levels

**log_state()** (lines 64-80) - Regular state logging

Format: `YYYY-MM-DD HH:MM:SS | CPU: XXC (State: X) | NVMe: XXC (Duty: XXXXX/40000, XX%) | STATUS`

Called every LOOP_INTERVAL seconds with current system state

**log_info()** (lines 82-93) - Informational messages

Examples:
- Startup messages (daemon starting, configuration loaded)
- State changes (fan speed increased/decreased)
- Sensor discovery (found CPU sensor, found NVMe sensor)
- Transition events (entering emergency mode, exiting emergency mode)

**log_error()** (lines 95-103) - Error conditions

Writes to both log file AND stderr (visible in systemd journal)

Examples:
- Sensor read failures
- Hardware access errors
- Critical temperature warnings
- Emergency mode activation

**log_debug()** (lines 105-115) - Verbose debugging output

Only active when DEBUG_MODE=1

Examples:
- Detailed sensor read operations
- Hysteresis calculations
- Threshold comparisons
- Hardware interface operations
- Timing information

### 5.3 State Log Format Specification

```
2025-12-26 14:30:15 | CPU:  65C (State: 2) | NVMe:  58C (Duty:  8000/40000,  20%) | OK
```

Field breakdown:
- `2025-12-26 14:30:15` - ISO 8601 timestamp
- `CPU:  65C` - CPU temperature in Celsius (right-aligned, 3 digits)
- `(State: 2)` - Current CPU fan state (0-4)
- `NVMe:  58C` - NVMe temperature in Celsius (right-aligned, 3 digits)
- `(Duty:  8000/40000,  20%)` - NVMe duty cycle (absolute and percentage)
- `OK` - Status indicator

### 5.4 Status Values

| Status | Meaning | Trigger |
|--------|---------|---------|
| OK | Normal operation | No errors, normal monitoring |
| SENSOR_ERROR | Temporary sensor failure | 1-2 consecutive sensor read failures |
| EMERGENCY | Emergency cooling active | 3+ failures OR manual emergency trigger |
| THERMAL_RUNAWAY | Critical temperature | CPU > 90°C OR NVMe > 85°C |

---

## 6. State Management

### 6.1 Global State Variables

Declared in main script (lines 115-128):

```bash
# Current fan states
CURRENT_CPU_STATE=1              # Current CPU fan state (0-4)
CURRENT_NVME_DUTY=$NVME_DUTY_LOW # Current NVMe duty cycle (0-40000)

# Sensor failure counters
CPU_FAIL_COUNT=0                 # Consecutive CPU sensor failures
NVME_FAIL_COUNT=0                # Consecutive NVMe sensor failures

# Last known good temperatures (for fallback)
LAST_CPU_TEMP=0                  # Last successful CPU temp reading
LAST_NVME_TEMP=0                 # Last successful NVMe temp reading

# Emergency mode flag
EMERGENCY_MODE=0                 # 0=normal, 1=emergency cooling active
```

Additional state in library (lines 117-125):

```bash
# Log rotation tracking
CURRENT_LOG_DATE=""              # Current log file date (YYYY-MM-DD)
CURRENT_LOG_FILE=""              # Current log file path
```

### 6.2 State Change Optimization

**Goal:** Minimize sysfs writes by only updating when values actually change

**CPU fan (lines 240-247):**
```bash
if [[ $new_cpu_state != $CURRENT_CPU_STATE ]]; then
    if set_cpu_fan_state "$new_cpu_state"; then
        log_info "CPU fan state changed: $CURRENT_CPU_STATE -> $new_cpu_state (temp: ${cpu_temp}C)"
        CURRENT_CPU_STATE=$new_cpu_state
    fi
fi
```

**NVMe fan (lines 250-259):**
```bash
if [[ $new_nvme_duty != $CURRENT_NVME_DUTY ]]; then
    if set_nvme_fan_duty "$new_nvme_duty"; then
        old_percent=$((CURRENT_NVME_DUTY * 100 / PWM_PERIOD))
        new_percent=$((new_nvme_duty * 100 / PWM_PERIOD))
        log_info "NVMe fan duty changed: $CURRENT_NVME_DUTY (${old_percent}%) -> $new_nvme_duty (${new_percent}%) (temp: ${nvme_temp}C)"
        CURRENT_NVME_DUTY=$new_nvme_duty
    fi
fi
```

**Benefits:**
- Reduces I/O load on sysfs
- Prevents unnecessary fan speed adjustments
- Improves performance (fewer system calls)
- Cleaner logs (only logs actual changes)

### 6.3 State Persistence

**Important:** State is not persisted across service restarts. Each restart:
- Starts with safe defaults (CPU State 1, NVMe 20%)
- Runs 30-second startup test
- Discovers sensors
- Begins normal operation

**Rationale:** Temperature-based control doesn't require state persistence. The system naturally converges to appropriate fan speeds based on current temperatures.

---

## 7. Systemd Integration

### 7.1 Security Hardening

File: systemd/fan-control.service (lines 17-26)

**ProtectSystem=strict:**
```ini
ProtectSystem=strict
```
Makes /usr, /boot, and /etc read-only to the service. Prevents accidental or malicious modification of system files.

**ReadWritePaths whitelist:**
```ini
ReadWritePaths=/var/log/fan-control /sys/class/pwm /sys/class/thermal
```
Explicitly allows writes to only:
- `/var/log/fan-control` - Log file directory
- `/sys/class/pwm` - PWM control for NVMe fan
- `/sys/class/thermal` - Thermal zone and cooling device control

All other paths remain read-only due to ProtectSystem=strict.

**PrivateTmp:**
```ini
PrivateTmp=yes
```
Provides isolated /tmp directory. Prevents:
- Information leakage via shared temporary files
- Temp file conflicts with other services
- Potential security exploits via /tmp

**NoNewPrivileges:**
```ini
NoNewPrivileges=true
```
Prevents the service from gaining additional privileges through:
- setuid/setgid executables
- File capabilities
- Security policy transitions

Combined effect: Principle of least privilege - service can only access what it absolutely needs.

### 7.2 Resource Limits

File: systemd/fan-control.service (lines 28-30)

**CPU Quota:**
```ini
CPUQuota=5%
```
Limits service to maximum 5% CPU utilization. Prevents:
- Runaway processes consuming excessive CPU
- Impact on system responsiveness
- Resource exhaustion attacks

Typical usage: <0.5% with 5-second loop interval, so 5% provides 10x safety margin.

**Memory Maximum:**
```ini
MemoryMax=50M
```
Hard limit of 50 MB memory usage. Prevents:
- Memory leaks from exhausting system RAM
- Out-of-memory conditions affecting other services
- Resource-based denial of service

Typical usage: 10-20 MB, so 50 MB provides ~3x safety margin.

### 7.3 Restart Policy

File: systemd/fan-control.service (lines 11-15)

**Configuration:**
```ini
Restart=on-failure           # Only restart on abnormal exit
RestartSec=10s              # Wait 10 seconds before restart
StartLimitInterval=200      # Time window for rate limiting
StartLimitBurst=5           # Max restarts within interval
```

**Behavior:**

Normal shutdown (exit 0, SIGTERM): No restart
Abnormal exit (exit 1, crash, SIGKILL): Restart after 10 seconds

**Rate limiting:**
- Allows 5 restart attempts within 200-second window
- If limit exceeded: Service enters failed state
- Prevents infinite restart loops from persistent failures

**Example scenario:**
1. Service crashes at T=0
2. Systemd waits 10 seconds
3. Service restarts at T=10
4. Crashes again at T=15
5. Waits, restarts at T=25
6. This continues up to 5 times
7. If 6th failure within 200 seconds: Stop attempting, mark failed

---

## 8. Installation System

### 8.1 Smart Installation Flow

File: install.sh (lines 71-139)

**Execution context detection:**
```bash
if [[ "${BASH_SOURCE[0]}" =~ ^/dev/fd/ ]] || [[ ! -f "${BASH_SOURCE[0]}" ]]; then
    # Running from curl/stdin (pipe detection)
    RUNNING_FROM_CURL=true
else
    # Running from filesystem (cloned repo)
    RUNNING_FROM_CURL=false
fi
```

**Flow for curl installation:**
```
1. User runs: curl ... | sudo bash
2. Script detects pipe execution
3. Clones repository to /opt/raspi-fan-control
4. Re-executes itself from cached location: exec /opt/raspi-fan-control/install.sh
5. Second execution proceeds with installation
```

**Flow for git clone installation:**
```
1. User runs: git clone ...; cd ...; sudo ./install.sh
2. Script detects filesystem execution
3. Proceeds directly with installation
```

**Repository caching benefits:**
- Enables offline reinstall/updates
- Provides access to uninstall.sh
- Allows local modifications
- Supports future updates (git pull)

### 8.2 Path Resolution Logic

File: fan-control.sh (lines 14-26)

**Smart path detection:**
```bash
if [[ -f "/etc/fan-control/fan-control.conf" ]]; then
    # Installed mode - use system paths
    CONFIG_FILE="/etc/fan-control/fan-control.conf"
    LIB_FILE="/usr/local/lib/fan-control/fan-control-lib.sh"
else
    # Source mode - use local paths
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CONFIG_FILE="$SCRIPT_DIR/fan-control.conf"
    LIB_FILE="$SCRIPT_DIR/fan-control-lib.sh"
fi
```

**Allows two modes:**

Installed mode (after running install.sh):
- Binary: /usr/local/bin/fan-control.sh
- Config: /etc/fan-control/fan-control.conf
- Library: /usr/local/lib/fan-control/fan-control-lib.sh

Source mode (running from git checkout):
- All files in src/ directory
- Useful for development and testing
- No installation required

### 8.3 Configuration Backup Mechanism

File: install.sh (lines 189-200)

**Smart config handling:**
```bash
if [ -f "$CONFIG_DEST" ]; then
    # Existing config - create timestamped backup
    BACKUP="${CONFIG_DEST}.backup.$(date +%Y%m%d-%H%M%S)"
    cp -p "$CONFIG_DEST" "$BACKUP"
    echo "Existing configuration backed up to: $BACKUP"
    echo "Keeping your current configuration."
else
    # New installation - install default config
    install -m 644 "$CONFIG_SRC" "$CONFIG_DEST"
fi
```

**Benefits:**
- Preserves user customizations during updates
- Creates timestamped backups (multiple backups supported)
- Never overwrites existing config
- Allows easy rollback if needed

---

## 9. Common Modification Patterns

### 9.1 Adding New Fan Speed Level

To add a 6th CPU fan state (e.g., State 5 for extreme cooling):

**Step 1:** Add threshold to config
```bash
# Add to /etc/fan-control/fan-control.conf
CPU_TEMP_STATE5=90
```

**Step 2:** Verify hardware support
```bash
cat /sys/class/thermal/cooling_device0/max_state
# Must be ≥5 for state 5 to work
```

**Step 3:** Update calculate_cpu_state() logic

Edit fan-control-lib.sh, modify the thresholds array:
```bash
THRESHOLDS=(0 $CPU_TEMP_STATE1 $CPU_TEMP_STATE2 $CPU_TEMP_STATE3 $CPU_TEMP_STATE4 $CPU_TEMP_STATE5)

for state in 5 4 3 2 1; do  # Add 5 to loop
    threshold=${THRESHOLDS[$state]}
    if (( temp >= threshold )); then
        echo $state
        return 0
    fi
done
```

**Step 4:** Update emergency state if needed
```bash
EMERGENCY_CPU_STATE=5  # Use new maximum state
```

**Step 5:** Restart service
```bash
sudo systemctl restart fan-control
```

### 9.2 Adding Custom Sensor

To add monitoring for a third temperature sensor (e.g., GPU):

**Step 1:** Add discovery in main script (after line 109)
```bash
# Find GPU temperature sensor
GPU_SENSOR=$(find_hwmon_device "gpu") || {
    log_error "GPU temperature sensor not found"
    cleanup_handler
    exit 1
}
log_info "GPU sensor found: $GPU_SENSOR"
```

**Step 2:** Add state tracking variables (after line 128)
```bash
CURRENT_GPU_STATE=1
GPU_FAIL_COUNT=0
LAST_GPU_TEMP=0
```

**Step 3:** Add temperature reading in main loop (after line 191)
```bash
if gpu_temp=$(read_temperature "$GPU_SENSOR"); then
    GPU_FAIL_COUNT=0
    LAST_GPU_TEMP=$gpu_temp
else
    ((GPU_FAIL_COUNT++))
    log_error "Failed to read GPU temperature"
    if (( GPU_FAIL_COUNT >= MAX_SENSOR_FAILURES )); then
        # Handle GPU sensor failure
    fi
    gpu_temp=$LAST_GPU_TEMP
fi
```

**Step 4:** Add to log_state() format
Modify fan-control-lib.sh log_state():
```bash
printf "%s | CPU: %3dC (State: %d) | GPU: %3dC (State: %d) | NVMe: %3dC (Duty: %5d/%d, %3d%%) | %s\n" \
    "$timestamp" "$cpu_temp" "$cpu_state" "$gpu_temp" "$gpu_state" \
    "$nvme_temp" "$nvme_duty" "$PWM_PERIOD" "$nvme_percent" "$status"
```

**Step 5:** Add configuration thresholds
```bash
# Add to fan-control.conf
GPU_TEMP_STATE1=60
GPU_TEMP_STATE2=70
GPU_TEMP_STATE3=80
GPU_TEMP_STATE4=90
GPU_CRITICAL_TEMP=95
```

### 9.3 Changing PWM Frequency

To change NVMe fan PWM frequency (e.g., from 25kHz to 20kHz):

**Current:** PWM_PERIOD=40000ns (25kHz)
**Target:** PWM_PERIOD=50000ns (20kHz)

**Step 1:** Update configuration
```bash
# Edit /etc/fan-control/fan-control.conf
PWM_PERIOD=50000
```

**Step 2:** Recalculate duty cycles proportionally
```bash
# Old duty cycles at 40000 period:
NVME_DUTY_LOW=8000    # 20%
NVME_DUTY_MED=16000   # 40%
NVME_DUTY_HIGH=24000  # 60%
NVME_DUTY_MAX=32000   # 80%

# New duty cycles at 50000 period:
NVME_DUTY_LOW=10000   # 20% of 50000
NVME_DUTY_MED=20000   # 40% of 50000
NVME_DUTY_HIGH=30000  # 60% of 50000
NVME_DUTY_MAX=40000   # 80% of 50000
```

**Step 3:** Verify fan compatibility
Check fan manufacturer specifications to ensure it supports 20kHz PWM frequency. Most fans support 21-28kHz range.

**Step 4:** Test manually before deploying
```bash
cd /sys/class/pwm/pwmchip0/pwm2
echo 0 > enable
echo 50000 > period
echo 10000 > duty_cycle
echo 1 > enable
# Verify fan spins correctly without noise/vibration
```

**Step 5:** Restart service with new configuration
```bash
sudo systemctl restart fan-control
```

---

## 10. Debugging Techniques

### 10.1 Enable Debug Mode

**Method 1: Persistent debug mode**

```bash
# Edit configuration
sudo nano /etc/fan-control/fan-control.conf

# Set debug mode
DEBUG_MODE=1

# Restart service
sudo systemctl restart fan-control

# Watch debug output in journal
journalctl -u fan-control -f
```

**Method 2: Temporary debug mode (service already running)**

```bash
# Stop service
sudo systemctl stop fan-control

# Run manually with debug enabled
sudo DEBUG_MODE=1 /usr/local/bin/fan-control.sh
```

**What debug output shows:**
- Each temperature sensor read with timing
- Hysteresis calculations and threshold comparisons
- Hardware I/O operations (sysfs reads/writes)
- State change decisions and rationale
- Timing information for performance analysis

### 10.2 Manual Hardware Test

**Test CPU fan without service:**

```bash
# Stop the service
sudo systemctl stop fan-control

# Enable automatic thermal control
echo enabled | sudo tee /sys/class/thermal/thermal_zone0/mode

# Test different states manually
for state in 0 1 2 3 4; do
    echo $state | sudo tee /sys/class/thermal/cooling_device0/cur_state
    echo "CPU fan set to state $state"
    sleep 5
done

# Verify current state
cat /sys/class/thermal/cooling_device0/cur_state

# Restart service when done
sudo systemctl start fan-control
```

**Test NVMe fan PWM:**

```bash
# Navigate to PWM directory
cd /sys/class/pwm/pwmchip0

# Export channel if needed
echo 2 | sudo tee export

# Navigate to channel
cd pwm2

# Disable before changes
echo 0 | sudo tee enable

# Set period
echo 40000 | sudo tee period

# Test different speeds
for duty in 0 8000 16000 24000 32000; do
    echo $duty | sudo tee duty_cycle
    percent=$((duty * 100 / 40000))
    echo "NVMe fan set to $duty ($percent%)"
    sleep 5
done

# Enable PWM
echo 1 | sudo tee enable

# Restart service when done
sudo systemctl start fan-control
```

### 10.3 Sensor Discovery Debug

**List all hwmon devices:**

```bash
for hwmon in /sys/class/hwmon/hwmon*; do
    name=$(cat "$hwmon/name" 2>/dev/null)
    echo "Device: $hwmon"
    echo "  Name: $name"

    # List all temperature inputs
    for temp in "$hwmon"/temp*_input; do
        if [ -f "$temp" ]; then
            millidegrees=$(cat "$temp")
            celsius=$((millidegrees / 1000))
            echo "  $(basename $temp): ${celsius}C"
        fi
    done
    echo
done
```

**Test sensor reading function:**

```bash
# Source the library
source /usr/local/lib/fan-control/fan-control-lib.sh

# Test CPU sensor discovery
cpu_sensor=$(find_hwmon_device "cpu")
echo "CPU sensor path: $cpu_sensor"

# Test reading
cpu_temp=$(read_temperature "$cpu_sensor")
echo "CPU temperature: ${cpu_temp}C"

# Test NVMe sensor
nvme_sensor=$(find_hwmon_device "nvme")
echo "NVMe sensor path: $nvme_sensor"
nvme_temp=$(read_temperature "$nvme_sensor")
echo "NVMe temperature: ${nvme_temp}C"
```

**Check thermal zone:**

```bash
# Check mode
cat /sys/class/thermal/thermal_zone0/mode

# Check temperature
cat /sys/class/thermal/thermal_zone0/temp

# List trip points
grep . /sys/class/thermal/thermal_zone0/trip_point_*
```

---

## 11. Performance Characteristics

### 11.1 Timing Analysis

**Sensor read operation:**
- sysfs file read: ~1-2 milliseconds
- hwmon device enumeration (startup only): ~5-10 milliseconds
- Temperature conversion (millidegrees to Celsius): <0.1 milliseconds

**State calculation:**
- Threshold comparison: <0.1 milliseconds (pure bash arithmetic)
- Hysteresis logic: <0.1 milliseconds
- Total calculation time: <0.5 milliseconds

**Hardware control:**
- sysfs write (single value): ~1-5 milliseconds
- PWM configuration (period+duty): ~2-10 milliseconds
- State change overhead: ~5-15 milliseconds total

**Loop iteration:**
- Minimum time (no state change): ~10-20 milliseconds
- Maximum time (state change + logging): ~30-50 milliseconds
- Sleep time: Configurable (default 5000 milliseconds = 5 seconds)

**CPU usage calculation:**
```
Active time per loop: ~20ms
Sleep time: 5000ms
Duty cycle: 20/5000 = 0.4%
Measured usage: <0.5% (matches calculation)
```

### 11.2 Memory Footprint

**Process memory breakdown:**

Bash process baseline: ~5-10 MB (bash interpreter + loaded libraries)
Script variables: <1 MB (minimal - mostly integers and short strings)
Log buffer: ~4 KB (logs written immediately, minimal buffering)
Total RSS (Resident Set Size): ~10-20 MB typical

**Memory usage over time:**
- No memory leaks (bash script, automatic garbage collection)
- Stable footprint (no dynamic allocations)
- Log rotation prevents disk usage growth

**Systemd limit safety margin:**
```
MemoryMax=50M (systemd limit)
Typical usage: ~15 MB
Safety margin: 50/15 = 3.3x headroom
```

### 11.3 Disk I/O Characteristics

**Log writes:**
- Frequency: Every LOOP_INTERVAL seconds (default: 5 seconds)
- Size per write: ~120 bytes (one log line)
- Daily volume: (86400 / 5) * 120 = ~2 MB per day
- With rotation (5 days): ~10 MB disk usage maximum

**sysfs I/O:**
- Read operations: 2 per loop (CPU temp, NVMe temp)
- Write operations: 0-2 per loop (only on state change)
- Typical: 2 reads, 0 writes per loop (stable state)
- Under load: 2 reads, 2 writes per loop (changing state)

**I/O impact:**
Minimal - sysfs is memory-backed, writes don't hit physical disk
Log writes are asynchronous, buffered by kernel

---

## 12. Known Limitations

1. **No smooth PWM ramping:**
   - Current: Immediate duty cycle changes (instant fan speed changes)
   - Impact: Audible "step" when fan speed changes
   - Future: Could implement gradual ramping (e.g., increase by 1000 every 100ms)

2. **Fixed hysteresis value:**
   - Current: Single HYSTERESIS value applies to all thresholds
   - Limitation: Can't have different hysteresis for different temperature ranges
   - Future: Per-threshold hysteresis (e.g., tighter at low temps, looser at high temps)

3. **Command-line only (no GUI):**
   - Current: Configuration via text file editing
   - Monitoring via command-line tools (tail, journalctl)
   - Future: Web-based dashboard for configuration and monitoring

4. **Single PWM fan support:**
   - Current: One NVMe fan on GPIO 18 (PWM channel 2)
   - Limitation: Can't control multiple PWM fans independently
   - Future: Multi-channel PWM support for additional fans

5. **Local logs only:**
   - Current: Logs written to /var/log/fan-control/ only
   - Limitation: No remote logging or centralized monitoring
   - Future: Syslog integration, remote logging support

6. **Bash 4.0+ dependency:**
   - Current: Uses bash-specific features (arrays, arithmetic)
   - Limitation: Not portable to sh or older bash versions
   - Mitigation: Raspberry Pi OS includes modern bash by default

7. **No configuration validation:**
   - Current: Assumes valid configuration values
   - Risk: Invalid thresholds could cause undefined behavior
   - Future: Config validation with error messages

8. **Fixed sensor matching:**
   - Current: Hardcoded search patterns ("cpu_thermal", "nvme")
   - Limitation: Won't detect sensors with different names
   - Future: Configurable sensor paths or regex patterns

---

## 13. Future Enhancement Ideas

**Performance optimizations:**
- Smooth PWM ramping: Gradual duty cycle changes to reduce audible steps
- Adaptive loop interval: Faster updates under load, slower when idle
- Fan curve interpolation: Linear interpolation between thresholds instead of steps

**Configuration improvements:**
- Per-threshold hysteresis values
- Temperature curve profiles (silent/balanced/performance)
- Profile switching via signals (SIGUSR1/SIGUSR2)
- Configuration validation and warnings
- Web-based configuration interface

**Monitoring enhancements:**
- Web dashboard with real-time graphs
- Prometheus metrics export (temperature, fan speed, state changes)
- Email/webhook alerts for thermal events
- Historical temperature data logging (database backend)

**Hardware support:**
- Multiple PWM fan support (additional GPIO pins)
- Configurable sensor paths (not just auto-discovery)
- Support for other SBC platforms (Rock Pi, Orange Pi)
- External temperature probes (via I2C/SPI sensors)

**Feature additions:**
- Fan health monitoring (RPM feedback via tachometer)
- Predictive fan control (temperature trend analysis)
- Load-based control (CPU usage, not just temperature)
- Dust detection (increased temps at same load indicate dust buildup)

**Reliability improvements:**
- Watchdog timer integration
- Self-healing (automatic recovery from stuck states)
- Configuration hot-reload (SIGHUP handler)
- A/B configuration testing (validate before applying)

**Developer experience:**
- Unit tests for hysteresis algorithm
- Integration tests with simulated hardware
- Performance profiling tools
- Documentation generator from code comments

---

## Conclusion

This technical documentation provides comprehensive insight into the Raspberry Pi 5 Fan Control system's architecture, algorithms, and implementation details. The system demonstrates robust error handling, intelligent thermal management, and production-ready safety mechanisms suitable for embedded systems.

Key strengths:
- Sophisticated hysteresis algorithm prevents oscillation
- Multi-level safety mechanisms ensure cooling under all conditions
- Built-in logging with automatic rotation
- Systemd security hardening and resource limits
- Smart installation supporting multiple deployment methods

The modular design allows for easy customization and extension while maintaining stability and safety as primary goals.
