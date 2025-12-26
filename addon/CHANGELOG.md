# Changelog

All notable changes to the Raspberry Pi 5 Fan Control Home Assistant Add-on will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-12-26

### Added

#### Core Functionality
- Initial release of Home Assistant OS add-on
- Dual fan control for CPU and NVMe fans
- Temperature-based fan speed control with hysteresis algorithm
- Real-time temperature monitoring (default: 5-second intervals)

#### Configuration Options
- Configurable CPU temperature thresholds (4 levels)
- Configurable NVMe temperature thresholds (4 levels)
- Adjustable hysteresis (1-10°C)
- Variable loop interval (1-60 seconds)
- Debug mode toggle
- Optional startup test

#### Safety Mechanisms
- Three-level error handling:
  - Level 1: Transient sensor failures (use last known temperature)
  - Level 2: Persistent sensor failures (emergency mode, max cooling)
  - Level 3: Thermal runaway protection (CPU >90°C, NVMe >85°C)
- Automatic kernel thermal control fallback
- Graceful shutdown with safe fan states
- Container health monitoring

#### User Experience
- HAOS UI configuration interface
- Integrated logging via HAOS supervisor
- Startup test for hardware verification
- Clear error messages with troubleshooting steps
- Automatic sensor discovery (works without NVMe drive)

#### Technical Features
- PWM control at 25kHz for NVMe fan
- Discrete state control (0-4) for CPU fan via cooling device
- Dynamic hwmon sensor discovery
- Privileged container with SYS_RAWIO capability
- Resource limits: 5% CPU quota, 50MB memory maximum
- Health check every 30 seconds

### Hardware Support
- Raspberry Pi 5 (aarch64 architecture only)
- CPU fan via thermal cooling device (/sys/class/thermal/cooling_device0)
- NVMe fan via PWM on GPIO 18 (/sys/class/pwm/pwmchip0/pwm2)
- Automatic detection of hwmon sensors (cpu_thermal, nvme)

### Documentation
- Complete README with installation instructions
- Detailed configuration documentation (DOCS.md)
- PWM overlay setup guide
- Troubleshooting section
- Configuration examples (quiet, performance, balanced)

### Dependencies
- Home Assistant OS base image (aarch64)
- Bash 4.0+
- Core utilities: coreutils, findutils, jq, procps

---

## Future Enhancements (Planned)

### Potential v1.1.0 Features
- Optional smooth PWM ramping (gradual speed changes)
- Fan RPM feedback monitoring (if tachometer available)
- Historical temperature data export
- Custom temperature profiles (preset configurations)

### Potential v1.2.0 Features
- Integration with Home Assistant sensors
- Automation triggers for fan events
- Dashboard card for temperature monitoring
- Email/notification alerts for thermal events

### Potential v2.0.0 Features
- Support for additional Raspberry Pi models
- Multiple PWM fan support
- Web-based configuration UI
- Prometheus metrics export

---

## Notes

- This add-on is specifically designed for Raspberry Pi 5 running Home Assistant OS
- For standalone Debian/Raspberry Pi OS installations, use the systemd service from the main repository
- Both installation methods are maintained from the same codebase

---

## Links

- **Repository**: https://github.com/uncommon-fix/raspi-fan-control
- **Issues**: https://github.com/uncommon-fix/raspi-fan-control/issues
- **Discussions**: https://github.com/uncommon-fix/raspi-fan-control/discussions
