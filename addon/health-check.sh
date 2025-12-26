#!/usr/bin/env bash
set -eo pipefail

# Health check script for HAOS supervisor
# Called every 30 seconds to verify add-on is functioning correctly

# Check daemon is running
if ! pgrep -f "fan-control.sh" > /dev/null; then
    echo "ERROR: Daemon process not found"
    exit 1
fi

# Check sysfs write access still works
if [[ ! -w /sys/class/pwm/pwmchip0/pwm2/duty_cycle ]]; then
    echo "ERROR: Lost sysfs write access to PWM"
    exit 1
fi

# Check at least one temperature sensor is readable
if ! ls /sys/class/hwmon/hwmon*/temp1_input >/dev/null 2>&1; then
    echo "ERROR: No temperature sensors accessible"
    exit 1
fi

# All checks passed
echo "OK"
exit 0
