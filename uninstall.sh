#!/usr/bin/env bash
# Uninstallation script for Raspberry Pi 5 Fan Control
# This script removes the fan control daemon and restores automatic thermal control

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

# Installation paths
INSTALL_BIN="/usr/local/bin"
INSTALL_LIB="/usr/local/lib/fan-control"
INSTALL_CONFIG="/etc/fan-control"
INSTALL_SYSTEMD="/etc/systemd/system"
LOG_DIR="/var/log/fan-control"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

print_header() {
    echo "=========================================="
    echo "  Raspberry Pi 5 Fan Control Uninstaller"
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
    print_error "This uninstallation script must be run as root"
    echo "Please run: sudo $0"
    exit 1
fi

# ============================================================================
# STOP AND DISABLE SERVICE
# ============================================================================

stop_service() {
    print_info "Stopping fan control service..."

    # Check if service exists
    if systemctl list-unit-files | grep -q fan-control.service; then
        # Stop the service
        if systemctl is-active --quiet fan-control; then
            systemctl stop fan-control 2>/dev/null || {
                print_error "Failed to stop fan-control service"
                return 1
            }
            print_success "Service stopped"
        else
            print_info "Service is not running"
        fi

        # Disable the service
        if systemctl is-enabled --quiet fan-control 2>/dev/null; then
            systemctl disable fan-control 2>/dev/null || {
                print_error "Failed to disable fan-control service"
                return 1
            }
            print_success "Service disabled"
        else
            print_info "Service is not enabled"
        fi
    else
        print_info "Service not found (may already be uninstalled)"
    fi

    echo ""
    return 0
}

# ============================================================================
# RESTORE AUTOMATIC THERMAL CONTROL
# ============================================================================

restore_thermal_control() {
    print_info "Restoring automatic thermal control..."

    local thermal_zone="/sys/class/thermal/thermal_zone0"

    if [[ -f "$thermal_zone/mode" ]]; then
        echo "enabled" > "$thermal_zone/mode" 2>/dev/null || {
            print_error "Failed to re-enable automatic thermal control"
            return 1
        }
        print_success "Automatic thermal control restored"
    else
        print_info "Thermal zone not found (may be already restored)"
    fi

    echo ""
    return 0
}

# ============================================================================
# REMOVE FILES
# ============================================================================

remove_files() {
    print_info "Removing installed files..."

    local removed=0

    # Remove main script
    if [[ -f "$INSTALL_BIN/fan-control.sh" ]]; then
        rm -f "$INSTALL_BIN/fan-control.sh"
        print_success "Removed $INSTALL_BIN/fan-control.sh"
        ((removed++))
    fi

    # Remove library directory
    if [[ -d "$INSTALL_LIB" ]]; then
        rm -rf "$INSTALL_LIB"
        print_success "Removed $INSTALL_LIB"
        ((removed++))
    fi

    # Remove configuration directory
    if [[ -d "$INSTALL_CONFIG" ]]; then
        rm -rf "$INSTALL_CONFIG"
        print_success "Removed $INSTALL_CONFIG"
        ((removed++))
    fi

    # Remove systemd service file
    if [[ -f "$INSTALL_SYSTEMD/fan-control.service" ]]; then
        rm -f "$INSTALL_SYSTEMD/fan-control.service"
        print_success "Removed $INSTALL_SYSTEMD/fan-control.service"
        ((removed++))
    fi

    if (( removed == 0 )); then
        print_info "No files found to remove (may already be uninstalled)"
    fi

    echo ""
    return 0
}

# ============================================================================
# RELOAD SYSTEMD
# ============================================================================

reload_systemd() {
    print_info "Reloading systemd daemon..."

    systemctl daemon-reload || {
        print_error "Failed to reload systemd daemon"
        return 1
    }
    print_success "Systemd daemon reloaded"

    echo ""
    return 0
}

# ============================================================================
# REMOVE LOGS
# ============================================================================

remove_logs() {
    # Ask user if they want to remove logs
    echo "=========================================="
    echo "  Log Files"
    echo "=========================================="
    echo ""

    if [[ -d "$LOG_DIR" ]]; then
        local log_count=$(find "$LOG_DIR" -name "fan-control-*.log" -type f 2>/dev/null | wc -l)
        local log_size=$(du -sh "$LOG_DIR" 2>/dev/null | awk '{print $1}')

        print_info "Found $log_count log file(s) in $LOG_DIR (total size: $log_size)"
        echo ""

        read -p "Do you want to remove the log files? [y/N] " -n 1 -r
        echo ""

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$LOG_DIR"
            print_success "Log directory removed"
        else
            print_info "Log files kept in $LOG_DIR"
        fi
    else
        print_info "No log directory found"
    fi

    echo ""
}

# ============================================================================
# POST-UNINSTALLATION
# ============================================================================

print_completion() {
    echo "=========================================="
    echo "  Uninstallation Complete!"
    echo "=========================================="
    echo ""
    echo "The fan control service has been removed."
    echo "Automatic thermal control has been restored."
    echo ""
    echo "Your Raspberry Pi will now use the default kernel-based fan control."
    echo ""
    echo "If you want to reinstall, run:"
    echo "  sudo ./install.sh"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    print_header

    # Stop and disable service
    stop_service || {
        print_error "Failed to stop service"
        echo "Continuing with uninstallation anyway..."
    }

    # Restore automatic thermal control
    restore_thermal_control || {
        print_error "Failed to restore automatic thermal control"
        echo "You may need to reboot to restore default behavior"
    }

    # Remove files
    remove_files || {
        print_error "Failed to remove some files"
        exit 1
    }

    # Reload systemd
    reload_systemd || {
        print_error "Failed to reload systemd"
        exit 1
    }

    # Ask about log removal
    remove_logs

    # Print completion message
    print_completion

    exit 0
}

# Run main function
main
