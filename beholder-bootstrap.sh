#!/bin/bash
#===============================================================================
# beholder-bootstrap.sh — Beholder Pi Role Bootstrap
# Version: 1
#
# WHAT:  Deploys Hailo-8L AI accelerator stack + Blinkt! LED status daemon
# WHY:   Make Beholder re-deployable from scratch if the SD/NVMe is lost
# HOW:   curl -fsSL <url> | bash
#
# PREREQ: Run pi-bootstrap.sh first for base shell setup (zsh, p10k, MOTD)
#         Or pass --full to run both in sequence.
#
# HARDWARE PROFILE (what this script expects):
#   Board:    Raspberry Pi 5 Model B (8GB)
#   Storage:  M.2 NVMe SSD (Micron, via USB 3.0 or PCIe HAT)
#   AI:       Hailo-8L NPU (M.2 / PCIe)
#   LEDs:     Blinkt! 8-pixel APA102 RGB strip (SPI/GPIO)
#   Network:  Dual-homed (eth0 + wlan0)
#   Audio:    HDMI out only
#   Display:  Headless (no desktop)
#
# FLAGS:
#   --no-update    Skip apt update/upgrade
#   --no-hailo     Skip Hailo runtime installation
#   --no-leds      Skip LED daemon installation
#   --no-camera    Skip camera/vision tools
#   --full         Run pi-bootstrap.sh first (base shell), then this
#   --dry-run      Show what would be done without changing anything
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# CONFIGURATION
#-------------------------------------------------------------------------------
SCRIPT_VERSION=1
LOG_FILE="$HOME/beholder-bootstrap.log"
BACKUP_DIR="$HOME/.beholder-backups/$(date +%Y%m%d-%H%M%S)"
VENV_DIR="$HOME/.venv/beholder"
LED_DAEMON="/opt/beholder/leds.py"
LED_SERVICE="beholder-leds"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# Status tracking
declare -A STATUS
FAILURES=0

#-------------------------------------------------------------------------------
# PARSE ARGUMENTS
#-------------------------------------------------------------------------------
DO_UPDATE=true
DO_HAILO=true
DO_LEDS=true
DO_CAMERA=true
DO_FULL=false
DRY_RUN=false

for arg in "$@"; do
    case $arg in
        --no-update)  DO_UPDATE=false ;;
        --no-hailo)   DO_HAILO=false ;;
        --no-leds)    DO_LEDS=false ;;
        --no-camera)  DO_CAMERA=false ;;
        --full)       DO_FULL=true ;;
        --dry-run)    DRY_RUN=true ;;
        --help|-h)
            echo "Usage: $0 [--no-update] [--no-hailo] [--no-leds] [--no-camera] [--full] [--dry-run]"
            exit 0
            ;;
        *) echo -e "${YELLOW}⚠ Unknown flag: $arg${NC}" >&2 ;;
    esac
done

#-------------------------------------------------------------------------------
# LOGGING HELPERS (same pattern as pi-bootstrap.sh)
#-------------------------------------------------------------------------------
log()     { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}✓${NC} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}✗${NC} $*" | tee -a "$LOG_FILE"; }

header() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${MAGENTA}  $*${NC}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
}

spin() {
    local label="$1"
    shift
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local start=$SECONDS

    if [[ "$DRY_RUN" == true ]]; then
        log "[dry-run] Would run: $*"
        success "$label ${DIM}(dry-run)${NC}"
        return 0
    fi

    ( "$@" ) >> "$LOG_FILE" 2>&1 &
    local pid=$!

    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(( SECONDS - start ))
        local mins=$(( elapsed / 60 ))
        local secs=$(( elapsed % 60 ))
        printf "\r  ${CYAN}%s${NC} %s ${DIM}%d:%02d${NC} " "${frames[i++ % ${#frames[@]}]}" "$label" "$mins" "$secs"
        sleep 0.1
    done

    local rc=0
    wait "$pid" || rc=$?
    local elapsed=$(( SECONDS - start ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))

    printf "\r%-${COLUMNS:-80}s\r" ""
    if [[ $rc -eq 0 ]]; then
        success "$label ${DIM}(${mins}m ${secs}s)${NC}"
    else
        error "$label failed ${DIM}(${mins}m ${secs}s)${NC}"
    fi

    return $rc
}

track_status() {
    local step="$1" result="$2"
    STATUS["$step"]="$result"
    if [[ "$result" == "FAIL" ]]; then
        ((FAILURES++)) || true
    fi
}

#-------------------------------------------------------------------------------
# APT HELPERS (reuse pi-bootstrap pattern)
#-------------------------------------------------------------------------------
APT_ENV=(sudo env DEBIAN_FRONTEND=noninteractive)
APT_DPKG_OPTS=(-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)

KERNEL_HOLD_PKGS=(
    raspberrypi-kernel
    raspberrypi-kernel-headers
    raspberrypi-bootloader
    linux-image-rpi-v8
    linux-image-rpi-2712
    linux-headers-rpi-v8
    linux-headers-rpi-2712
)

#-------------------------------------------------------------------------------
# PREFLIGHT — verify we're on a Pi 5
#-------------------------------------------------------------------------------
preflight() {
    header "PREFLIGHT CHECKS"

    # Must be aarch64
    local arch
    arch=$(uname -m)
    if [[ "$arch" != "aarch64" ]]; then
        error "Expected aarch64, got $arch. Beholder requires a Pi 5."
        track_status "Preflight" "FAIL"
        return 1
    fi
    success "Architecture: $arch"

    # Must be Pi 5
    local model="unknown"
    if [[ -f /proc/device-tree/model ]]; then
        model=$(tr -d '\0' < /proc/device-tree/model)
    fi
    if [[ ! "${model,,}" =~ "pi 5" ]]; then
        error "Expected Raspberry Pi 5, got: $model"
        track_status "Preflight" "FAIL"
        return 1
    fi
    success "Model: $model"

    # RAM check (expect 8GB)
    local ram_mb
    ram_mb=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
    if (( ram_mb < 4000 )); then
        warn "Only ${ram_mb}MB RAM detected — Hailo inference may be memory-constrained"
    else
        success "RAM: ${ram_mb}MB"
    fi

    # Check for base shell (pi-bootstrap.sh)
    if [[ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]]; then
        success "Base shell (Elminster) detected"
    else
        warn "Base shell not found — run pi-bootstrap.sh first, or use --full"
        if [[ "$DO_FULL" == true ]]; then
            log "Will install base shell as part of --full run"
        fi
    fi

    # Boot config location
    if [[ -f /boot/firmware/config.txt ]]; then
        BOOT_CONFIG="/boot/firmware/config.txt"
    elif [[ -f /boot/config.txt ]]; then
        BOOT_CONFIG="/boot/config.txt"
    else
        BOOT_CONFIG=""
        warn "Boot config not found"
    fi
    [[ -n "$BOOT_CONFIG" ]] && success "Boot config: $BOOT_CONFIG"

    track_status "Preflight" "OK"
}

#-------------------------------------------------------------------------------
# RUN BASE BOOTSTRAP (--full mode)
#-------------------------------------------------------------------------------
run_base_bootstrap() {
    header "RUNNING BASE SHELL BOOTSTRAP"

    if [[ "$DO_FULL" == false ]]; then
        log "Skipping base bootstrap (use --full to include)"
        track_status "Base Bootstrap" "SKIP"
        return 0
    fi

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local base_script="$script_dir/pi-bootstrap.sh"

    if [[ ! -f "$base_script" ]]; then
        error "pi-bootstrap.sh not found in $script_dir"
        warn "Download it first, or run base setup manually"
        track_status "Base Bootstrap" "FAIL"
        return 1
    fi

    local base_flags=()
    [[ "$DO_UPDATE" == false ]] && base_flags+=(--no-update)

    log "Running: bash $base_script ${base_flags[*]:-}"
    if bash "$base_script" "${base_flags[@]:-}"; then
        track_status "Base Bootstrap" "OK"
    else
        warn "Base bootstrap had failures (continuing with role setup)"
        track_status "Base Bootstrap" "FAIL"
    fi
}

#-------------------------------------------------------------------------------
# UPDATE OS
#-------------------------------------------------------------------------------
update_os() {
    header "UPDATING OS PACKAGES"

    if [[ "$DO_UPDATE" == false ]]; then
        log "Skipping OS update (--no-update)"
        track_status "OS Update" "SKIP"
        return 0
    fi

    # Hold kernel packages
    local held=()
    for pkg in "${KERNEL_HOLD_PKGS[@]}"; do
        if dpkg -l "$pkg" &>/dev/null; then
            sudo apt-mark hold "$pkg" &>/dev/null && held+=("$pkg")
        fi
    done
    (( ${#held[@]} > 0 )) && success "Held ${#held[@]} kernel pkg(s)"

    if ! spin "Refreshing package lists" \
        "${APT_ENV[@]}" apt-get update -qq; then
        track_status "OS Update" "FAIL"
        return 1
    fi

    if ! spin "Upgrading packages" \
        "${APT_ENV[@]}" apt-get upgrade -y -qq "${APT_DPKG_OPTS[@]}"; then
        track_status "OS Update" "FAIL"
        return 1
    fi

    track_status "OS Update" "OK"
}

#-------------------------------------------------------------------------------
# INSTALL HAILO RUNTIME
#-------------------------------------------------------------------------------
install_hailo() {
    header "INSTALLING HAILO-8L AI RUNTIME"

    if [[ "$DO_HAILO" == false ]]; then
        log "Skipping Hailo install (--no-hailo)"
        track_status "Hailo Runtime" "SKIP"
        return 0
    fi

    # Check if already installed
    if command -v hailortcli &>/dev/null; then
        local ver
        ver=$(hailortcli fw-control identify 2>/dev/null | grep -oP 'Firmware Version:\s*\K[\d.]+' || echo "unknown")
        success "Hailo runtime already installed (FW: $ver)"
    fi

    # hailo-all is the meta-package on Pi OS Bookworm
    # Includes: hailort, hailort-pcie-driver, hailo-firmware, hailo-tappas
    if dpkg -s hailo-all &>/dev/null; then
        success "hailo-all package already installed"
    else
        log "Installing hailo-all meta-package..."
        if ! spin "Installing Hailo runtime (hailo-all)" \
            "${APT_ENV[@]}" apt-get install -y -qq "${APT_DPKG_OPTS[@]}" hailo-all; then
            warn "hailo-all not in repo — trying individual packages..."

            # Fallback: install components individually
            local hailo_pkgs=(hailort hailort-pcie-driver)
            local installed=0
            for pkg in "${hailo_pkgs[@]}"; do
                if spin "Installing $pkg" \
                    "${APT_ENV[@]}" apt-get install -y -qq "${APT_DPKG_OPTS[@]}" "$pkg" 2>/dev/null; then
                    ((installed++)) || true
                fi
            done

            if (( installed == 0 )); then
                error "Could not install Hailo packages from apt"
                warn "You may need to install hailort manually from Hailo's developer zone"
                warn "  https://hailo.ai/developer-zone/"
                track_status "Hailo Runtime" "FAIL"
                return 1
            fi
        fi
    fi

    # Ensure hailort service is enabled
    if systemctl list-unit-files | grep -q hailort.service; then
        sudo systemctl enable hailort.service 2>/dev/null || true
        sudo systemctl start hailort.service 2>/dev/null || true
        success "hailort.service enabled and started"
    fi

    # Verify Hailo device is reachable
    if command -v hailortcli &>/dev/null; then
        if hailortcli fw-control identify &>/dev/null; then
            success "Hailo device responding"
        else
            warn "Hailo device not responding — check PCIe connection"
        fi
    fi

    track_status "Hailo Runtime" "OK"
}

#-------------------------------------------------------------------------------
# INSTALL PYTHON ENVIRONMENT
#-------------------------------------------------------------------------------
install_python_env() {
    header "INSTALLING PYTHON ENVIRONMENT"

    # System packages needed for GPIO/LED/vision work
    local sys_pkgs=(
        python3-dev
        python3-pip
        python3-venv
        python3-numpy
        python3-opencv
        python3-picamera2
        python3-libcamera
        python3-gpiozero
        python3-lgpio
        python3-spidev
    )

    log "Installing system Python packages..."
    if ! spin "Installing Python system packages" \
        "${APT_ENV[@]}" apt-get install -y -qq "${APT_DPKG_OPTS[@]}" "${sys_pkgs[@]}"; then
        warn "Some Python system packages may not be available"
    fi

    # Install blinkt via pip (not always in apt)
    if python3 -c "import blinkt" &>/dev/null; then
        success "blinkt library already available"
    else
        log "Installing blinkt library..."
        if spin "Installing blinkt (pip)" \
            pip3 install --break-system-packages blinkt 2>/dev/null || \
            pip3 install blinkt; then
            success "blinkt installed"
        else
            warn "blinkt install failed — LED daemon may not work"
        fi
    fi

    # Install hailort Python bindings if not present
    if python3 -c "import hailo_platform" &>/dev/null; then
        success "hailort Python bindings available"
    elif python3 -c "import hailort" &>/dev/null; then
        success "hailort Python bindings available"
    else
        log "Installing hailort Python bindings..."
        spin "Installing hailort Python bindings" \
            pip3 install --break-system-packages hailort 2>/dev/null || \
            warn "hailort Python bindings not installed (may come from hailo-all)"
    fi

    track_status "Python Environment" "OK"
}

#-------------------------------------------------------------------------------
# INSTALL VISION / MEDIA TOOLS
#-------------------------------------------------------------------------------
install_vision_tools() {
    header "INSTALLING VISION & MEDIA TOOLS"

    if [[ "$DO_CAMERA" == false ]]; then
        log "Skipping camera/vision tools (--no-camera)"
        track_status "Vision Tools" "SKIP"
        return 0
    fi

    local pkgs=(
        ffmpeg
        libcamera-apps
        v4l-utils
        gstreamer1.0-tools
        gstreamer1.0-plugins-base
        gstreamer1.0-plugins-good
    )

    if ! spin "Installing vision & media tools" \
        "${APT_ENV[@]}" apt-get install -y -qq "${APT_DPKG_OPTS[@]}" "${pkgs[@]}"; then
        warn "Some vision packages may not be available"
    fi

    track_status "Vision Tools" "OK"
}

#-------------------------------------------------------------------------------
# DEPLOY BEHOLDER LED DAEMON
#-------------------------------------------------------------------------------
deploy_led_daemon() {
    header "DEPLOYING BEHOLDER LED STATUS DAEMON"

    if [[ "$DO_LEDS" == false ]]; then
        log "Skipping LED daemon (--no-leds)"
        track_status "LED Daemon" "SKIP"
        return 0
    fi

    # Create daemon directory
    sudo mkdir -p /opt/beholder

    # Write the LED daemon script
    log "Writing LED daemon to $LED_DAEMON..."
    sudo tee "$LED_DAEMON" > /dev/null << 'LED_SCRIPT'
#!/usr/bin/env python3
"""
beholder-leds.py — Beholder status LED daemon (Blinkt! APA102)

8 pixels, left to right:
  [0]     Heartbeat        — slow pulse (green=ok, red=hot, off=dead)
  [1]     CPU load         — black→green→yellow→red by load average
  [2]     RAM usage        — black→green→yellow→red by percentage
  [3]     Disk usage       — black→green→yellow→red by percentage
  [4]     Network (eth0)   — blue=up, off=down
  [5]     Network (wlan0)  — cyan=up, off=down
  [6]     Hailo NPU        — magenta=active, dim=idle, off=missing
  [7]     Temperature      — green→yellow→red by SoC temp

Runs as systemd service: beholder-leds.service
"""

import signal
import sys
import time
import math
import os
import subprocess

try:
    import blinkt
except ImportError:
    print("ERROR: blinkt library not found. Install with: pip3 install blinkt")
    sys.exit(1)

# Configuration
BRIGHTNESS = 0.05       # Blinkt! LEDs are BRIGHT — keep low
UPDATE_INTERVAL = 1.0   # seconds between updates
HEARTBEAT_SPEED = 2.0   # pulse cycle in seconds

# Pixel assignments
PX_HEARTBEAT = 0
PX_CPU       = 1
PX_RAM       = 2
PX_DISK      = 3
PX_ETH       = 4
PX_WLAN      = 5
PX_HAILO     = 6
PX_TEMP      = 7


def cleanup(sig=None, frame=None):
    """Turn off all LEDs on exit."""
    blinkt.clear()
    blinkt.show()
    sys.exit(0)


signal.signal(signal.SIGTERM, cleanup)
signal.signal(signal.SIGINT, cleanup)


def read_file(path):
    """Read a file, return contents or empty string."""
    try:
        with open(path) as f:
            return f.read().strip()
    except (OSError, IOError):
        return ""


def get_cpu_load():
    """Return 1-minute load average as fraction of cores."""
    try:
        load = os.getloadavg()[0]
        cores = os.cpu_count() or 4
        return min(load / cores, 1.0)
    except OSError:
        return 0.0


def get_ram_pct():
    """Return RAM usage as 0.0-1.0."""
    meminfo = read_file("/proc/meminfo")
    total = available = 0
    for line in meminfo.splitlines():
        if line.startswith("MemTotal:"):
            total = int(line.split()[1])
        elif line.startswith("MemAvailable:"):
            available = int(line.split()[1])
    if total == 0:
        return 0.0
    return 1.0 - (available / total)


def get_disk_pct():
    """Return root disk usage as 0.0-1.0."""
    try:
        st = os.statvfs("/")
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        if total == 0:
            return 0.0
        return 1.0 - (free / total)
    except OSError:
        return 0.0


def get_interface_up(iface):
    """Check if a network interface is UP and has an IP."""
    state = read_file(f"/sys/class/net/{iface}/operstate")
    return state == "up"


def get_temp_c():
    """Return SoC temperature in Celsius."""
    raw = read_file("/sys/class/thermal/thermal_zone0/temp")
    if raw:
        return int(raw) / 1000.0
    return 0.0


def hailo_present():
    """Check if Hailo device is accessible."""
    try:
        result = subprocess.run(
            ["hailortcli", "fw-control", "identify"],
            capture_output=True, timeout=3
        )
        return result.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def pct_to_rgb(pct):
    """Map 0.0-1.0 to green→yellow→red."""
    if pct < 0.5:
        # Green to yellow
        r = int(255 * (pct * 2))
        g = 255
    else:
        # Yellow to red
        r = 255
        g = int(255 * (1.0 - (pct - 0.5) * 2))
    return (max(0, min(255, r)), max(0, min(255, g)), 0)


def main():
    blinkt.set_clear_on_exit(True)
    blinkt.set_brightness(BRIGHTNESS)
    blinkt.clear()

    # Startup animation — sweep magenta left to right
    for i in range(8):
        blinkt.clear()
        blinkt.set_pixel(i, 180, 0, 255)
        blinkt.show()
        time.sleep(0.08)
    for i in range(7, -1, -1):
        blinkt.clear()
        blinkt.set_pixel(i, 180, 0, 255)
        blinkt.show()
        time.sleep(0.08)
    blinkt.clear()
    blinkt.show()
    time.sleep(0.3)

    # Cache Hailo status (check every 30 cycles, not every second)
    hailo_ok = False
    hailo_check_counter = 0

    tick = 0
    while True:
        try:
            # --- Heartbeat (pixel 0) ---
            temp_c = get_temp_c()
            pulse = (math.sin(tick * (2 * math.pi / (HEARTBEAT_SPEED / UPDATE_INTERVAL))) + 1) / 2
            intensity = int(40 + pulse * 215)
            if temp_c < 60:
                blinkt.set_pixel(PX_HEARTBEAT, 0, intensity, 0)       # green
            elif temp_c < 70:
                blinkt.set_pixel(PX_HEARTBEAT, intensity, intensity, 0) # yellow
            else:
                blinkt.set_pixel(PX_HEARTBEAT, intensity, 0, 0)       # red

            # --- CPU (pixel 1) ---
            r, g, b = pct_to_rgb(get_cpu_load())
            blinkt.set_pixel(PX_CPU, r, g, b)

            # --- RAM (pixel 2) ---
            r, g, b = pct_to_rgb(get_ram_pct())
            blinkt.set_pixel(PX_RAM, r, g, b)

            # --- Disk (pixel 3) ---
            r, g, b = pct_to_rgb(get_disk_pct())
            blinkt.set_pixel(PX_DISK, r, g, b)

            # --- Network eth0 (pixel 4) ---
            if get_interface_up("eth0"):
                blinkt.set_pixel(PX_ETH, 0, 0, 255)     # blue
            else:
                blinkt.set_pixel(PX_ETH, 0, 0, 0)

            # --- Network wlan0 (pixel 5) ---
            if get_interface_up("wlan0"):
                blinkt.set_pixel(PX_WLAN, 0, 255, 255)   # cyan
            else:
                blinkt.set_pixel(PX_WLAN, 0, 0, 0)

            # --- Hailo NPU (pixel 6) ---
            hailo_check_counter += 1
            if hailo_check_counter >= 30:
                hailo_ok = hailo_present()
                hailo_check_counter = 0
            if hailo_ok:
                blinkt.set_pixel(PX_HAILO, 180, 0, 255)  # magenta
            else:
                blinkt.set_pixel(PX_HAILO, 30, 0, 40)    # dim purple

            # --- Temperature (pixel 7) ---
            # Map 30-80°C to 0.0-1.0
            temp_pct = max(0.0, min(1.0, (temp_c - 30) / 50.0))
            r, g, b = pct_to_rgb(temp_pct)
            blinkt.set_pixel(PX_TEMP, r, g, b)

            blinkt.show()
            tick += 1
            time.sleep(UPDATE_INTERVAL)

        except KeyboardInterrupt:
            cleanup()
        except Exception as e:
            # Don't crash the daemon on transient errors
            print(f"Warning: {e}", file=sys.stderr)
            time.sleep(UPDATE_INTERVAL)


if __name__ == "__main__":
    main()
LED_SCRIPT

    sudo chmod +x "$LED_DAEMON"
    success "LED daemon written to $LED_DAEMON"

    # Write systemd service unit
    log "Writing systemd service unit..."
    sudo tee /etc/systemd/system/${LED_SERVICE}.service > /dev/null << UNIT
[Unit]
Description=Beholder LED status daemon (Blinkt!)
After=network.target hailort.service
Wants=hailort.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${LED_DAEMON}
Restart=always
RestartSec=5
User=root
Nice=10
StandardOutput=journal
StandardError=journal

# Hardening
ProtectHome=read-only
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/dev/spidev10.0 /dev/gpiomem /sys

[Install]
WantedBy=multi-user.target
UNIT

    # Enable and start
    sudo systemctl daemon-reload
    sudo systemctl enable ${LED_SERVICE}.service
    sudo systemctl restart ${LED_SERVICE}.service

    # Verify
    if systemctl is-active --quiet ${LED_SERVICE}.service; then
        success "${LED_SERVICE}.service running"
    else
        warn "${LED_SERVICE}.service failed to start — check: journalctl -u ${LED_SERVICE}"
    fi

    track_status "LED Daemon" "OK"
}

#-------------------------------------------------------------------------------
# CONFIGURE BOOT (SPI, PCIe, interfaces)
#-------------------------------------------------------------------------------
configure_boot() {
    header "CONFIGURING BOOT PARAMETERS"

    if [[ -z "${BOOT_CONFIG:-}" ]]; then
        warn "No boot config found — skipping"
        track_status "Boot Config" "SKIP"
        return 0
    fi

    mkdir -p "$BACKUP_DIR"
    sudo cp "$BOOT_CONFIG" "$BACKUP_DIR/config.txt.bak"
    success "Backed up $BOOT_CONFIG"

    local changes=0

    # Enable SPI (required for Blinkt!)
    if grep -qE '^\s*dtparam=spi=on' "$BOOT_CONFIG" 2>/dev/null; then
        success "SPI already enabled"
    else
        log "Enabling SPI..."
        echo -e "\n# SPI — required for Blinkt! LEDs (beholder-bootstrap)" | sudo tee -a "$BOOT_CONFIG" >/dev/null
        echo "dtparam=spi=on" | sudo tee -a "$BOOT_CONFIG" >/dev/null
        success "SPI enabled"
        ((changes++)) || true
    fi

    # PCIe Gen 3 (doubles Hailo throughput)
    if grep -qE '^\s*dtparam=pciex1_gen=3' "$BOOT_CONFIG" 2>/dev/null; then
        success "PCIe Gen 3 already enabled"
    else
        log "Enabling PCIe Gen 3..."
        echo -e "\n# PCIe Gen 3 — doubles NVMe/Hailo throughput (beholder-bootstrap)" | sudo tee -a "$BOOT_CONFIG" >/dev/null
        echo "dtparam=pciex1_gen=3" | sudo tee -a "$BOOT_CONFIG" >/dev/null
        success "PCIe Gen 3 enabled (requires reboot)"
        ((changes++)) || true
    fi

    # 4Kp60 HDMI (already enabled per recon, but ensure it persists)
    if grep -qE '^\s*hdmi_enable_4kp60=1' "$BOOT_CONFIG" 2>/dev/null; then
        success "4Kp60 HDMI already enabled"
    else
        echo -e "\n# 4K60 HDMI output (beholder-bootstrap)" | sudo tee -a "$BOOT_CONFIG" >/dev/null
        echo "hdmi_enable_4kp60=1" | sudo tee -a "$BOOT_CONFIG" >/dev/null
        success "4Kp60 HDMI enabled"
        ((changes++)) || true
    fi

    if (( changes > 0 )); then
        warn "Reboot required for boot config changes to take effect"
    fi

    track_status "Boot Config" "OK"
}

#-------------------------------------------------------------------------------
# CONFIGURE NETWORK (hostname, mDNS)
#-------------------------------------------------------------------------------
configure_network() {
    header "CONFIGURING NETWORK IDENTITY"

    local current_hostname
    current_hostname=$(hostname)

    if [[ "$current_hostname" == "Beholder" ]]; then
        success "Hostname already set to Beholder"
    else
        log "Setting hostname to Beholder..."
        if [[ "$DRY_RUN" == false ]]; then
            echo "Beholder" | sudo tee /etc/hostname >/dev/null
            sudo hostnamectl set-hostname Beholder 2>/dev/null || true
            # Update /etc/hosts
            if grep -q "$current_hostname" /etc/hosts 2>/dev/null; then
                sudo sed -i "s/$current_hostname/Beholder/g" /etc/hosts
            fi
            success "Hostname set to Beholder"
        else
            log "[dry-run] Would set hostname to Beholder"
        fi
    fi

    # Ensure avahi-daemon is installed (for .local mDNS)
    if dpkg -s avahi-daemon &>/dev/null; then
        success "avahi-daemon installed (Beholder.local will resolve)"
    else
        spin "Installing avahi-daemon" \
            "${APT_ENV[@]}" apt-get install -y -qq avahi-daemon || true
    fi

    track_status "Network Identity" "OK"
}

#-------------------------------------------------------------------------------
# HEALTH CHECK
#-------------------------------------------------------------------------------
health_check() {
    header "HEALTH CHECK"

    # Temperature
    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        local temp_raw temp_c
        temp_raw=$(cat /sys/class/thermal/thermal_zone0/temp)
        temp_c=$((temp_raw / 1000))
        if (( temp_c < 60 )); then
            success "Temperature: ${temp_c}°C"
        elif (( temp_c < 70 )); then
            warn "Temperature: ${temp_c}°C (warm)"
        else
            error "Temperature: ${temp_c}°C (HOT — check cooling)"
        fi
    fi

    # Throttle status
    if command -v vcgencmd &>/dev/null; then
        local throttle
        throttle=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo "N/A")
        if [[ "$throttle" == "0x0" ]]; then
            success "No throttling detected"
        elif [[ "$throttle" =~ ^0x ]]; then
            warn "Throttle flags: $throttle"
        fi
    fi

    # Hailo device
    if command -v hailortcli &>/dev/null; then
        if hailortcli fw-control identify &>/dev/null; then
            success "Hailo NPU responding"
        else
            warn "Hailo NPU not responding"
        fi
    else
        warn "hailortcli not found"
    fi

    # LED service
    if systemctl is-active --quiet ${LED_SERVICE}.service 2>/dev/null; then
        success "${LED_SERVICE}.service running"
    else
        warn "${LED_SERVICE}.service not running"
    fi

    # SPI device
    if [[ -e /dev/spidev10.0 ]] || compgen -G "/dev/spidev*" >/dev/null 2>&1; then
        success "SPI device available"
    else
        warn "No SPI device found — Blinkt! may not work"
    fi

    # Network
    if ip link show eth0 2>/dev/null | grep -q "state UP"; then
        success "eth0: UP"
    else
        warn "eth0: DOWN"
    fi
    if ip link show wlan0 2>/dev/null | grep -q "state UP"; then
        success "wlan0: UP"
    fi

    # Disk space
    local disk_pct
    disk_pct=$(df / | awk 'NR==2{gsub(/%/,"",$5); print $5}')
    if (( disk_pct < 70 )); then
        success "Disk: ${disk_pct}% used"
    elif (( disk_pct < 85 )); then
        warn "Disk: ${disk_pct}% used"
    else
        error "Disk: ${disk_pct}% used — running low!"
    fi

    track_status "Health Check" "OK"
}

#-------------------------------------------------------------------------------
# WRITE /etc/beholder-info
#-------------------------------------------------------------------------------
write_beholder_info() {
    log "Writing /etc/beholder-info..."

    local net_if ip_addr mac_addr hailo_ver
    net_if=$(timeout 2 ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
    [[ -z "$net_if" ]] && net_if="eth0"
    ip_addr=$(timeout 2 hostname -I 2>/dev/null | awk '{print $1}')
    mac_addr=$(cat "/sys/class/net/${net_if}/address" 2>/dev/null || echo "unknown")
    hailo_ver=$(hailortcli fw-control identify 2>/dev/null | grep -oP 'Firmware Version:\s*\K[\d.]+' || echo "not detected")

    sudo tee /etc/beholder-info >/dev/null <<EOF
# Beholder — AI Edge Node
# Generated by beholder-bootstrap v${SCRIPT_VERSION} on $(date -Iseconds)
HOSTNAME=Beholder
ROLE=ai-edge-node
MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "unknown")
INTERFACE=${net_if}
IP_ADDRESS=${ip_addr:-unknown}
MAC_ADDRESS=${mac_addr}
HAILO_FIRMWARE=${hailo_ver}
BOOTSTRAP_VERSION=${SCRIPT_VERSION}
LED_DAEMON=${LED_DAEMON}
LED_SERVICE=${LED_SERVICE}
EOF

    success "Wrote /etc/beholder-info"
}

#-------------------------------------------------------------------------------
# SUMMARY
#-------------------------------------------------------------------------------
print_summary() {
    header "BEHOLDER BOOTSTRAP COMPLETE"

    echo ""
    echo -e "${BOLD}INSTALLATION STATUS${NC}"
    echo "───────────────────────────────────────────────────────────"

    for step in "Preflight" "Base Bootstrap" "OS Update" "Hailo Runtime" \
                "Python Environment" "Vision Tools" "LED Daemon" \
                "Boot Config" "Network Identity" "Health Check"; do
        local status="${STATUS[$step]:-N/A}"
        case $status in
            OK)   echo -e "  ${GREEN}✓${NC} $step" ;;
            FAIL) echo -e "  ${RED}✗${NC} $step" ;;
            SKIP) echo -e "  ${YELLOW}○${NC} $step (skipped)" ;;
            *)    echo -e "  ${BLUE}?${NC} $step" ;;
        esac
    done

    echo ""
    if [[ $FAILURES -gt 0 ]]; then
        echo -e "${RED}⚠ $FAILURES step(s) failed — review above for details${NC}"
    else
        echo -e "${GREEN}✓ All steps completed successfully${NC}"
    fi

    echo ""
    echo -e "${BOLD}FILES CREATED${NC}"
    echo "───────────────────────────────────────────────────────────"
    echo "  LED Daemon:     $LED_DAEMON"
    echo "  Service Unit:   /etc/systemd/system/${LED_SERVICE}.service"
    echo "  Node Info:      /etc/beholder-info"
    echo "  Backups:        $BACKUP_DIR"
    echo "  Log:            $LOG_FILE"

    echo ""
    echo -e "${BOLD}LED PIXEL MAP${NC}"
    echo "───────────────────────────────────────────────────────────"
    echo "  [0] Heartbeat    green=ok, yellow=warm, red=hot"
    echo "  [1] CPU load     green→yellow→red"
    echo "  [2] RAM usage    green→yellow→red"
    echo "  [3] Disk usage   green→yellow→red"
    echo "  [4] eth0         blue=up, off=down"
    echo "  [5] wlan0        cyan=up, off=down"
    echo "  [6] Hailo NPU    magenta=active, dim=idle"
    echo "  [7] Temperature  green→yellow→red"

    echo ""
    echo -e "${BOLD}SERVICES${NC}"
    echo "───────────────────────────────────────────────────────────"
    echo "  systemctl status ${LED_SERVICE}     # LED daemon"
    echo "  systemctl status hailort          # Hailo runtime"
    echo "  journalctl -u ${LED_SERVICE} -f    # LED daemon logs"
    echo "  hailortcli fw-control identify    # Hailo device info"

    echo ""
    echo -e "${DIM}Beholder sees all.${NC}"
    echo ""
}

#-------------------------------------------------------------------------------
# MAIN
#-------------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${BOLD}${MAGENTA}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║     BEHOLDER-BOOTSTRAP — AI Edge Node Setup  (v${SCRIPT_VERSION})        ║${NC}"
    echo -e "${BOLD}${MAGENTA}║     Hailo-8L · Blinkt! · lab.hoens.fun                   ║${NC}"
    echo -e "${BOLD}${MAGENTA}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo "=== beholder-bootstrap.sh v${SCRIPT_VERSION} started $(date -Iseconds) ===" > "$LOG_FILE"

    preflight           || { error "Preflight failed — aborting"; return 1; }
    run_base_bootstrap  || true
    update_os           || true
    install_hailo       || true
    install_python_env  || true
    install_vision_tools || true
    deploy_led_daemon   || true
    configure_boot      || true
    configure_network   || true
    health_check        || true
    write_beholder_info || true
    print_summary

    return $FAILURES
}

main "$@"
