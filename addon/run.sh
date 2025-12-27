#!/usr/bin/env bash
set -euo pipefail

OPTIONS_FILE="/data/options.json"
RUNTIME_CONF="/tmp/fan-control-runtime.conf"

echo "========================================="
echo "Raspberry Pi 5 Fan Control - HAOS Add-on"
echo "========================================="
echo ""

# Verify hardware paths exist
echo "Verifying hardware access..."

if [[ ! -d /sys/class/pwm/pwmchip0 ]]; then
    echo ""
    echo "ERROR: PWM chip not found at /sys/class/pwm/pwmchip0"
    echo ""
    echo "SOLUTION: Configure device tree overlay"
    echo "1. SSH to Home Assistant OS (not this container):"
    echo "   ssh root@homeassistant.local"
    echo "2. Edit /mnt/boot/config.txt"
    echo "3. Add line: dtoverlay=pwm-2chan,pin=18,func=2"
    echo "4. Reboot system"
    echo "5. Restart this add-on"
    echo ""
    echo "Enabling kernel thermal control for safety..."
    echo "enabled" > /sys/class/thermal/thermal_zone0/mode 2>/dev/null || true
    exit 1
fi

if [[ ! -d /sys/class/thermal/thermal_zone0 ]]; then
    echo "ERROR: Thermal zone not found"
    exit 1
fi

if [[ ! -d /sys/class/thermal/cooling_device0 ]]; then
    echo "ERROR: CPU cooling device not found"
    exit 1
fi

echo "✓ PWM chip found"
echo "✓ Thermal zone found"
echo "✓ CPU cooling device found"
echo ""

# ============================================================
# DIAGNOSTIC: Test hardware write access
# ============================================================
echo "========================================="
echo "DIAGNOSTIC: Testing Hardware Access"
echo "========================================="
echo ""

echo "--- Checking /sys mount status ---"
mount | grep "/sys " || echo "Could not find /sys mount info"
echo ""

echo "--- Testing /sys/class/pwm write access ---"
if [ -w /sys/class/pwm/pwmchip0/export ]; then
    echo "✓ PWM export is WRITABLE"
else
    echo "✗ PWM export is NOT writable (read-only or no permission)"
    ls -la /sys/class/pwm/pwmchip0/export 2>&1 || echo "  File does not exist"
fi
echo ""

echo "--- Testing /sys/class/thermal write access ---"
if [ -w /sys/class/thermal/thermal_zone0/mode ]; then
    echo "✓ Thermal zone mode is WRITABLE"
else
    echo "✗ Thermal zone mode is NOT writable (read-only or no permission)"
    ls -la /sys/class/thermal/thermal_zone0/mode 2>&1 || echo "  File does not exist"
fi

if [ -w /sys/class/thermal/cooling_device0/cur_state ]; then
    echo "✓ CPU cooling device is WRITABLE"
else
    echo "✗ CPU cooling device is NOT writable (read-only or no permission)"
    ls -la /sys/class/thermal/cooling_device0/cur_state 2>&1 || echo "  File does not exist"
fi
echo ""

echo "--- Checking for alternative hardware access methods ---"
if [ -e /dev/mem ]; then
    echo "✓ /dev/mem exists"
    ls -la /dev/mem
    if [ -w /dev/mem ]; then
        echo "  → /dev/mem is WRITABLE"
    else
        echo "  → /dev/mem is NOT writable"
    fi
else
    echo "✗ /dev/mem does not exist"
fi

if ls /dev/gpiochip* 2>/dev/null; then
    echo "✓ GPIO chip devices found:"
    ls -la /dev/gpiochip* 2>/dev/null
else
    echo "✗ No /dev/gpiochip* devices found"
fi

if [ -e /dev/gpiomem ]; then
    echo "✓ /dev/gpiomem exists"
    ls -la /dev/gpiomem
else
    echo "✗ /dev/gpiomem does not exist"
fi
echo ""

echo "--- Current user and capabilities ---"
echo "User: $(whoami) (UID: $(id -u), GID: $(id -g))"
echo "Groups: $(groups)"
if command -v capsh >/dev/null 2>&1; then
    echo "Capabilities: $(capsh --print | grep Current || echo 'capsh available but no caps info')"
else
    echo "Capabilities: capsh not available, cannot check"
fi
echo ""

echo "========================================="
echo "END DIAGNOSTIC"
echo "========================================="
echo ""

# Parse HAOS options using jq
echo "Loading configuration..."

CPU_STATE1=$(jq -r '.cpu_temp_thresholds.state1' "$OPTIONS_FILE")
CPU_STATE2=$(jq -r '.cpu_temp_thresholds.state2' "$OPTIONS_FILE")
CPU_STATE3=$(jq -r '.cpu_temp_thresholds.state3' "$OPTIONS_FILE")
CPU_STATE4=$(jq -r '.cpu_temp_thresholds.state4' "$OPTIONS_FILE")

NVME_LEVEL1=$(jq -r '.nvme_temp_thresholds.level1' "$OPTIONS_FILE")
NVME_LEVEL2=$(jq -r '.nvme_temp_thresholds.level2' "$OPTIONS_FILE")
NVME_LEVEL3=$(jq -r '.nvme_temp_thresholds.level3' "$OPTIONS_FILE")
NVME_LEVEL4=$(jq -r '.nvme_temp_thresholds.level4' "$OPTIONS_FILE")

HYSTERESIS=$(jq -r '.hysteresis' "$OPTIONS_FILE")
LOOP_INTERVAL=$(jq -r '.loop_interval' "$OPTIONS_FILE")
DEBUG_MODE=$(jq -r '.debug_mode' "$OPTIONS_FILE")
STARTUP_TEST=$(jq -r '.startup_test_enabled' "$OPTIONS_FILE")

# Validate ascending order
if (( CPU_STATE1 >= CPU_STATE2 )) || \
   (( CPU_STATE2 >= CPU_STATE3 )) || \
   (( CPU_STATE3 >= CPU_STATE4 )); then
    echo "ERROR: CPU thresholds must be in ascending order"
    echo "  State 1: ${CPU_STATE1}°C"
    echo "  State 2: ${CPU_STATE2}°C"
    echo "  State 3: ${CPU_STATE3}°C"
    echo "  State 4: ${CPU_STATE4}°C"
    exit 1
fi

if (( NVME_LEVEL1 >= NVME_LEVEL2 )) || \
   (( NVME_LEVEL2 >= NVME_LEVEL3 )) || \
   (( NVME_LEVEL3 >= NVME_LEVEL4 )); then
    echo "ERROR: NVMe thresholds must be in ascending order"
    echo "  Level 1: ${NVME_LEVEL1}°C"
    echo "  Level 2: ${NVME_LEVEL2}°C"
    echo "  Level 3: ${NVME_LEVEL3}°C"
    echo "  Level 4: ${NVME_LEVEL4}°C"
    exit 1
fi

echo "✓ Configuration validated"
echo ""

# Generate runtime configuration
cat > "$RUNTIME_CONF" <<EOF
# Auto-generated from HAOS add-on options
# Changes will be overwritten on add-on restart
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# Temperature Thresholds
CPU_TEMP_STATE1=$CPU_STATE1
CPU_TEMP_STATE2=$CPU_STATE2
CPU_TEMP_STATE3=$CPU_STATE3
CPU_TEMP_STATE4=$CPU_STATE4

NVME_TEMP_LEVEL1=$NVME_LEVEL1
NVME_TEMP_LEVEL2=$NVME_LEVEL2
NVME_TEMP_LEVEL3=$NVME_LEVEL3
NVME_TEMP_LEVEL4=$NVME_LEVEL4

HYSTERESIS=$HYSTERESIS

# PWM Configuration (fixed for 25kHz)
PWM_PERIOD=40000
NVME_DUTY_OFF=0
NVME_DUTY_LOW=8000
NVME_DUTY_MED=16000
NVME_DUTY_HIGH=24000
NVME_DUTY_MAX=32000

# Timing
LOOP_INTERVAL=$LOOP_INTERVAL

# Logging (HAOS mode - stdout)
LOG_DIR="/tmp"
LOG_RETENTION_DAYS=0
DEBUG_MODE=$([[ "$DEBUG_MODE" == "true" ]] && echo "1" || echo "0")

# Hardware Paths
PWM_CHIP="/sys/class/pwm/pwmchip0"
PWM_CHANNEL=2
CPU_COOLING_DEVICE="/sys/class/thermal/cooling_device0"
THERMAL_ZONE="/sys/class/thermal/thermal_zone0"

# Safety Settings
MAX_SENSOR_FAILURES=3
EMERGENCY_CPU_STATE=4
EMERGENCY_NVME_DUTY=32000
CPU_CRITICAL_TEMP=90
NVME_CRITICAL_TEMP=85
SAFE_CPU_STATE=2
SAFE_NVME_DUTY=16000

# Startup test
STARTUP_TEST_ENABLED=$([[ "$STARTUP_TEST" == "true" ]] && echo "1" || echo "0")
EOF

echo "Configuration generated:"
echo "  CPU thresholds: ${CPU_STATE1}°C / ${CPU_STATE2}°C / ${CPU_STATE3}°C / ${CPU_STATE4}°C"
echo "  NVMe thresholds: ${NVME_LEVEL1}°C / ${NVME_LEVEL2}°C / ${NVME_LEVEL3}°C / ${NVME_LEVEL4}°C"
echo "  Hysteresis: ${HYSTERESIS}°C"
echo "  Loop interval: ${LOOP_INTERVAL}s"
echo "  Debug mode: ${DEBUG_MODE}"
echo "  Startup test: ${STARTUP_TEST}"
echo ""

# Export environment for daemon
export HAOS_MODE=1
export CONFIG_FILE="$RUNTIME_CONF"

echo "Starting fan control daemon..."
echo "========================================="
echo ""

# Execute daemon
exec /usr/local/bin/fan-control.sh
