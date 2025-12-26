#!/usr/bin/env bash
# Fan Control Library Functions
# Raspberry Pi 5 Fan Control System
#
# This library provides reusable functions for temperature monitoring,
# fan control, logging, and safety mechanisms.

# ============================================================================
# GLOBAL STATE VARIABLES
# ============================================================================

# Current log file tracking
CURRENT_LOG_DATE=""
CURRENT_LOG_FILE=""

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

# setup_logging: Create log directory if it doesn't exist
setup_logging() {
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || {
            echo "ERROR: Cannot create log directory $LOG_DIR" >&2
            return 1
        }
    fi

    chmod 755 "$LOG_DIR" 2>/dev/null
    return 0
}

# get_log_file: Get current log file path, create new file if date changed
# Implements daily log rotation
get_log_file() {
    local today=$(date +%Y-%m-%d)

    # Check if we need a new log file
    if [[ "$today" != "$CURRENT_LOG_DATE" ]]; then
        CURRENT_LOG_DATE="$today"
        CURRENT_LOG_FILE="$LOG_DIR/fan-control-${today}.log"

        # Create new log file with header
        {
            echo "=========================================="
            echo "Fan Control Log - Started: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "=========================================="
        } >> "$CURRENT_LOG_FILE" 2>/dev/null

        # Rotate old logs
        rotate_logs
    fi

    echo "$CURRENT_LOG_FILE"
}

# rotate_logs: Delete log files older than retention period
rotate_logs() {
    if [[ -d "$LOG_DIR" ]]; then
        find "$LOG_DIR" -name "fan-control-*.log" -type f -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null
    fi
}

# log_state: Log current system state (temperatures and fan speeds)
# Arguments: cpu_temp cpu_state nvme_temp nvme_duty status_message
log_state() {
    local cpu_temp=$1
    local cpu_state=$2
    local nvme_temp=$3
    local nvme_duty=$4
    local status=$5

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local nvme_percent=$((nvme_duty * 100 / PWM_PERIOD))
    local logfile=$(get_log_file)

    printf "%s | CPU: %3dC (State: %d) | NVMe: %3dC (Duty: %5d/%d, %3d%%) | %s\n" \
        "$timestamp" "$cpu_temp" "$cpu_state" "$nvme_temp" "$nvme_duty" "$PWM_PERIOD" "$nvme_percent" "$status" \
        >> "$logfile" 2>/dev/null
}

# log_info: Log informational message
log_info() {
    local message=$1
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local logfile=$(get_log_file)

    echo "$timestamp | INFO: $message" >> "$logfile" 2>/dev/null

    if [[ "$DEBUG_MODE" == "1" ]]; then
        echo "$timestamp | INFO: $message" >&2
    fi
}

# log_error: Log error message (to both file and stderr)
log_error() {
    local message=$1
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local logfile=$(get_log_file)

    echo "$timestamp | ERROR: $message" >> "$logfile" 2>/dev/null
    echo "$timestamp | ERROR: $message" >&2
}

# log_debug: Log debug message (only if DEBUG_MODE is enabled)
log_debug() {
    if [[ "$DEBUG_MODE" == "1" ]]; then
        local message=$1
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        local logfile=$(get_log_file)

        echo "$timestamp | DEBUG: $message" >> "$logfile" 2>/dev/null
        echo "$timestamp | DEBUG: $message" >&2
    fi
}

# ============================================================================
# TEMPERATURE READING FUNCTIONS
# ============================================================================

# find_hwmon_device: Find hwmon device by type (cpu or nvme)
# Returns path to temp1_input file
# Arguments: device_type ("cpu" or "nvme")
find_hwmon_device() {
    local device_type=$1

    for hwmon in /sys/class/hwmon/hwmon*; do
        if [[ ! -f "$hwmon/name" ]]; then
            continue
        fi

        local name=$(cat "$hwmon/name" 2>/dev/null)

        case "$device_type" in
            cpu)
                # Look for CPU thermal sensor
                if [[ "$name" =~ (cpu_thermal|thermal_zone) ]]; then
                    if [[ -f "$hwmon/temp1_input" ]]; then
                        echo "$hwmon/temp1_input"
                        return 0
                    fi
                fi
                ;;
            nvme)
                # Look for NVMe sensor
                if [[ "$name" =~ nvme ]]; then
                    if [[ -f "$hwmon/temp1_input" ]]; then
                        echo "$hwmon/temp1_input"
                        return 0
                    fi
                fi
                ;;
        esac
    done

    return 1
}

# read_temperature: Read temperature from sensor path
# Converts from millidegrees to degrees Celsius
# Arguments: sensor_path
# Returns: temperature in Celsius
read_temperature() {
    local sensor_path=$1

    # Check if sensor is readable
    if [[ ! -r "$sensor_path" ]]; then
        log_debug "Sensor not readable: $sensor_path"
        return 1
    fi

    # Read raw temperature value
    local temp_raw=$(cat "$sensor_path" 2>/dev/null)
    local read_status=$?

    if [[ $read_status -ne 0 ]]; then
        log_debug "Failed to read sensor: $sensor_path"
        return 1
    fi

    # Validate it's a number
    if [[ ! "$temp_raw" =~ ^[0-9]+$ ]]; then
        log_debug "Invalid temperature value: $temp_raw from $sensor_path"
        return 1
    fi

    # Convert millidegrees to degrees Celsius
    local temp_celsius=$((temp_raw / 1000))

    echo "$temp_celsius"
    return 0
}

# ============================================================================
# HARDWARE INITIALIZATION FUNCTIONS
# ============================================================================

# init_nvme_pwm: Initialize PWM for NVMe fan control
# Exports PWM channel, sets period, enables PWM, sets initial duty cycle
init_nvme_pwm() {
    local pwm_path="$PWM_CHIP/pwm$PWM_CHANNEL"

    log_info "Initializing NVMe PWM..."

    # Check if already exported
    if [[ -d "$pwm_path" ]]; then
        log_info "PWM channel already exported, reusing existing"
    else
        # Try to export PWM channel
        echo "$PWM_CHANNEL" > "$PWM_CHIP/export" 2>/dev/null || {
            log_error "Failed to export PWM channel $PWM_CHANNEL"
            return 1
        }

        # Wait for sysfs to populate
        sleep 0.5
    fi

    # Verify PWM path exists
    if [[ ! -d "$pwm_path" ]]; then
        log_error "PWM path does not exist after export: $pwm_path"
        return 1
    fi

    # Disable PWM before configuration
    echo 0 > "$pwm_path/enable" 2>/dev/null

    # Set PWM period
    echo "$PWM_PERIOD" > "$pwm_path/period" 2>/dev/null || {
        log_error "Failed to set PWM period to $PWM_PERIOD"
        return 1
    }

    # Set initial safe duty cycle (20%)
    echo "$NVME_DUTY_LOW" > "$pwm_path/duty_cycle" 2>/dev/null || {
        log_error "Failed to set initial duty cycle"
        return 1
    }

    # Enable PWM
    echo 1 > "$pwm_path/enable" 2>/dev/null || {
        log_error "Failed to enable PWM"
        return 1
    }

    log_info "NVMe PWM initialized successfully (period: $PWM_PERIOD, initial duty: $NVME_DUTY_LOW)"
    return 0
}

# init_cpu_fan: Verify CPU cooling device exists and is accessible
init_cpu_fan() {
    log_info "Checking CPU cooling device..."

    if [[ ! -d "$CPU_COOLING_DEVICE" ]]; then
        log_error "CPU cooling device not found: $CPU_COOLING_DEVICE"
        return 1
    fi

    if [[ ! -w "$CPU_COOLING_DEVICE/cur_state" ]]; then
        log_error "Cannot write to CPU cooling device: $CPU_COOLING_DEVICE/cur_state"
        return 1
    fi

    log_info "CPU cooling device verified: $CPU_COOLING_DEVICE"
    return 0
}

# disable_auto_thermal: Disable automatic thermal control
# This allows manual fan control without interference from kernel
disable_auto_thermal() {
    log_info "Disabling automatic thermal control..."

    if [[ ! -f "$THERMAL_ZONE/mode" ]]; then
        log_error "Thermal zone mode file not found: $THERMAL_ZONE/mode"
        return 1
    fi

    echo "disabled" > "$THERMAL_ZONE/mode" 2>/dev/null || {
        log_error "Failed to disable automatic thermal control"
        return 1
    }

    log_info "Automatic thermal control disabled"
    return 0
}

# enable_auto_thermal: Re-enable automatic thermal control
# Called during cleanup to restore kernel control
enable_auto_thermal() {
    log_info "Re-enabling automatic thermal control..."

    if [[ ! -f "$THERMAL_ZONE/mode" ]]; then
        log_error "Thermal zone mode file not found: $THERMAL_ZONE/mode"
        return 1
    fi

    echo "enabled" > "$THERMAL_ZONE/mode" 2>/dev/null || {
        log_error "Failed to enable automatic thermal control"
        return 1
    }

    log_info "Automatic thermal control re-enabled"
    return 0
}

# ============================================================================
# FAN CONTROL FUNCTIONS
# ============================================================================

# set_nvme_fan_duty: Set NVMe fan duty cycle
# Arguments: duty_cycle (0-40000)
set_nvme_fan_duty() {
    local duty=$1
    local duty_cycle_path="$PWM_CHIP/pwm$PWM_CHANNEL/duty_cycle"

    if [[ ! -w "$duty_cycle_path" ]]; then
        log_error "Cannot write to NVMe PWM duty_cycle: $duty_cycle_path"
        return 1
    fi

    echo "$duty" > "$duty_cycle_path" 2>/dev/null || {
        log_error "Failed to set NVMe fan duty to $duty"
        return 1
    }

    log_debug "NVMe fan duty set to $duty"
    return 0
}

# set_cpu_fan_state: Set CPU fan cooling state
# Arguments: state (0-4)
set_cpu_fan_state() {
    local state=$1
    local cur_state_path="$CPU_COOLING_DEVICE/cur_state"

    if [[ ! -w "$cur_state_path" ]]; then
        log_error "Cannot write to CPU cooling device: $cur_state_path"
        return 1
    fi

    echo "$state" > "$cur_state_path" 2>/dev/null || {
        log_error "Failed to set CPU fan state to $state"
        return 1
    }

    log_debug "CPU fan state set to $state"
    return 0
}

# ============================================================================
# CONTROL LOGIC FUNCTIONS (with Hysteresis)
# ============================================================================

# calculate_cpu_state: Calculate CPU fan state with hysteresis
# Arguments: current_temp current_state
# Returns: new_state
calculate_cpu_state() {
    local temp=$1
    local current=$2
    local target=$current

    # Determine target state based on temperature
    if (( temp >= CPU_TEMP_STATE4 )); then
        target=4
    elif (( temp >= CPU_TEMP_STATE3 )); then
        target=3
    elif (( temp >= CPU_TEMP_STATE2 )); then
        target=2
    elif (( temp >= CPU_TEMP_STATE1 )); then
        target=1
    else
        target=0
    fi

    # Apply hysteresis when decreasing speed
    if (( target < current )); then
        # Find the threshold for current state
        local threshold
        case $current in
            4) threshold=$CPU_TEMP_STATE4 ;;
            3) threshold=$CPU_TEMP_STATE3 ;;
            2) threshold=$CPU_TEMP_STATE2 ;;
            1) threshold=$CPU_TEMP_STATE1 ;;
            *) threshold=0 ;;
        esac

        # Only decrease if temperature is HYSTERESIS degrees below threshold
        if (( temp > (threshold - HYSTERESIS) )); then
            target=$current  # Keep current state
            log_debug "CPU hysteresis active: temp=$temp, threshold=$threshold, staying at state $current"
        fi
    fi

    echo "$target"
}

# calculate_nvme_duty: Calculate NVMe fan duty cycle with hysteresis
# Arguments: current_temp current_duty
# Returns: new_duty
calculate_nvme_duty() {
    local temp=$1
    local current=$2
    local target=$current

    # Determine target duty cycle based on temperature
    if (( temp >= NVME_TEMP_LEVEL4 )); then
        target=$NVME_DUTY_MAX
    elif (( temp >= NVME_TEMP_LEVEL3 )); then
        target=$NVME_DUTY_HIGH
    elif (( temp >= NVME_TEMP_LEVEL2 )); then
        target=$NVME_DUTY_MED
    elif (( temp >= NVME_TEMP_LEVEL1 )); then
        target=$NVME_DUTY_LOW
    else
        target=$NVME_DUTY_OFF
    fi

    # Apply hysteresis when decreasing speed
    if (( target < current )); then
        # Find the threshold for current duty cycle
        local threshold
        case $current in
            $NVME_DUTY_MAX)  threshold=$NVME_TEMP_LEVEL4 ;;
            $NVME_DUTY_HIGH) threshold=$NVME_TEMP_LEVEL3 ;;
            $NVME_DUTY_MED)  threshold=$NVME_TEMP_LEVEL2 ;;
            $NVME_DUTY_LOW)  threshold=$NVME_TEMP_LEVEL1 ;;
            *) threshold=0 ;;
        esac

        # Only decrease if temperature is HYSTERESIS degrees below threshold
        if (( temp > (threshold - HYSTERESIS) )); then
            target=$current  # Keep current duty
            log_debug "NVMe hysteresis active: temp=$temp, threshold=$threshold, staying at duty $current"
        fi
    fi

    echo "$target"
}

# ============================================================================
# SAFETY FUNCTIONS
# ============================================================================

# check_thermal_runaway: Check for dangerous temperatures and activate emergency cooling
# Arguments: cpu_temp nvme_temp
# Returns: 0 if OK, 1 if critical
check_thermal_runaway() {
    local cpu_temp=$1
    local nvme_temp=$2

    # Check if either temperature exceeds critical threshold
    if (( cpu_temp > CPU_CRITICAL_TEMP )) || (( nvme_temp > NVME_CRITICAL_TEMP )); then
        log_error "CRITICAL TEMPERATURE ALERT! CPU: ${cpu_temp}C (critical: ${CPU_CRITICAL_TEMP}C), NVMe: ${nvme_temp}C (critical: ${NVME_CRITICAL_TEMP}C)"

        # Force maximum cooling
        set_cpu_fan_state "$EMERGENCY_CPU_STATE"
        set_nvme_fan_duty "$EMERGENCY_NVME_DUTY"

        # Re-enable automatic thermal control as additional safety measure
        enable_auto_thermal

        log_error "Emergency cooling activated - fans at maximum speed, automatic thermal control re-enabled"

        return 1
    fi

    return 0
}

# cleanup_handler: Cleanup function called on script exit
# Restores system to safe state
cleanup_handler() {
    log_info "Fan control service shutting down..."

    # Set CPU fan to safe default speed
    log_info "Setting CPU fan to safe default speed..."
    set_cpu_fan_state "$SAFE_CPU_STATE" 2>/dev/null

    # Turn off NVMe fan before PWM disable/unexport to prevent spinning on shutdown
    log_info "Turning off NVMe fan..."
    set_nvme_fan_duty 0 2>/dev/null

    # Brief delay to ensure PWM state change takes effect
    sleep 0.2

    # Re-enable automatic thermal control
    log_info "Re-enabling automatic thermal control..."
    enable_auto_thermal 2>/dev/null

    # Disable and unexport PWM
    local pwm_path="$PWM_CHIP/pwm$PWM_CHANNEL"
    if [[ -d "$pwm_path" ]]; then
        log_info "Disabling PWM..."
        echo 0 > "$pwm_path/enable" 2>/dev/null
        echo "$PWM_CHANNEL" > "$PWM_CHIP/unexport" 2>/dev/null
    fi

    log_info "Fan control service stopped cleanly"
    exit 0
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# check_permissions: Verify write access to all required sysfs paths
check_permissions() {
    local errors=0

    log_info "Checking permissions..."

    # Check PWM access
    if [[ ! -w "$PWM_CHIP/export" ]] && [[ ! -d "$PWM_CHIP/pwm$PWM_CHANNEL" ]]; then
        log_error "No write permission to $PWM_CHIP/export"
        ((errors++))
    fi

    # Check thermal zone access
    if [[ ! -w "$THERMAL_ZONE/mode" ]]; then
        log_error "No write permission to $THERMAL_ZONE/mode"
        ((errors++))
    fi

    # Check cooling device access
    if [[ ! -w "$CPU_COOLING_DEVICE/cur_state" ]]; then
        log_error "No write permission to $CPU_COOLING_DEVICE/cur_state"
        ((errors++))
    fi

    if (( errors > 0 )); then
        log_error "Permission check failed ($errors errors). Are you running as root?"
        return 1
    fi

    log_info "Permission check passed"
    return 0
}

# verify_hardware: Verify that all required hardware paths exist
verify_hardware() {
    local errors=0

    echo "Verifying hardware compatibility..."

    # Check PWM chip
    if [[ ! -d "$PWM_CHIP" ]]; then
        echo "ERROR: PWM chip not found at $PWM_CHIP"
        echo "       Make sure PWM overlay is configured in /boot/firmware/config.txt"
        ((errors++))
    fi

    # Check thermal zone
    if [[ ! -d "$THERMAL_ZONE" ]]; then
        echo "ERROR: Thermal zone not found at $THERMAL_ZONE"
        ((errors++))
    fi

    # Check cooling device
    if [[ ! -d "$CPU_COOLING_DEVICE" ]]; then
        echo "ERROR: CPU cooling device not found at $CPU_COOLING_DEVICE"
        ((errors++))
    fi

    # Check for hwmon devices
    if ! ls /sys/class/hwmon/hwmon* >/dev/null 2>&1; then
        echo "ERROR: No hwmon devices found in /sys/class/hwmon/"
        ((errors++))
    fi

    if (( errors > 0 )); then
        echo "Hardware verification failed ($errors errors)."
        echo "This may not be a Raspberry Pi 5, or required kernel modules are not loaded."
        return 1
    fi

    echo "Hardware verification passed."
    return 0
}
