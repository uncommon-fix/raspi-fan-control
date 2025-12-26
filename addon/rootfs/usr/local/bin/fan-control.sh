#!/usr/bin/env bash
# Raspberry Pi 5 Fan Control Daemon
# Monitors CPU and NVMe temperatures and controls fans accordingly
#
# This script should be run as a systemd service with root privileges.
# It provides automatic fan control with hysteresis to prevent oscillation.
#
# HAOS Add-on Mode: When HAOS_MODE=1, uses container paths and stdout logging

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

# Determine installation paths
# MODIFICATION A: Added HAOS mode detection
if [[ "${HAOS_MODE:-0}" == "1" ]]; then
    # HAOS add-on mode - use container paths
    CONFIG_FILE="${CONFIG_FILE:-/tmp/fan-control-runtime.conf}"
    LIB_FILE="/usr/local/bin/fan-control-lib.sh"
elif [[ -f "/etc/fan-control/fan-control.conf" ]]; then
    # Installed configuration
    CONFIG_FILE="/etc/fan-control/fan-control.conf"
    LIB_FILE="/usr/local/lib/fan-control/fan-control-lib.sh"
else
    # Running from source directory
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CONFIG_FILE="$SCRIPT_DIR/fan-control.conf"
    LIB_FILE="$SCRIPT_DIR/fan-control-lib.sh"
fi

# Source configuration
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
    exit 1
fi
source "$CONFIG_FILE"

# Source library functions
if [[ ! -f "$LIB_FILE" ]]; then
    echo "ERROR: Library file not found: $LIB_FILE" >&2
    exit 1
fi
source "$LIB_FILE"

# ============================================================================
# ROOT PERMISSION CHECK
# ============================================================================

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root" >&2
    echo "Try: sudo $0" >&2
    exit 1
fi

# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

# Register cleanup handler for graceful shutdown
trap cleanup_handler SIGTERM SIGINT EXIT

# ============================================================================
# INITIALIZATION
# ============================================================================

echo "Starting Raspberry Pi 5 Fan Control Daemon..."

# Setup logging
setup_logging || {
    echo "ERROR: Failed to setup logging" >&2
    exit 1
}

log_info "=========================================="
log_info "Fan Control Daemon Starting"
log_info "=========================================="
log_info "Configuration: $CONFIG_FILE"
log_info "Library: $LIB_FILE"

# Check permissions
check_permissions || exit 1

# Disable automatic thermal control to allow manual fan control
disable_auto_thermal || exit 1

# Initialize NVMe PWM
init_nvme_pwm || exit 1

# Initialize CPU fan
init_cpu_fan || exit 1

# ============================================================================
# STARTUP TEST - Spin fans to verify operation
# ============================================================================

# MODIFICATION B: Made startup test configurable
if [[ "${STARTUP_TEST_ENABLED:-1}" == "1" ]]; then
    log_info "Running 30-second startup test..."
    log_info "Fans will spin at high speed to verify system is working"

    # Set CPU fan to high speed (state 3)
    set_cpu_fan_state 3 || log_error "Failed to set CPU fan for startup test"

    # Set NVMe fan to 80% duty cycle for visibility
    STARTUP_NVME_DUTY=$((PWM_PERIOD * 80 / 100))
    set_nvme_fan_duty "$STARTUP_NVME_DUTY" || log_error "Failed to set NVMe fan for startup test"

    log_info "Startup test running... (30 seconds)"
    sleep 30

    log_info "Startup test complete - switching to temperature-based control"
else
    log_info "Startup test disabled - skipping"
fi

# ============================================================================
# SENSOR DISCOVERY
# ============================================================================

log_info "Discovering temperature sensors..."

# Find CPU temperature sensor
CPU_SENSOR=$(find_hwmon_device "cpu") || {
    log_error "CPU temperature sensor not found"
    cleanup_handler
    exit 1
}
log_info "CPU sensor found: $CPU_SENSOR"

# MODIFICATION C: Made NVMe sensor optional
# Find NVMe temperature sensor (optional for systems without NVMe)
if NVME_SENSOR=$(find_hwmon_device "nvme"); then
    log_info "NVMe sensor found: $NVME_SENSOR"
    NVME_CONTROL_ENABLED=1
else
    log_info "NVMe temperature sensor not found - NVMe fan control disabled"
    log_info "This is normal if no NVMe drive is installed"
    NVME_CONTROL_ENABLED=0
fi

# ============================================================================
# STATE TRACKING VARIABLES
# ============================================================================

# Current fan states
CURRENT_CPU_STATE=1              # Start at low speed
CURRENT_NVME_DUTY=$NVME_DUTY_LOW # Start at 20%

# Sensor failure counters
CPU_FAIL_COUNT=0
NVME_FAIL_COUNT=0

# Last known good temperatures (for fallback)
LAST_CPU_TEMP=0
LAST_NVME_TEMP=0

# Emergency mode flag
EMERGENCY_MODE=0

# ============================================================================
# MAIN CONTROL LOOP
# ============================================================================

log_info "Entering main control loop (interval: ${LOOP_INTERVAL}s)"
log_info "Temperature thresholds - CPU: ${CPU_TEMP_STATE1}/${CPU_TEMP_STATE2}/${CPU_TEMP_STATE3}/${CPU_TEMP_STATE4}C, NVMe: ${NVME_TEMP_LEVEL1}/${NVME_TEMP_LEVEL2}/${NVME_TEMP_LEVEL3}/${NVME_TEMP_LEVEL4}C"
log_info "Hysteresis: ${HYSTERESIS}C"

while true; do
    # ========================================================================
    # READ TEMPERATURES
    # ========================================================================

    # Read CPU temperature
    if cpu_temp=$(read_temperature "$CPU_SENSOR"); then
        # Success - reset failure counter
        CPU_FAIL_COUNT=0
        LAST_CPU_TEMP=$cpu_temp
    else
        # Failed to read temperature
        ((CPU_FAIL_COUNT++))
        log_error "Failed to read CPU temperature (failure $CPU_FAIL_COUNT/$MAX_SENSOR_FAILURES)"

        if (( CPU_FAIL_COUNT >= MAX_SENSOR_FAILURES )); then
            # Too many failures - enter emergency mode
            if (( EMERGENCY_MODE == 0 )); then
                log_error "CPU sensor failures exceeded threshold - ENTERING EMERGENCY MODE"
                set_cpu_fan_state "$EMERGENCY_CPU_STATE"
                EMERGENCY_MODE=1
            fi
            cpu_temp=999  # Use high dummy value to keep emergency mode active
        else
            # Use last known temperature
            cpu_temp=$LAST_CPU_TEMP
            log_debug "Using last known CPU temperature: ${cpu_temp}C"
        fi
    fi

    # MODIFICATION D: Conditional NVMe temperature reading
    # Read NVMe temperature (only if NVMe control is enabled)
    if (( NVME_CONTROL_ENABLED == 1 )); then
        if nvme_temp=$(read_temperature "$NVME_SENSOR"); then
            # Success - reset failure counter
            NVME_FAIL_COUNT=0
            LAST_NVME_TEMP=$nvme_temp
        else
            # Failed to read temperature
            ((NVME_FAIL_COUNT++))
            log_error "Failed to read NVMe temperature (failure $NVME_FAIL_COUNT/$MAX_SENSOR_FAILURES)"

            if (( NVME_FAIL_COUNT >= MAX_SENSOR_FAILURES )); then
                # Too many failures - enter emergency mode
                if (( EMERGENCY_MODE == 0 )); then
                    log_error "NVMe sensor failures exceeded threshold - ENTERING EMERGENCY MODE"
                    set_nvme_fan_duty "$EMERGENCY_NVME_DUTY"
                    EMERGENCY_MODE=1
                fi
                nvme_temp=999  # Use high dummy value to keep emergency mode active
            else
                # Use last known temperature
                nvme_temp=$LAST_NVME_TEMP
                log_debug "Using last known NVMe temperature: ${nvme_temp}C"
            fi
        fi
    else
        # No NVMe sensor - use safe default
        nvme_temp=0
        new_nvme_duty=$NVME_DUTY_OFF
    fi

    # ========================================================================
    # SAFETY CHECK - THERMAL RUNAWAY PROTECTION
    # ========================================================================

    if ! check_thermal_runaway "$cpu_temp" "$nvme_temp"; then
        # Critical temperature detected - emergency cooling activated
        # Skip normal control logic and continue monitoring
        EMERGENCY_MODE=1
        log_state "$cpu_temp" "$EMERGENCY_CPU_STATE" "$nvme_temp" "$EMERGENCY_NVME_DUTY" "THERMAL_RUNAWAY"
        sleep "$LOOP_INTERVAL"
        continue
    fi

    # ========================================================================
    # CALCULATE NEW FAN STATES (with hysteresis)
    # ========================================================================

    # Calculate CPU fan state
    new_cpu_state=$(calculate_cpu_state "$cpu_temp" "$CURRENT_CPU_STATE")

    # Calculate NVMe fan duty cycle (only if NVMe control enabled)
    if (( NVME_CONTROL_ENABLED == 1 )); then
        new_nvme_duty=$(calculate_nvme_duty "$nvme_temp" "$CURRENT_NVME_DUTY")
    fi

    # ========================================================================
    # APPLY FAN CONTROLS (only if changed)
    # ========================================================================

    # Update CPU fan if state changed
    if [[ $new_cpu_state != $CURRENT_CPU_STATE ]]; then
        if set_cpu_fan_state "$new_cpu_state"; then
            log_info "CPU fan state changed: $CURRENT_CPU_STATE -> $new_cpu_state (temp: ${cpu_temp}C)"
            CURRENT_CPU_STATE=$new_cpu_state
        else
            log_error "Failed to set CPU fan state to $new_cpu_state"
        fi
    fi

    # MODIFICATION D: Conditional NVMe fan control
    # Update NVMe fan if duty cycle changed (only if NVMe control enabled)
    if (( NVME_CONTROL_ENABLED == 1 )); then
        if [[ $new_nvme_duty != $CURRENT_NVME_DUTY ]]; then
            if set_nvme_fan_duty "$new_nvme_duty"; then
                old_percent=$((CURRENT_NVME_DUTY * 100 / PWM_PERIOD))
                new_percent=$((new_nvme_duty * 100 / PWM_PERIOD))
                log_info "NVMe fan duty changed: $CURRENT_NVME_DUTY (${old_percent}%) -> $new_nvme_duty (${new_percent}%) (temp: ${nvme_temp}C)"
                CURRENT_NVME_DUTY=$new_nvme_duty
            else
                log_error "Failed to set NVMe fan duty to $new_nvme_duty"
            fi
        fi
    fi

    # ========================================================================
    # LOG CURRENT STATE
    # ========================================================================

    # Determine status message
    status="OK"
    if (( EMERGENCY_MODE == 1 )); then
        status="EMERGENCY"
    elif (( CPU_FAIL_COUNT > 0 )) || (( NVME_FAIL_COUNT > 0 )); then
        status="SENSOR_ERROR"
    fi

    log_state "$cpu_temp" "$CURRENT_CPU_STATE" "$nvme_temp" "$CURRENT_NVME_DUTY" "$status"

    # ========================================================================
    # SLEEP BEFORE NEXT ITERATION
    # ========================================================================

    sleep "$LOOP_INTERVAL"
done
