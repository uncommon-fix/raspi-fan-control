#!/usr/bin/env bash
# Installation script for Raspberry Pi 5 Fan Control
# This script installs the fan control daemon as a systemd service

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Installation paths
INSTALL_BIN="/usr/local/bin"
INSTALL_LIB="/usr/local/lib/fan-control"
INSTALL_CONFIG="/etc/fan-control"
INSTALL_SYSTEMD="/etc/systemd/system"
LOG_DIR="/var/log/fan-control"

# Source files
SRC_SCRIPT="$SCRIPT_DIR/src/fan-control.sh"
SRC_LIB="$SCRIPT_DIR/src/fan-control-lib.sh"
SRC_CONFIG="$SCRIPT_DIR/src/fan-control.conf"
SRC_SERVICE="$SCRIPT_DIR/systemd/fan-control.service"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

print_header() {
    echo "=========================================="
    echo "  Raspberry Pi 5 Fan Control Installer"
    echo "=========================================="
    echo ""
}

print_success() {
    echo "[OK] $1"
}

print_error() {
    echo "[ERROR] $1" >&2
}

print_info() {
    echo "[INFO] $1"
}

# ============================================================================
# ROOT CHECK
# ============================================================================

if [[ $EUID -ne 0 ]]; then
    print_error "This installation script must be run as root"
    echo "Please run: sudo $0"
    exit 1
fi

# ============================================================================
# HARDWARE VERIFICATION
# ============================================================================

verify_hardware() {
    local errors=0

    print_info "Verifying hardware compatibility..."

    # Check PWM chip
    if [[ ! -d "/sys/class/pwm/pwmchip1" ]]; then
        print_error "PWM chip not found at /sys/class/pwm/pwmchip1"
        echo "        Make sure PWM overlay is configured in /boot/firmware/config.txt:"
        echo "        [all]"
        echo "        dtoverlay=pwm,pin=18,func=2"
        ((errors++))
    else
        print_success "PWM chip found"
    fi

    # Check thermal zone
    if [[ ! -d "/sys/class/thermal/thermal_zone0" ]]; then
        print_error "Thermal zone not found at /sys/class/thermal/thermal_zone0"
        ((errors++))
    else
        print_success "Thermal zone found"
    fi

    # Check cooling device
    if [[ ! -d "/sys/class/thermal/cooling_device0" ]]; then
        print_error "CPU cooling device not found at /sys/class/thermal/cooling_device0"
        ((errors++))
    else
        print_success "CPU cooling device found"
    fi

    # Check for hwmon devices
    if ! ls /sys/class/hwmon/hwmon* >/dev/null 2>&1; then
        print_error "No hwmon devices found in /sys/class/hwmon/"
        ((errors++))
    else
        local hwmon_count=$(ls -d /sys/class/hwmon/hwmon* 2>/dev/null | wc -l)
        print_success "Found $hwmon_count hwmon device(s)"
    fi

    if (( errors > 0 )); then
        print_error "Hardware verification failed with $errors error(s)"
        echo ""
        echo "This system may not be a Raspberry Pi 5, or required kernel modules are not loaded."
        echo "Please check your hardware configuration and try again."
        return 1
    fi

    print_success "Hardware verification passed"
    echo ""
    return 0
}

# ============================================================================
# SOURCE FILES VERIFICATION
# ============================================================================

verify_source_files() {
    local errors=0

    print_info "Verifying source files..."

    # Check main script
    if [[ ! -f "$SRC_SCRIPT" ]]; then
        print_error "Main script not found: $SRC_SCRIPT"
        ((errors++))
    fi

    # Check library
    if [[ ! -f "$SRC_LIB" ]]; then
        print_error "Library not found: $SRC_LIB"
        ((errors++))
    fi

    # Check configuration
    if [[ ! -f "$SRC_CONFIG" ]]; then
        print_error "Configuration not found: $SRC_CONFIG"
        ((errors++))
    fi

    # Check systemd service
    if [[ ! -f "$SRC_SERVICE" ]]; then
        print_error "Systemd service file not found: $SRC_SERVICE"
        ((errors++))
    fi

    if (( errors > 0 )); then
        print_error "Source file verification failed with $errors error(s)"
        return 1
    fi

    print_success "All source files found"
    echo ""
    return 0
}

# ============================================================================
# INSTALLATION
# ============================================================================

install_files() {
    print_info "Installing files..."

    # Create directories
    print_info "Creating directories..."
    mkdir -p "$INSTALL_CONFIG" || {
        print_error "Failed to create $INSTALL_CONFIG"
        return 1
    }
    mkdir -p "$INSTALL_LIB" || {
        print_error "Failed to create $INSTALL_LIB"
        return 1
    }
    mkdir -p "$LOG_DIR" || {
        print_error "Failed to create $LOG_DIR"
        return 1
    }

    # Set log directory permissions
    chmod 755 "$LOG_DIR"
    print_success "Directories created"

    # Install main script
    print_info "Installing main script..."
    install -m 755 "$SRC_SCRIPT" "$INSTALL_BIN/fan-control.sh" || {
        print_error "Failed to install main script"
        return 1
    }
    print_success "Main script installed to $INSTALL_BIN/fan-control.sh"

    # Install library
    print_info "Installing library..."
    install -m 644 "$SRC_LIB" "$INSTALL_LIB/fan-control-lib.sh" || {
        print_error "Failed to install library"
        return 1
    }
    print_success "Library installed to $INSTALL_LIB/fan-control-lib.sh"

    # Install configuration (don't overwrite if exists)
    if [[ -f "$INSTALL_CONFIG/fan-control.conf" ]]; then
        print_info "Configuration file already exists, creating backup..."
        cp "$INSTALL_CONFIG/fan-control.conf" "$INSTALL_CONFIG/fan-control.conf.bak.$(date +%Y%m%d-%H%M%S)"
        print_info "Installing new configuration..."
        install -m 644 "$SRC_CONFIG" "$INSTALL_CONFIG/fan-control.conf"
        print_success "Configuration updated (backup created)"
    else
        print_info "Installing configuration..."
        install -m 644 "$SRC_CONFIG" "$INSTALL_CONFIG/fan-control.conf" || {
            print_error "Failed to install configuration"
            return 1
        }
        print_success "Configuration installed to $INSTALL_CONFIG/fan-control.conf"
    fi

    # Install systemd service
    print_info "Installing systemd service..."
    install -m 644 "$SRC_SERVICE" "$INSTALL_SYSTEMD/fan-control.service" || {
        print_error "Failed to install systemd service"
        return 1
    }
    print_success "Systemd service installed to $INSTALL_SYSTEMD/fan-control.service"

    echo ""
    return 0
}

# ============================================================================
# SYSTEMD CONFIGURATION
# ============================================================================

configure_systemd() {
    print_info "Configuring systemd..."

    # Reload systemd daemon
    systemctl daemon-reload || {
        print_error "Failed to reload systemd daemon"
        return 1
    }
    print_success "Systemd daemon reloaded"

    echo ""
    return 0
}

# ============================================================================
# POST-INSTALLATION
# ============================================================================

print_next_steps() {
    echo "=========================================="
    echo "  Installation Complete!"
    echo "=========================================="
    echo ""
    echo "Configuration file: $INSTALL_CONFIG/fan-control.conf"
    echo "Log directory: $LOG_DIR"
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. (Optional) Review and adjust configuration:"
    echo "   sudo nano $INSTALL_CONFIG/fan-control.conf"
    echo ""
    echo "2. Enable service to start on boot:"
    echo "   sudo systemctl enable fan-control"
    echo ""
    echo "3. Start the service now:"
    echo "   sudo systemctl start fan-control"
    echo ""
    echo "4. Check service status:"
    echo "   sudo systemctl status fan-control"
    echo ""
    echo "5. Monitor logs:"
    echo "   tail -f $LOG_DIR/fan-control-\$(date +%Y-%m-%d).log"
    echo ""
    echo "6. View systemd journal:"
    echo "   journalctl -u fan-control -f"
    echo ""
    echo "Temperature thresholds (CPU/NVMe):"
    echo "  State/Level 1: 50°C  State/Level 2: 60°C"
    echo "  State/Level 3: 70°C  State/Level 4: 80°C"
    echo "  Hysteresis: 3°C"
    echo ""
    echo "To uninstall, run:"
    echo "  sudo $SCRIPT_DIR/uninstall.sh"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    print_header

    # Verify hardware
    verify_hardware || exit 1

    # Verify source files
    verify_source_files || exit 1

    # Install files
    install_files || exit 1

    # Configure systemd
    configure_systemd || exit 1

    # Print next steps
    print_next_steps

    exit 0
}

# Run main function
main
