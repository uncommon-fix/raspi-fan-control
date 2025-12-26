#!/usr/bin/env bash
# Installation script for Raspberry Pi 5 Fan Control
# This script installs the fan control daemon as a systemd service

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

# Handle BASH_SOURCE when running from stdin (curl | bash)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$PWD}")" 2>/dev/null && pwd || pwd)"

# Repository configuration
REPO_URL="https://github.com/uncommon-fix/raspi-fan-control.git"
REPO_CACHE="/opt/raspi-fan-control"
INSTALL_MARKER="$REPO_CACHE/.installed"
BRANCH="${BRANCH:-main}"  # Allow override via env var

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
# REPOSITORY MANAGEMENT
# ============================================================================

# detect_execution_context: Check if running from cached repo or standalone
# Returns: 0 if running from cache, 1 if standalone
detect_execution_context() {
    # Check if SCRIPT_DIR is inside REPO_CACHE
    if [[ "$SCRIPT_DIR" == "$REPO_CACHE"* ]]; then
        return 0  # Running from cached repo
    else
        return 1  # Running standalone (from curl)
    fi
}

# clone_or_update_repo: Clone repository or update existing clone
clone_or_update_repo() {
    print_info "Preparing repository..."

    # Check if git is installed
    if ! command -v git &> /dev/null; then
        print_error "git is not installed"
        echo "Please install git: sudo apt-get install git"
        return 1
    fi

    if [[ ! -d "$REPO_CACHE" ]]; then
        # Clone fresh repository
        print_info "Cloning repository from $REPO_URL..."
        print_info "Branch: $BRANCH"

        git clone "$REPO_URL" "$REPO_CACHE" 2>&1 || {
            print_error "Failed to clone repository"
            echo "Please check your internet connection and try again"
            return 1
        }

        # Checkout specified branch
        cd "$REPO_CACHE"
        git checkout "$BRANCH" 2>&1 || {
            print_error "Failed to checkout branch '$BRANCH'"
            echo ""
            echo "Available branches:"
            git branch -r
            return 1
        }

        print_success "Repository cloned to $REPO_CACHE"
    else
        # Update existing repository
        print_info "Updating existing repository at $REPO_CACHE..."

        cd "$REPO_CACHE"

        # Check if repo is dirty
        if [[ -n $(git status --porcelain) ]]; then
            print_info "Repository has local modifications, stashing changes..."
            git stash 2>&1
        fi

        # Fetch latest changes
        git fetch origin 2>&1 || {
            print_error "Failed to fetch from origin"
            echo "Please check your internet connection and try again"
            return 1
        }

        # Checkout and pull specified branch
        git checkout "$BRANCH" 2>&1 || {
            print_error "Failed to checkout branch '$BRANCH'"
            return 1
        }

        git pull origin "$BRANCH" 2>&1 || {
            print_error "Failed to pull from origin/$BRANCH"
            return 1
        }

        print_success "Repository updated to latest $BRANCH"
    fi

    echo ""
    return 0
}

# reexec_from_cache: Re-execute install script from cached repository
reexec_from_cache() {
    print_info "Re-executing from cached repository..."
    echo ""

    # Export environment variables for the re-executed script
    export BRANCH

    # Re-execute from cached repository
    exec "$REPO_CACHE/install.sh"
}

# save_install_metadata: Save installation metadata to marker file
save_install_metadata() {
    if [[ -d "$REPO_CACHE/.git" ]]; then
        local git_commit=$(cd "$REPO_CACHE" && git rev-parse HEAD 2>/dev/null || echo "unknown")
        local git_branch=$(cd "$REPO_CACHE" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

        cat > "$INSTALL_MARKER" << EOF
INSTALLED_AT=$timestamp
GIT_COMMIT=$git_commit
GIT_BRANCH=$git_branch
REPO_URL=$REPO_URL
EOF

        print_info "Installation metadata saved to $INSTALL_MARKER"
    fi
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
    if [[ ! -d "/sys/class/pwm/pwmchip0" ]]; then
        print_error "PWM chip not found at /sys/class/pwm/pwmchip0"
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
    echo "  sudo $REPO_CACHE/uninstall.sh"
    echo ""
    echo "To update to latest version:"
    echo "  curl -fsSL https://raw.githubusercontent.com/uncommon-fix/raspi-fan-control/main/install.sh | sudo bash"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    print_header

    # Detect execution context
    if detect_execution_context; then
        # Running from cached repo - proceed with installation
        print_info "Running from cached repository: $REPO_CACHE"
        echo ""
    else
        # Running standalone (from curl) - need to clone and re-exec
        print_info "Standalone execution detected"
        print_info "Repository will be cached at: $REPO_CACHE"
        print_info "Branch: $BRANCH"
        echo ""

        # Clone or update repository
        clone_or_update_repo || exit 1

        # Re-execute from cached repository
        reexec_from_cache
        # Script execution stops here - we never reach this point
    fi

    # Original installation logic continues here
    # (only reached when running from cached repo)

    # Verify hardware
    verify_hardware || exit 1

    # Verify source files
    verify_source_files || exit 1

    # Install files
    install_files || exit 1

    # Configure systemd
    configure_systemd || exit 1

    # Save installation metadata
    save_install_metadata

    # Print next steps
    print_next_steps

    exit 0
}

# Run main function
main
