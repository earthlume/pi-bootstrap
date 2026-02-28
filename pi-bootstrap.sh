#!/bin/bash
#===============================================================================
# pi-bootstrap.sh — Earthlume's ADHD-Friendly Pi Shell Setup
# Version: 20
#
# WHAT:  Installs zsh + antidote + catppuccin-themed tooling with sane defaults
# WHY:   Reduce cognitive load; make CLI accessible and pleasant
# HOW:   Auto-detects hardware, picks light/standard/full tier
#
# USAGE: curl -fsSL <url> | bash
#    or: bash pi-bootstrap.sh [FLAGS]
#
# FLAGS:
#   --optimize         Apply safe system tweaks (swappiness, journald, PCIe)
#   --update-os        Run apt update/upgrade (default: skip)
#   --no-chsh          Don't change default shell to zsh
#   --no-motd          Don't install custom MOTD
#   --info-only        Just print system info and exit
#   --dry-run          Show what would happen without making changes
#   --tier-override=X  Force tier: light, standard, or full
#   --uninstall        Remove everything pi-bootstrap installed
#   --help             Show this help
#
# THREE TIERS:
#   light    — <1GB RAM: minimal prompt, lean plugins, ASCII mode
#   standard — 1-4GB RAM: full p10k prompt, nerdfont, btop
#   full     — >=4GB AND arm64: starship, eza, delta, dust, glow, lazygit,
#              lazydocker, fastfetch, zellij — the whole enchilada
#
# ARCHITECTURE:
#   - Antidote plugin manager (NOT oh-my-zsh)
#   - Starship prompt on full tier, Powerlevel10k on light/standard
#   - tmux on all tiers, Zellij on full tier (arm64 only)
#   - Catppuccin Mocha theme across all tools
#   - Modular aliases in ~/.config/zsh/aliases/
#
# DOMAIN: lab.hoens.fun
#===============================================================================

main() {

set -euo pipefail

#-------------------------------------------------------------------------------
# PINNED TOOL VERSIONS
# Change these to upgrade. Never use "latest" — reproducibility matters.
#-------------------------------------------------------------------------------
PIN_ZELLIJ="v0.41.2"
PIN_EZA="v0.20.14"
PIN_DELTA="0.18.2"
PIN_DUST="v1.1.1"
PIN_GLOW="v2.0.0"
PIN_LAZYGIT="v0.44.1"
PIN_LAZYDOCKER="v0.23.3"
PIN_FASTFETCH="2.31.0"

#-------------------------------------------------------------------------------
# CONFIGURATION
#-------------------------------------------------------------------------------
VERSION=20
BACKUP_DIR="$HOME/.pi-bootstrap-backups/$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$HOME/.adhd-bootstrap.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# Status tracking
declare -A STATUS
FAILURES=0

# Globals populated by detect_system
PI_MODEL=""
PI_SOC=""
RAM_MB=0
DPKG_ARCH=""
UNAME_ARCH=""
OS_NAME=""
OS_VERSION_ID=""
OS_VERSION_CODENAME=""
KERNEL=""
TIER=""
HAS_PCIE=false
BOOT_CONFIG=""

#-------------------------------------------------------------------------------
# PARSE ARGUMENTS
#-------------------------------------------------------------------------------
DO_OPTIMIZE=false
DO_UPDATE=false
DO_CHSH=true
DO_MOTD=true
INFO_ONLY=false
DRY_RUN=false
TIER_OVERRIDE=""
DO_UNINSTALL=false

for arg in "$@"; do
    case $arg in
        --optimize)          DO_OPTIMIZE=true ;;
        --update-os)         DO_UPDATE=true ;;
        --no-chsh)           DO_CHSH=false ;;
        --no-motd)           DO_MOTD=false ;;
        --info-only)         INFO_ONLY=true ;;
        --dry-run)           DRY_RUN=true ;;
        --tier-override=*)   TIER_OVERRIDE="${arg#*=}" ;;
        --uninstall)         DO_UNINSTALL=true ;;
        --help|-h)
            cat <<HELPEOF
Usage: $0 [FLAGS]

Flags:
  --optimize          Apply safe system tweaks (swappiness, journald, PCIe)
  --update-os         Run apt update/upgrade (kernel packages held)
  --no-chsh           Don't change default shell to zsh
  --no-motd           Don't install custom MOTD
  --info-only         Just print system info and exit
  --dry-run           Show what would happen without making changes
  --tier-override=X   Force tier: light, standard, or full
  --uninstall         Remove everything pi-bootstrap installed
  --help              Show this help

Tiers:
  light     <1GB RAM: minimal prompt, lean plugins
  standard  1-4GB RAM: full p10k, nerdfont, btop
  full      >=4GB + arm64: starship, eza, delta, zellij, etc.

HELPEOF
            return 0
            ;;
        *) echo -e "${YELLOW}Warning: Unknown flag: $arg${NC}" >&2 ;;
    esac
done

# Validate tier override
if [[ -n "$TIER_OVERRIDE" ]]; then
    case "$TIER_OVERRIDE" in
        light|standard|full) : ;;
        *) echo -e "${RED}Error: --tier-override must be light, standard, or full${NC}" >&2; return 1 ;;
    esac
fi

#-------------------------------------------------------------------------------
# LOGGING HELPERS
#-------------------------------------------------------------------------------
log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[ok]${NC} $*" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[!!]${NC} $*" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERR]${NC} $*" | tee -a "$LOG_FILE"
}

header() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}======================================================================${NC}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}  $*${NC}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}======================================================================${NC}" | tee -a "$LOG_FILE"
}

# Spinner — run a command with animated braille progress indicator
# Usage: spin "Descriptive label" command arg1 arg2 ...
# Returns the command's exit code. Output goes to log file.
# DRY_RUN aware: prints label and returns 0 without running.
spin() {
    local label="$1"
    shift

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} $label" | tee -a "$LOG_FILE"
        return 0
    fi

    local frames=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
    local start=$SECONDS

    # Run command in background, redirect output to log
    ( "$@" ) >> "$LOG_FILE" 2>&1 &
    local pid=$!

    # Animate while process runs
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(( SECONDS - start ))
        local mins=$(( elapsed / 60 ))
        local secs=$(( elapsed % 60 ))
        printf "\r  ${CYAN}%s${NC} %s ${DIM}%d:%02d${NC} " "${frames[i++ % ${#frames[@]}]}" "$label" "$mins" "$secs"
        sleep 0.1
    done

    # Get exit code
    local rc=0
    wait "$pid" || rc=$?
    local elapsed=$(( SECONDS - start ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))

    # Clear spinner line and print result
    printf "\r%-${COLUMNS:-80}s\r" ""
    if [[ $rc -eq 0 ]]; then
        success "$label ${DIM}(${mins}m ${secs}s)${NC}"
    else
        error "$label failed ${DIM}(${mins}m ${secs}s)${NC}"
    fi

    return $rc
}

# Track step status
track_status() {
    local step="$1"
    local result="$2"  # "OK" or "FAIL" or "SKIP"
    STATUS["$step"]="$result"
    if [[ "$result" == "FAIL" ]]; then
        ((FAILURES++)) || true
    fi
}


#-------------------------------------------------------------------------------
# HARDWARE DETECTION
#-------------------------------------------------------------------------------
detect_system() {
    header "DETECTING HARDWARE"

    # Pi model from device tree
    if [[ -f /proc/device-tree/model ]]; then
        PI_MODEL=$(tr -d '\0' < /proc/device-tree/model)
    elif grep -q "Model" /proc/cpuinfo 2>/dev/null; then
        PI_MODEL=$(grep "Model" /proc/cpuinfo | cut -d: -f2 | xargs)
    else
        PI_MODEL="Unknown (not a Pi?)"
    fi
    log "Model: $PI_MODEL"

    # SoC detection from device tree compatible string
    if [[ -f /proc/device-tree/compatible ]]; then
        local compat
        compat=$(tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null | head -5 | tr '\n' ' ')
        case "$compat" in
            *bcm2712*) PI_SOC="bcm2712 (Pi 5)" ;;
            *bcm2711*) PI_SOC="bcm2711 (Pi 4)" ;;
            *bcm2837*) PI_SOC="bcm2837 (Pi 3/Zero 2W)" ;;
            *bcm2836*) PI_SOC="bcm2836 (Pi 2)" ;;
            *bcm2835*) PI_SOC="bcm2835 (Pi 1/Zero)" ;;
            *)         PI_SOC="unknown ($compat)" ;;
        esac
    else
        PI_SOC="unknown (no device-tree)"
    fi
    log "SoC: $PI_SOC"

    # RAM in MB
    local ram_kb
    ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    RAM_MB=$((ram_kb / 1024))
    log "RAM: ${RAM_MB} MB"

    # Architecture — dpkg for package decisions, uname for binary downloads
    DPKG_ARCH=$(dpkg --print-architecture 2>/dev/null || echo "unknown")
    UNAME_ARCH=$(uname -m)
    log "Architecture: dpkg=$DPKG_ARCH uname=$UNAME_ARCH"

    # OS info
    if [[ -f /etc/os-release ]]; then
        OS_NAME=$(. /etc/os-release && echo "${PRETTY_NAME:-Unknown}")
        OS_VERSION_ID=$(. /etc/os-release && echo "${VERSION_ID:-unknown}")
        OS_VERSION_CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")
    else
        OS_NAME="Unknown"
        OS_VERSION_ID="unknown"
        OS_VERSION_CODENAME="unknown"
    fi
    log "OS: $OS_NAME"

    # Kernel
    KERNEL=$(uname -r)
    log "Kernel: $KERNEL"

    # Storage
    read -r ROOT_SIZE ROOT_AVAIL ROOT_USED_PCT <<< "$(df -h / | awk 'NR==2 {print $2, $4, $5}')"
    log "Root filesystem: $ROOT_SIZE total, $ROOT_AVAIL available ($ROOT_USED_PCT used)"

    # 3-tier logic
    if [[ -n "$TIER_OVERRIDE" ]]; then
        TIER="$TIER_OVERRIDE"
        log "Tier override: ${BOLD}$TIER${NC}"
    elif [[ $RAM_MB -ge 4000 && "$DPKG_ARCH" == "arm64" ]]; then
        TIER="full"
    elif [[ $RAM_MB -ge 1000 ]]; then
        TIER="standard"
    else
        TIER="light"
    fi
    log "Selected tier: ${BOLD}$TIER${NC}"

    # PCIe detection
    HAS_PCIE=false
    if compgen -G "/sys/bus/pci/devices/*" >/dev/null 2>&1; then
        HAS_PCIE=true
    fi
    log "PCIe detected: $HAS_PCIE"

    # Boot config location
    if [[ -f /boot/firmware/config.txt ]]; then
        BOOT_CONFIG="/boot/firmware/config.txt"
    elif [[ -f /boot/config.txt ]]; then
        BOOT_CONFIG="/boot/config.txt"
    else
        BOOT_CONFIG=""
    fi
    log "Boot config: ${BOOT_CONFIG:-not found}"

    track_status "Hardware Detection" "OK"
}

#-------------------------------------------------------------------------------
# EXTENDED HARDWARE DETECTION (for --info-only)
#-------------------------------------------------------------------------------
detect_extended_hardware() {
    log "Gathering extended system info..."

    # CPU info
    CPU_CORES=$(nproc 2>/dev/null || echo "?")
    CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "ARM")

    # Temperature
    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        local temp_raw
        temp_raw=$(cat /sys/class/thermal/thermal_zone0/temp)
        TEMP_C=$((temp_raw / 1000))
    else
        TEMP_C="N/A"
    fi

    # Throttling status
    if command -v vcgencmd &>/dev/null; then
        THROTTLE_STATUS=$(timeout 3 vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo "N/A")
    else
        THROTTLE_STATUS="vcgencmd not available"
    fi

    # Camera detection
    if compgen -G "/dev/video*" > /dev/null 2>&1; then
        CAMERA_DEVICES=$(ls /dev/video* 2>/dev/null | tr '\n' ' ')
        [[ -z "$CAMERA_DEVICES" ]] && CAMERA_DEVICES="none detected"
    else
        CAMERA_DEVICES="none detected"
    fi
    if command -v libcamera-hello &>/dev/null; then
        LIBCAMERA="installed"
    else
        LIBCAMERA="not installed"
    fi

    # I2C status
    if [[ -e /dev/i2c-1 ]]; then
        I2C_STATUS="enabled"
        if command -v i2cdetect &>/dev/null; then
            I2C_DEVICES=$(timeout 3 i2cdetect -y 1 2>/dev/null | grep -c "^[0-9]" || echo "0")
            I2C_DEVICES="${I2C_DEVICES} bus(es) scanned"
        else
            I2C_DEVICES="i2c-tools not installed"
        fi
    else
        I2C_STATUS="disabled"
        I2C_DEVICES="N/A"
    fi

    # SPI status
    if [[ -e /dev/spidev0.0 ]]; then
        SPI_STATUS="enabled"
    else
        SPI_STATUS="disabled"
    fi

    # GPIO status
    if [[ -d /sys/class/gpio ]]; then
        GPIO_STATUS="available"
    else
        GPIO_STATUS="not available"
    fi

    # USB devices
    if command -v lsusb &>/dev/null; then
        USB_DEVICES=$(timeout 5 lsusb 2>/dev/null | wc -l || echo "0")
        USB_DEVICE_LIST=$(timeout 5 lsusb 2>/dev/null | grep -vi "hub" | head -5 || echo "none")
    else
        USB_DEVICES="lsusb not available"
        USB_DEVICE_LIST=""
    fi

    # Network interfaces
    NET_INTERFACES=$(timeout 3 ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v lo | tr '\n' ' ' || echo "unknown")

    # WiFi
    if command -v iwconfig &>/dev/null; then
        WIFI_INTERFACE=$(timeout 3 iwconfig 2>/dev/null | grep -o "^wlan[0-9]" | head -1 || echo "none")
    else
        WIFI_INTERFACE=$(timeout 3 ip link show 2>/dev/null | grep -o "wlan[0-9]" | head -1 || echo "none")
    fi

    # Bluetooth
    if command -v bluetoothctl &>/dev/null; then
        BT_STATUS="available"
    elif [[ -d /sys/class/bluetooth ]]; then
        BT_STATUS="available (no bluetoothctl)"
    else
        BT_STATUS="not detected"
    fi

    # Boot overlays
    if [[ -n "${BOOT_CONFIG:-}" && -f "$BOOT_CONFIG" ]]; then
        BOOT_OVERLAYS=$(grep "^dtoverlay=" "$BOOT_CONFIG" 2>/dev/null | cut -d= -f2 | tr '\n' ', ' || echo "none")
        [[ -z "$BOOT_OVERLAYS" ]] && BOOT_OVERLAYS="none configured"
    else
        BOOT_OVERLAYS="unknown"
    fi
}

#-------------------------------------------------------------------------------
# PRINT SYSTEM INFO (--info-only diagnostic dump)
#-------------------------------------------------------------------------------
print_system_info() {
    detect_system
    detect_extended_hardware

    header "SYSTEM INFO — PASTE THIS BACK TO COSMO"

    cat <<EOF

\`\`\`
======================================================================
SYSTEM PROFILE — $(date -Iseconds)
======================================================================

HARDWARE
--------
PI_MODEL:     $PI_MODEL
PI_SOC:       $PI_SOC
DPKG_ARCH:    $DPKG_ARCH
UNAME_ARCH:   $UNAME_ARCH
CPU:          $CPU_MODEL ($CPU_CORES cores)
RAM_MB:       $RAM_MB
TEMP:         ${TEMP_C}°C
THROTTLE:     $THROTTLE_STATUS
TIER:         $TIER

STORAGE
-------
ROOT_SIZE:    $ROOT_SIZE
ROOT_AVAIL:   $ROOT_AVAIL
ROOT_USED:    $ROOT_USED_PCT

OS
--
OS:           $OS_NAME
KERNEL:       $KERNEL
HOSTNAME:     $(hostname)
USER:         $(whoami)
BOOT_CONFIG:  ${BOOT_CONFIG:-not found}

INTERFACES
----------
I2C:          $I2C_STATUS ($I2C_DEVICES)
SPI:          $SPI_STATUS
GPIO:         $GPIO_STATUS
PCIe:         $HAS_PCIE
NETWORK:      $NET_INTERFACES
WIFI:         $WIFI_INTERFACE
BLUETOOTH:    $BT_STATUS

PERIPHERALS
-----------
CAMERA:       $CAMERA_DEVICES
LIBCAMERA:    $LIBCAMERA
USB_DEVICES:  $USB_DEVICES
OVERLAYS:     $BOOT_OVERLAYS

USB DEVICE LIST:
$USB_DEVICE_LIST
======================================================================
\`\`\`

EOF

    # Pi 5 specific info
    if [[ "${PI_MODEL,,}" =~ pi\ 5 ]]; then
        echo "--- Pi 5 Specific ---"
        if [[ -n "$BOOT_CONFIG" && -f "$BOOT_CONFIG" ]]; then
            echo "PCIe config:"
            grep -i pcie "$BOOT_CONFIG" 2>/dev/null || echo "(no pcie settings found)"
        fi
    fi
}


#-------------------------------------------------------------------------------
# IDEMPOTENT HELPERS
#-------------------------------------------------------------------------------

# Check if a command exists before trying to install
install_if_missing() {
    local cmd="$1"
    shift
    if command -v "$cmd" &>/dev/null; then
        success "$cmd already installed"
        return 0
    fi
    "$@"
}

# Check dpkg -s for each package, batch-install the missing ones
ensure_apt_packages() {
    local label="$1"
    shift
    local missing=()

    for pkg in "$@"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        success "$label: all ${#@} packages already installed"
        return 0
    fi

    log "$label: installing ${#missing[@]} missing package(s): ${missing[*]}"
    spin "$label (${#missing[@]} packages)" \
        "${APT_ENV[@]}" apt-get install -y -qq "${APT_DPKG_OPTS[@]}" "${missing[@]}"
}

# Add a line to a file only if it doesn't already exist
ensure_line_in_file() {
    local file="$1"
    local line="$2"
    if [[ -f "$file" ]] && grep -qF "$line" "$file" 2>/dev/null; then
        return 0
    fi
    echo "$line" >> "$file"
}

# Architecture-aware GitHub binary downloader
# Usage: download_github_release repo version asset_pattern binary_name install_dir
#   repo          — e.g., "eza-community/eza"
#   version       — e.g., "v0.20.14"
#   asset_pattern — e.g., "eza_aarch64-unknown-linux-gnu.tar.gz" (use UNAME_ARCH)
#   binary_name   — e.g., "eza" (name of binary inside archive or the raw binary)
#   install_dir   — e.g., "/usr/local/bin"
#
# Handles: .tar.gz (extract + find binary), .deb (dpkg -i), raw binary
# Skips if binary already exists at correct version
download_github_release() {
    local repo="$1"
    local version="$2"
    local asset_pattern="$3"
    local binary_name="$4"
    local install_dir="${5:-/usr/local/bin}"

    # Skip if binary exists and version matches
    if command -v "$binary_name" &>/dev/null; then
        local current_ver
        current_ver=$("$binary_name" --version 2>/dev/null | head -1 || echo "")
        # Strip leading 'v' for comparison
        local pin_clean="${version#v}"
        if [[ "$current_ver" == *"$pin_clean"* ]]; then
            success "$binary_name $version already installed"
            return 0
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would download $binary_name $version from $repo" | tee -a "$LOG_FILE"
        return 0
    fi

    local url="https://github.com/${repo}/releases/download/${version}/${asset_pattern}"
    local tmpdir
    tmpdir=$(mktemp -d)
    local tmpfile="${tmpdir}/${asset_pattern}"

    log "Downloading $binary_name $version from $repo..."
    if ! curl -fsSL -o "$tmpfile" "$url" 2>>"$LOG_FILE"; then
        error "Failed to download $binary_name from $url"
        rm -rf "$tmpdir"
        return 1
    fi

    # Handle based on file type
    case "$asset_pattern" in
        *.deb)
            sudo dpkg -i "$tmpfile" >> "$LOG_FILE" 2>&1 || {
                # Try to fix dependencies
                sudo apt-get install -f -y -qq >> "$LOG_FILE" 2>&1
            }
            ;;
        *.tar.gz|*.tgz)
            tar xzf "$tmpfile" -C "$tmpdir" >> "$LOG_FILE" 2>&1
            # Find the binary in the extracted contents
            local found_bin
            found_bin=$(find "$tmpdir" -name "$binary_name" -type f -executable 2>/dev/null | head -1)
            if [[ -z "$found_bin" ]]; then
                # Try non-executable files (some archives don't set +x)
                found_bin=$(find "$tmpdir" -name "$binary_name" -type f 2>/dev/null | head -1)
            fi
            if [[ -n "$found_bin" ]]; then
                sudo install -m 755 "$found_bin" "${install_dir}/${binary_name}"
            else
                error "Could not find $binary_name binary in archive"
                rm -rf "$tmpdir"
                return 1
            fi
            ;;
        *)
            # Raw binary
            sudo install -m 755 "$tmpfile" "${install_dir}/${binary_name}"
            ;;
    esac

    rm -rf "$tmpdir"
    success "$binary_name $version installed to $install_dir"
    return 0
}

#-------------------------------------------------------------------------------
# BACKUP CONFIGS
#-------------------------------------------------------------------------------
backup_configs() {
    header "BACKING UP EXISTING CONFIGS"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would back up configs to $BACKUP_DIR" | tee -a "$LOG_FILE"
        track_status "Backup Configs" "SKIP"
        return 0
    fi

    mkdir -p "$BACKUP_DIR"

    local files_to_backup=(
        "$HOME/.zshrc"
        "$HOME/.bashrc"
        "$HOME/.p10k.zsh"
        "$HOME/.tmux.conf"
        "$HOME/.config/starship.toml"
    )

    local backed_up=0
    for file in "${files_to_backup[@]}"; do
        if [[ -f "$file" ]]; then
            cp "$file" "$BACKUP_DIR/"
            success "Backed up: $file"
            ((backed_up++)) || true
        fi
    done

    log "Backups stored in: $BACKUP_DIR"

    if [[ $backed_up -gt 0 ]]; then
        track_status "Backup Configs" "OK"
    else
        log "No existing configs to back up"
        track_status "Backup Configs" "SKIP"
    fi
}

#-------------------------------------------------------------------------------
# VERIFY TIME SYNC (clock drift breaks TLS, apt signatures, logs)
#-------------------------------------------------------------------------------
verify_time_sync() {
    header "VERIFYING TIME SYNC"

    local sync_ok=false

    # Check systemd-timesyncd
    if timedatectl show --property=NTP --value 2>/dev/null | grep -qi "yes"; then
        local synced
        synced=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "no")
        if [[ "$synced" == "yes" ]]; then
            success "Time synced via systemd-timesyncd"
            sync_ok=true
        else
            warn "timesyncd active but not yet synchronized — may need a moment"
        fi
    elif systemctl is-active --quiet chronyd 2>/dev/null; then
        success "Time synced via chrony"
        sync_ok=true
    else
        warn "NTP not active — enabling systemd-timesyncd..."
        if [[ "$DRY_RUN" == true ]]; then
            echo -e "  ${CYAN}[DRY RUN]${NC} Would enable systemd-timesyncd" | tee -a "$LOG_FILE"
        elif sudo timedatectl set-ntp true 2>/dev/null; then
            success "systemd-timesyncd enabled (will sync shortly)"
        else
            warn "Could not enable NTP — clock may drift"
        fi
    fi

    log "System time: $(date -Iseconds)"

    if [[ "$sync_ok" == true ]]; then
        track_status "Time Sync" "OK"
    else
        track_status "Time Sync" "SKIP"
    fi
}

#-------------------------------------------------------------------------------
# UPDATE OS
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

update_os() {
    header "UPDATING OS PACKAGES"

    if [[ "$DO_UPDATE" == false ]]; then
        log "Skipping OS update (use --update-os to enable)"
        track_status "OS Update" "SKIP"
        return 0
    fi

    # Hold kernel packages to prevent DKMS breakage
    log "Holding kernel/firmware packages..."
    local held=()
    for pkg in "${KERNEL_HOLD_PKGS[@]}"; do
        if dpkg -l "$pkg" &>/dev/null; then
            if [[ "$DRY_RUN" == true ]]; then
                echo -e "  ${CYAN}[DRY RUN]${NC} Would hold $pkg" | tee -a "$LOG_FILE"
            else
                sudo apt-mark hold "$pkg" &>/dev/null && held+=("$pkg")
            fi
        fi
    done
    if [[ ${#held[@]} -gt 0 ]]; then
        success "Held ${#held[@]} kernel pkg(s): ${held[*]}"
    fi

    # Update package lists
    if ! spin "Refreshing package lists" \
        "${APT_ENV[@]}" apt-get update -qq; then
        track_status "OS Update" "FAIL"
        return 1
    fi

    # Upgrade packages
    if ! spin "Upgrading packages" \
        "${APT_ENV[@]}" apt-get upgrade -y -qq "${APT_DPKG_OPTS[@]}"; then
        track_status "OS Update" "FAIL"
        return 1
    fi
    track_status "OS Update" "OK"

    # Check if reboot needed
    if [[ -f /var/run/reboot-required ]]; then
        warn "Reboot required after updates"
    fi
}


#-------------------------------------------------------------------------------
# PACKAGE INSTALLATION — CORE (all tiers)
#-------------------------------------------------------------------------------
install_core_packages() {
    header "INSTALLING CORE PACKAGES"

    # Ensure package lists are fresh if update_os didn't run
    if [[ "$DO_UPDATE" == false ]]; then
        spin "Refreshing package lists" \
            "${APT_ENV[@]}" apt-get update -qq || true
    fi

    local core_packages=(
        zsh
        git
        curl
        wget
        fontconfig
        tmux
        fzf
        jq
        stow
        figlet
        fortune-mod
        tree
        bat
        fd-find
        ripgrep
        htop
        ncdu
        duf
        tealdeer
        neovim
        sqlite3
        python3-venv
    )

    if ! ensure_apt_packages "Core packages" "${core_packages[@]}"; then
        track_status "Install Packages" "FAIL"
        return 1
    fi

    # Create symlinks for Debian-renamed binaries
    if [[ "$DRY_RUN" != true ]]; then
        if command -v batcat &>/dev/null && [[ ! -e /usr/local/bin/bat ]]; then
            sudo ln -sf "$(command -v batcat)" /usr/local/bin/bat
            success "Created symlink: bat -> batcat"
        fi
        if command -v fdfind &>/dev/null && [[ ! -e /usr/local/bin/fd ]]; then
            sudo ln -sf "$(command -v fdfind)" /usr/local/bin/fd
            success "Created symlink: fd -> fdfind"
        fi
    else
        echo -e "  ${CYAN}[DRY RUN]${NC} Would create bat/fd symlinks" | tee -a "$LOG_FILE"
    fi

    track_status "Install Packages" "OK"
}

#-------------------------------------------------------------------------------
# PACKAGE INSTALLATION — STANDARD (standard + full tiers)
#-------------------------------------------------------------------------------
install_standard_packages() {
    if [[ "$TIER" == "light" ]]; then
        return 0
    fi

    header "INSTALLING STANDARD TIER PACKAGES"

    local std_packages=(
        btop
    )

    ensure_apt_packages "Standard packages" "${std_packages[@]}" || true
}

#-------------------------------------------------------------------------------
# PACKAGE INSTALLATION — FULL (full tier, GitHub binaries)
#-------------------------------------------------------------------------------
install_full_packages() {
    if [[ "$TIER" != "full" ]]; then
        return 0
    fi

    header "INSTALLING FULL TIER PACKAGES (GitHub binaries)"

    local arch_eza=""
    local arch_dust=""
    local arch_glow=""
    local arch_lazygit=""
    local arch_lazydocker=""

    case "$UNAME_ARCH" in
        aarch64)
            arch_eza="aarch64-unknown-linux-gnu"
            arch_dust="aarch64-unknown-linux-musl"
            arch_glow="arm64"
            arch_lazygit="arm64"
            arch_lazydocker="arm64"
            ;;
        armv7l)
            arch_eza="armv7-unknown-linux-gnueabihf"
            arch_dust="armv7-unknown-linux-gnueabihf"
            arch_glow="armv7"
            arch_lazygit="armv6"
            arch_lazydocker="armv7"
            ;;
        armv6l)
            arch_eza="arm-unknown-linux-gnueabihf"
            arch_dust="arm-unknown-linux-gnueabihf"
            arch_glow="armv6"
            arch_lazygit="armv6"
            arch_lazydocker="armv6"
            ;;
        *)
            warn "Unsupported architecture for full-tier binaries: $UNAME_ARCH"
            return 1
            ;;
    esac

    # eza — modern ls replacement
    spin "Installing eza $PIN_EZA" \
        download_github_release "eza-community/eza" "$PIN_EZA" \
        "eza_${arch_eza}.tar.gz" "eza" "/usr/local/bin" || true

    # delta — better git diff (.deb)
    spin "Installing delta $PIN_DELTA" \
        download_github_release "dandavison/delta" "$PIN_DELTA" \
        "git-delta_${PIN_DELTA}_${DPKG_ARCH}.deb" "delta" "/usr/local/bin" || true

    # dust — better du
    spin "Installing dust $PIN_DUST" \
        download_github_release "bootandy/dust" "$PIN_DUST" \
        "dust-${PIN_DUST}-${arch_dust}.tar.gz" "dust" "/usr/local/bin" || true

    # glow — terminal markdown viewer
    spin "Installing glow $PIN_GLOW" \
        download_github_release "charmbracelet/glow" "$PIN_GLOW" \
        "glow_${PIN_GLOW#v}_linux_${arch_glow}.tar.gz" "glow" "/usr/local/bin" || true

    # lazygit — terminal git UI
    spin "Installing lazygit $PIN_LAZYGIT" \
        download_github_release "jesseduffield/lazygit" "$PIN_LAZYGIT" \
        "lazygit_${PIN_LAZYGIT#v}_Linux_${arch_lazygit}.tar.gz" "lazygit" "/usr/local/bin" || true

    # lazydocker — terminal docker UI
    spin "Installing lazydocker $PIN_LAZYDOCKER" \
        download_github_release "jesseduffield/lazydocker" "$PIN_LAZYDOCKER" \
        "lazydocker_${PIN_LAZYDOCKER#v}_Linux_${arch_lazydocker}.tar.gz" "lazydocker" "/usr/local/bin" || true

    # fastfetch — system info (.deb)
    spin "Installing fastfetch $PIN_FASTFETCH" \
        download_github_release "fastfetch-cli/fastfetch" "$PIN_FASTFETCH" \
        "fastfetch-linux-${DPKG_ARCH}.deb" "fastfetch" "/usr/local/bin" || true
}

#-------------------------------------------------------------------------------
# INSTALL ZOXIDE — all tiers
#-------------------------------------------------------------------------------
install_zoxide() {
    header "INSTALLING ZOXIDE"

    if command -v zoxide &>/dev/null; then
        success "zoxide already installed ($(zoxide --version 2>/dev/null || echo 'unknown'))"
        return 0
    fi

    # Try apt first
    if apt-cache show zoxide &>/dev/null 2>&1; then
        spin "Installing zoxide via apt" \
            "${APT_ENV[@]}" apt-get install -y -qq zoxide && return 0
    fi

    # Fallback: GitHub binary
    local zoxide_arch=""
    case "$UNAME_ARCH" in
        aarch64)  zoxide_arch="aarch64-unknown-linux-musl" ;;
        armv7l)   zoxide_arch="armv7-unknown-linux-musleabihf" ;;
        armv6l)   zoxide_arch="arm-unknown-linux-musleabihf" ;;
        *)        warn "Cannot install zoxide for $UNAME_ARCH"; return 1 ;;
    esac

    spin "Installing zoxide from GitHub" \
        download_github_release "ajeetdsouza/zoxide" "v0.9.6" \
        "zoxide-0.9.6-${zoxide_arch}.tar.gz" "zoxide" "/usr/local/bin" || true
}

#-------------------------------------------------------------------------------
# INSTALL UV — all tiers (Python package manager)
#-------------------------------------------------------------------------------
install_uv() {
    header "INSTALLING UV"

    if command -v uv &>/dev/null; then
        success "uv already installed ($(uv --version 2>/dev/null || echo 'unknown'))"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would install uv from astral.sh" | tee -a "$LOG_FILE"
        return 0
    fi

    log "Installing uv (Python package manager)..."
    local uv_script
    uv_script=$(curl -fsSL https://astral.sh/uv/install.sh 2>/dev/null) || true
    if [[ -n "$uv_script" ]]; then
        if spin "Installing uv" sh -c "$uv_script"; then
            success "uv installed"
        else
            warn "uv install failed (non-critical, can install later)"
        fi
    else
        warn "Could not download uv installer (non-critical)"
    fi
}

#-------------------------------------------------------------------------------
# INSTALL STARSHIP — full tier only
#-------------------------------------------------------------------------------
install_starship() {
    if [[ "$TIER" != "full" ]]; then
        return 0
    fi

    header "INSTALLING STARSHIP PROMPT"

    if command -v starship &>/dev/null; then
        success "starship already installed ($(starship --version 2>/dev/null | head -1 || echo 'unknown'))"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would install starship via official installer" | tee -a "$LOG_FILE"
        return 0
    fi

    local starship_script
    starship_script=$(curl -fsSL https://starship.rs/install.sh 2>/dev/null) || true
    if [[ -n "$starship_script" ]]; then
        if spin "Installing starship" sh -c "$starship_script -- --yes"; then
            success "starship installed"
        else
            warn "starship install failed"
        fi
    else
        warn "Could not download starship installer"
    fi
}

#-------------------------------------------------------------------------------
# INSTALL ZELLIJ — full tier, arm64 only
#-------------------------------------------------------------------------------
install_zellij() {
    if [[ "$TIER" != "full" || "$DPKG_ARCH" != "arm64" ]]; then
        return 0
    fi

    header "INSTALLING ZELLIJ"

    if command -v zellij &>/dev/null; then
        local current_ver
        current_ver=$(zellij --version 2>/dev/null | awk '{print $2}' || echo "")
        if [[ "$current_ver" == "${PIN_ZELLIJ#v}" ]]; then
            success "zellij ${PIN_ZELLIJ} already installed"
            return 0
        fi
    fi

    spin "Installing zellij $PIN_ZELLIJ" \
        download_github_release "zellij-org/zellij" "$PIN_ZELLIJ" \
        "zellij-aarch64-unknown-linux-musl.tar.gz" "zellij" "/usr/local/bin" || true
}


#-------------------------------------------------------------------------------
# SHELL FRAMEWORK — ANTIDOTE
#-------------------------------------------------------------------------------
install_antidote() {
    header "INSTALLING ANTIDOTE PLUGIN MANAGER"

    if [[ -d "$HOME/.antidote" ]]; then
        success "Antidote already installed"
        # Pull latest if not dry run
        if [[ "$DRY_RUN" != true ]]; then
            (cd "$HOME/.antidote" && git pull --quiet 2>/dev/null) || true
        fi
    else
        if [[ "$DRY_RUN" == true ]]; then
            echo -e "  ${CYAN}[DRY RUN]${NC} Would clone antidote to ~/.antidote" | tee -a "$LOG_FILE"
        else
            spin "Cloning antidote" \
                git clone --depth=1 https://github.com/mattmc3/antidote.git "$HOME/.antidote" || {
                    track_status "Antidote" "FAIL"
                    return 1
                }
        fi
    fi

    # Check for oh-my-zsh and warn about migration
    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        warn "Found ~/.oh-my-zsh — you're migrating from oh-my-zsh to antidote."
        warn "oh-my-zsh will NOT be loaded. Remove ~/.oh-my-zsh when ready."
    fi

    track_status "Antidote" "OK"
}

#-------------------------------------------------------------------------------
# CREATE PLUGIN LIST
#-------------------------------------------------------------------------------
create_plugin_list() {
    header "CREATING PLUGIN LIST"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would write ~/.zsh_plugins.txt" | tee -a "$LOG_FILE"
        track_status "Plugins" "OK"
        return 0
    fi

    cat > "$HOME/.zsh_plugins.txt" <<'PLUGINLIST'
# Antidote plugin list — generated by pi-bootstrap v20
# Each line is a GitHub repo or a local path.

# Completions (load first)
zsh-users/zsh-completions

# Autosuggestions (inline ghost text from history)
zsh-users/zsh-autosuggestions

# Syntax highlighting (colors as you type)
zsh-users/zsh-syntax-highlighting

# "You should use" — reminds you about aliases you forgot
MichaelAquilina/zsh-you-should-use

# Abbreviations (like fish abbreviations)
olets/zsh-abbr kind:defer
PLUGINLIST

    success "Plugin list written to ~/.zsh_plugins.txt"
    track_status "Plugins" "OK"
}

#-------------------------------------------------------------------------------
# PROMPT — POWERLEVEL10K (light/standard tiers)
#-------------------------------------------------------------------------------
install_p10k() {
    if [[ "$TIER" == "full" ]]; then
        return 0
    fi

    header "INSTALLING POWERLEVEL10K"

    local p10k_dir="$HOME/.powerlevel10k"

    if [[ -d "$p10k_dir" ]]; then
        success "powerlevel10k already present"
        track_status "Powerlevel10k" "SKIP"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would clone powerlevel10k to ~/.powerlevel10k" | tee -a "$LOG_FILE"
        track_status "Powerlevel10k" "OK"
        return 0
    fi

    if spin "Cloning powerlevel10k" \
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$p10k_dir"; then
        track_status "Powerlevel10k" "OK"
    else
        track_status "Powerlevel10k" "FAIL"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# INSTALL NERD FONTS (light/standard tiers for p10k)
#-------------------------------------------------------------------------------
install_fonts() {
    if [[ "$TIER" == "full" ]]; then
        return 0
    fi

    header "INSTALLING NERD FONTS"

    local font_dir="$HOME/.local/share/fonts"
    mkdir -p "$font_dir"

    local fonts=(
        "MesloLGS%20NF%20Regular.ttf"
        "MesloLGS%20NF%20Bold.ttf"
        "MesloLGS%20NF%20Italic.ttf"
        "MesloLGS%20NF%20Bold%20Italic.ttf"
    )

    local base_url="https://github.com/romkatv/powerlevel10k-media/raw/master"
    local font_failures=0

    for font in "${fonts[@]}"; do
        local decoded_font="${font//%20/ }"
        if [[ -f "$font_dir/$decoded_font" ]]; then
            continue
        fi
        if [[ "$DRY_RUN" == true ]]; then
            echo -e "  ${CYAN}[DRY RUN]${NC} Would download $decoded_font" | tee -a "$LOG_FILE"
        elif ! spin "Downloading $decoded_font" \
            curl -fsSL -o "$font_dir/$decoded_font" "$base_url/$font"; then
            ((font_failures++)) || true
        fi
    done

    # Rebuild font cache
    if [[ "$DRY_RUN" != true ]]; then
        spin "Rebuilding font cache" fc-cache -f "$font_dir" || true
    fi

    if [[ $font_failures -eq 0 ]]; then
        success "Fonts installed (configure your terminal to use 'MesloLGS NF')"
        track_status "Nerd Fonts" "OK"
    else
        warn "Some fonts failed to download"
        track_status "Nerd Fonts" "FAIL"
    fi
}

#-------------------------------------------------------------------------------
# GENERATE P10K CONFIG
#-------------------------------------------------------------------------------
generate_p10k_config() {
    if [[ "$TIER" == "full" ]]; then
        return 0
    fi

    header "GENERATING POWERLEVEL10K CONFIG"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would generate ~/.p10k.zsh for tier=$TIER" | tee -a "$LOG_FILE"
        track_status "P10k Config" "OK"
        return 0
    fi

    if [[ "$TIER" == "standard" ]]; then
        _generate_p10k_standard
    else
        _generate_p10k_light
    fi

    # Clear stale instant prompt cache
    rm -f "$HOME/.cache/p10k-instant-prompt-"*.zsh 2>/dev/null

    success ".p10k.zsh generated (tier: $TIER)"
    track_status "P10k Config" "OK"
}

_generate_p10k_standard() {
    cat > "$HOME/.p10k.zsh" <<'P10K_STD'
# Powerlevel10k config — standard tier (nerdfont, rich segments)
# Generated by pi-bootstrap v20

'builtin' 'local' '-a' 'p10k_config_opts'
[[ ! -o 'aliases'         ]] || p10k_config_opts+=('aliases')
[[ ! -o 'sh_glob'         ]] || p10k_config_opts+=('sh_glob')
[[ ! -o 'no_brace_expand' ]] || p10k_config_opts+=('no_brace_expand')
'builtin' 'setopt' 'no_aliases' 'no_sh_glob' 'brace_expand'

() {
  emulate -L zsh -o extended_glob

  unset -m '(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR'

  typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet

  # Left prompt: context, directory, git, newline, prompt char
  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
    context
    dir
    vcs
    newline
    prompt_char
  )

  # Right prompt: status, execution time, background jobs, time
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
    status
    command_execution_time
    background_jobs
    time
  )

  # Style
  typeset -g POWERLEVEL9K_MODE=nerdfont-complete
  typeset -g POWERLEVEL9K_PROMPT_ON_NEWLINE=false
  typeset -g POWERLEVEL9K_RPROMPT_ON_NEWLINE=false
  typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true

  # Directory
  typeset -g POWERLEVEL9K_SHORTEN_DIR_LENGTH=3
  typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_last
  typeset -g POWERLEVEL9K_DIR_FOREGROUND=31
  typeset -g POWERLEVEL9K_DIR_BACKGROUND=238

  # Git status colors
  typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=0
  typeset -g POWERLEVEL9K_VCS_CLEAN_BACKGROUND=2
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=0
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_BACKGROUND=3
  typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=0
  typeset -g POWERLEVEL9K_VCS_MODIFIED_BACKGROUND=3

  # Prompt character
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=2
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=1
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIINS_CONTENT_EXPANSION='❯'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VICMD_CONTENT_EXPANSION='❮'

  # Execution time (show if > 3s)
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_THRESHOLD=3
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=0
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_BACKGROUND=3

  # Time format
  typeset -g POWERLEVEL9K_TIME_FORMAT='%D{%H:%M}'
  typeset -g POWERLEVEL9K_TIME_FOREGROUND=0
  typeset -g POWERLEVEL9K_TIME_BACKGROUND=7

  # Context: show user@host on SSH or root
  typeset -g POWERLEVEL9K_CONTEXT_ROOT_FOREGROUND=1
  typeset -g POWERLEVEL9K_CONTEXT_ROOT_BACKGROUND=0
  typeset -g POWERLEVEL9K_CONTEXT_{REMOTE,REMOTE_SUDO}_FOREGROUND=3
  typeset -g POWERLEVEL9K_CONTEXT_{REMOTE,REMOTE_SUDO}_BACKGROUND=0
  typeset -g POWERLEVEL9K_CONTEXT_FOREGROUND=3
  typeset -g POWERLEVEL9K_CONTEXT_BACKGROUND=0
  typeset -g POWERLEVEL9K_CONTEXT_TEMPLATE='%n@%m'
  typeset -g POWERLEVEL9K_CONTEXT_{DEFAULT,SUDO}_{CONTENT,VISUAL_IDENTIFIER}_EXPANSION=

  # Status: show exit code on failure
  typeset -g POWERLEVEL9K_STATUS_OK=false
  typeset -g POWERLEVEL9K_STATUS_ERROR=true
  typeset -g POWERLEVEL9K_STATUS_ERROR_FOREGROUND=0
  typeset -g POWERLEVEL9K_STATUS_ERROR_BACKGROUND=1

  typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=off

  (( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
}

(( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
'builtin' 'unset' 'p10k_config_opts'
P10K_STD
}

_generate_p10k_light() {
    cat > "$HOME/.p10k.zsh" <<'P10K_LIGHT'
# Powerlevel10k config — light tier (ASCII, minimal, fast)
# Generated by pi-bootstrap v20

'builtin' 'local' '-a' 'p10k_config_opts'
[[ ! -o 'aliases'         ]] || p10k_config_opts+=('aliases')
[[ ! -o 'sh_glob'         ]] || p10k_config_opts+=('sh_glob')
[[ ! -o 'no_brace_expand' ]] || p10k_config_opts+=('no_brace_expand')
'builtin' 'setopt' 'no_aliases' 'no_sh_glob' 'brace_expand'

() {
  emulate -L zsh -o extended_glob

  unset -m '(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR'

  typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet

  # Minimal left prompt
  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
    dir
    vcs
    prompt_char
  )

  # Minimal right prompt
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
    status
  )

  # ASCII mode for compatibility
  typeset -g POWERLEVEL9K_MODE=ascii

  # Prompt char
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=2
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=1
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIINS_CONTENT_EXPANSION='>'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VICMD_CONTENT_EXPANSION='<'

  # Directory
  typeset -g POWERLEVEL9K_SHORTEN_DIR_LENGTH=2
  typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_last

  # Disable gitstatus for speed on low-end hardware
  typeset -g POWERLEVEL9K_DISABLE_GITSTATUS=true
  typeset -g POWERLEVEL9K_VCS_DISABLE_GITSTATUS_FORMATTING=true

  # Status only on error
  typeset -g POWERLEVEL9K_STATUS_OK=false
  typeset -g POWERLEVEL9K_STATUS_ERROR=true

  (( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
}

(( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
'builtin' 'unset' 'p10k_config_opts'
P10K_LIGHT
}


#-------------------------------------------------------------------------------
# GENERATE STARSHIP CONFIG — full tier
#-------------------------------------------------------------------------------
generate_starship_config() {
    if [[ "$TIER" != "full" ]]; then
        return 0
    fi

    header "GENERATING STARSHIP CONFIG"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would write ~/.config/starship.toml" | tee -a "$LOG_FILE"
        track_status "Starship Config" "OK"
        return 0
    fi

    mkdir -p "$HOME/.config"

    cat > "$HOME/.config/starship.toml" <<'STARSHIP_TOML'
# Starship prompt config — Catppuccin Mocha theme
# Generated by pi-bootstrap v20

# Catppuccin Mocha palette reference:
# rosewater=#f5e0dc flamingo=#f2cdcd pink=#f5c2e7 mauve=#cba6f7
# red=#f38ba8 maroon=#eba0ac peach=#fab387 yellow=#f9e2af
# green=#a6e3a1 teal=#94e2d5 sky=#89dceb sapphire=#74c7ec
# blue=#89b4fa lavender=#b4befe text=#cdd6f4 subtext1=#bac2de
# subtext0=#a6adc8 overlay2=#9399b2 overlay1=#7f849c overlay0=#6c7086
# surface2=#585b70 surface1=#45475a surface0=#313244
# base=#1e1e2e mantle=#181825 crust=#11111b

format = """
$username\
$hostname\
$directory\
$git_branch\
$git_status\
$cmd_duration\
$line_break\
$character"""

right_format = """$time"""

[character]
success_symbol = "[>](bold #a6e3a1)"
error_symbol = "[>](bold #f38ba8)"
vimcmd_symbol = "[<](bold #cba6f7)"

[username]
style_user = "bold #89b4fa"
style_root = "bold #f38ba8"
format = "[$user]($style) "
show_always = false

[hostname]
ssh_only = true
style = "bold #94e2d5"
format = "[@$hostname]($style) "

[directory]
style = "bold #89b4fa"
truncation_length = 3
truncation_symbol = ".../"
read_only = " ro"
read_only_style = "#f38ba8"

[git_branch]
style = "bold #a6e3a1"
format = "[$symbol$branch]($style) "
symbol = " "

[git_status]
style = "#fab387"
format = '([\[$all_status$ahead_behind\]]($style) )'
conflicted = "="
ahead = "^"
behind = "v"
diverged = "^v"
untracked = "?"
stashed = "$"
modified = "!"
staged = "+"
renamed = "r"
deleted = "x"

[cmd_duration]
min_time = 3_000
style = "bold #f9e2af"
format = "[$duration]($style) "
show_milliseconds = false

[time]
disabled = false
style = "#6c7086"
format = "[$time]($style)"
time_format = "%H:%M"

[line_break]
disabled = false
STARSHIP_TOML

    success "Starship config written to ~/.config/starship.toml"
    track_status "Starship Config" "OK"
}

#-------------------------------------------------------------------------------
# CATPPUCCIN THEME CONFIGS
#-------------------------------------------------------------------------------
configure_catppuccin() {
    header "CONFIGURING CATPPUCCIN MOCHA THEME"

    configure_fzf_theme
    configure_bat_theme
    configure_btop_theme
    configure_delta_theme
    configure_zellij_theme

    track_status "Catppuccin Theme" "OK"
}

configure_fzf_theme() {
    # FZF colors are set in .zshrc via FZF_DEFAULT_OPTS
    # This function is a no-op — the colors are baked into generate_zshrc()
    success "fzf Catppuccin colors: configured (via .zshrc)"
}

configure_bat_theme() {
    if ! command -v bat &>/dev/null && ! command -v batcat &>/dev/null; then
        warn "bat/batcat not found, skipping bat theme"
        return 0
    fi

    local bat_theme_dir="$HOME/.config/bat/themes"
    local theme_file="$bat_theme_dir/Catppuccin Mocha.tmTheme"

    if [[ -f "$theme_file" ]]; then
        success "bat Catppuccin theme already installed"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would download Catppuccin bat theme" | tee -a "$LOG_FILE"
        return 0
    fi

    mkdir -p "$bat_theme_dir"

    local url="https://raw.githubusercontent.com/catppuccin/bat/main/themes/Catppuccin%20Mocha.tmTheme"
    if curl -fsSL -o "$theme_file" "$url" 2>>"$LOG_FILE"; then
        # Build bat cache
        if command -v bat &>/dev/null; then
            bat cache --build >> "$LOG_FILE" 2>&1 || true
        elif command -v batcat &>/dev/null; then
            batcat cache --build >> "$LOG_FILE" 2>&1 || true
        fi
        success "bat Catppuccin Mocha theme installed"
    else
        warn "Failed to download bat theme"
    fi
}

configure_btop_theme() {
    if ! command -v btop &>/dev/null; then
        return 0
    fi

    local btop_theme_dir="$HOME/.config/btop/themes"
    local theme_file="$btop_theme_dir/catppuccin_mocha.theme"

    if [[ -f "$theme_file" ]]; then
        success "btop Catppuccin theme already installed"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would download Catppuccin btop theme" | tee -a "$LOG_FILE"
        return 0
    fi

    mkdir -p "$btop_theme_dir"

    local url="https://raw.githubusercontent.com/catppuccin/btop/main/themes/catppuccin_mocha.theme"
    if curl -fsSL -o "$theme_file" "$url" 2>>"$LOG_FILE"; then
        success "btop Catppuccin Mocha theme installed"
    else
        warn "Failed to download btop theme"
    fi
}

configure_delta_theme() {
    if ! command -v delta &>/dev/null; then
        return 0
    fi

    local gitconfig="$HOME/.gitconfig"

    # Check if delta section already exists
    if [[ -f "$gitconfig" ]] && grep -q '\[delta\]' "$gitconfig" 2>/dev/null; then
        success "delta config already present in .gitconfig"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would add delta config to .gitconfig" | tee -a "$LOG_FILE"
        return 0
    fi

    cat >> "$gitconfig" <<'DELTACONF'

# Delta pager config — Catppuccin Mocha (added by pi-bootstrap v20)
[core]
    pager = delta

[interactive]
    diffFilter = delta --color-only

[delta]
    navigate = true
    side-by-side = false
    line-numbers = true
    syntax-theme = "Catppuccin Mocha"
    minus-style = "syntax #3b2030"
    minus-emph-style = "syntax #53273a"
    plus-style = "syntax #203b20"
    plus-emph-style = "syntax #274027"
    hunk-header-style = "syntax bold"
    hunk-header-decoration-style = "#585b70 ul"
    file-style = "#cba6f7 bold"
    file-decoration-style = "#585b70 ul"
    line-numbers-minus-style = "#f38ba8"
    line-numbers-plus-style = "#a6e3a1"
    line-numbers-zero-style = "#6c7086"

[merge]
    conflictstyle = diff3

[diff]
    colorMoved = default
DELTACONF

    success "delta Catppuccin config added to .gitconfig"
}

configure_zellij_theme() {
    if [[ "$TIER" != "full" ]] || ! command -v zellij &>/dev/null; then
        return 0
    fi

    local zellij_theme_dir="$HOME/.config/zellij/themes"
    local theme_file="$zellij_theme_dir/catppuccin-mocha.kdl"

    if [[ -f "$theme_file" ]]; then
        success "zellij Catppuccin theme already installed"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would write zellij Catppuccin theme" | tee -a "$LOG_FILE"
        return 0
    fi

    mkdir -p "$zellij_theme_dir"

    cat > "$theme_file" <<'ZELLIJ_THEME'
// Catppuccin Mocha theme for Zellij
// Generated by pi-bootstrap v20
themes {
    catppuccin-mocha {
        bg "#585b70"
        fg "#cdd6f4"
        red "#f38ba8"
        green "#a6e3a1"
        blue "#89b4fa"
        yellow "#f9e2af"
        magenta "#f5c2e7"
        orange "#fab387"
        cyan "#89dceb"
        black "#1e1e2e"
        white "#cdd6f4"
    }
}
ZELLIJ_THEME

    success "zellij Catppuccin Mocha theme written"
}


#-------------------------------------------------------------------------------
# TMUX CONFIGURATION
#-------------------------------------------------------------------------------
configure_tmux() {
    header "CONFIGURING TMUX"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would install TPM and generate ~/.tmux.conf" | tee -a "$LOG_FILE"
        track_status "tmux Config" "OK"
        return 0
    fi

    # Install TPM (Tmux Plugin Manager)
    local tpm_dir="$HOME/.tmux/plugins/tpm"
    if [[ ! -d "$tpm_dir" ]]; then
        spin "Cloning TPM (Tmux Plugin Manager)" \
            git clone --depth=1 https://github.com/tmux-plugins/tpm "$tpm_dir" || {
                warn "Failed to clone TPM"
            }
    else
        success "TPM already installed"
    fi

    # Generate tmux.conf
    cat > "$HOME/.tmux.conf" <<'TMUX_CONF'
# tmux.conf — Generated by pi-bootstrap v20
# Catppuccin Mocha theme, ADHD-friendly defaults

# ─── Terminal ────────────────────────────────────────────────────────
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",*256col*:Tc"

# ─── General ─────────────────────────────────────────────────────────
set -g mouse on
set -g history-limit 10000
set -g base-index 1
setw -g pane-base-index 1

# Renumber windows when one is closed
set -g renumber-windows on

# Reduce escape delay (helps with vim)
set -sg escape-time 10

# ─── Intuitive splits ────────────────────────────────────────────────
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
unbind '"'
unbind %

# New window in current path
bind c new-window -c "#{pane_current_path}"

# ─── Pane navigation (vim-style) ─────────────────────────────────────
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

# ─── Reload config ───────────────────────────────────────────────────
bind r source-file ~/.tmux.conf \; display-message "Config reloaded"

# ─── TPM Plugins ─────────────────────────────────────────────────────
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'catppuccin/tmux'

# ─── Catppuccin config ───────────────────────────────────────────────
set -g @catppuccin_flavor 'mocha'
set -g @catppuccin_window_status_style "rounded"
set -g @catppuccin_status_modules_right "application session date_time"
set -g @catppuccin_date_time_text "%H:%M"

# ─── Initialize TPM (keep at very bottom) ────────────────────────────
run '~/.tmux/plugins/tpm/tpm'
TMUX_CONF

    success "tmux.conf generated with Catppuccin Mocha"
    track_status "tmux Config" "OK"
}


#-------------------------------------------------------------------------------
# MODULAR ALIASES
#-------------------------------------------------------------------------------
create_modular_aliases() {
    header "CREATING MODULAR ALIASES"

    local alias_dir="$HOME/.config/zsh/aliases"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would create alias files in $alias_dir" | tee -a "$LOG_FILE"
        track_status "Modular Aliases" "OK"
        return 0
    fi

    mkdir -p "$alias_dir"

    # --- docker.zsh ---
    cat > "$alias_dir/docker.zsh" <<'DOCKER_ALIASES'
# Docker aliases — pi-bootstrap v20
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dcu='docker compose up -d'
alias dcd='docker compose down'
alias dlogs='docker compose logs -f'
alias dprune='docker system prune -af'
DOCKER_ALIASES

    # --- git.zsh ---
    cat > "$alias_dir/git.zsh" <<'GIT_ALIASES'
# Git aliases — pi-bootstrap v20
alias gs='git status'
alias gd='git diff'
alias gl='git log --oneline -20'
alias gp='git push'
alias gpl='git pull'
alias gco='git checkout'
alias ga='git add'
alias gc='git commit'
alias gb='git branch'
GIT_ALIASES

    # --- navigation.zsh ---
    cat > "$alias_dir/navigation.zsh" <<'NAV_ALIASES'
# Navigation aliases — pi-bootstrap v20
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# mkdir + cd in one shot
mkcd() { mkdir -p "$1" && cd "$1"; }
NAV_ALIASES

    # --- pi.zsh ---
    cat > "$alias_dir/pi.zsh" <<'PI_ALIASES'
# Raspberry Pi aliases — pi-bootstrap v20
alias temp='vcgencmd measure_temp 2>/dev/null || echo "N/A"'
alias throttle='vcgencmd get_throttled 2>/dev/null || echo "vcgencmd not available"'
alias pimodel='cat /proc/device-tree/model 2>/dev/null && echo'
PI_ALIASES

    # --- system.zsh ---
    cat > "$alias_dir/system.zsh" <<'SYSTEM_ALIASES'
# System aliases — pi-bootstrap v20
alias update='sudo apt update && sudo apt upgrade -y'
alias ports='sudo ss -tulnp'
alias myip='curl -s ifconfig.me && echo'
alias cls='clear'
alias c='clear'
alias df='df -h'
alias du='du -h'
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias grep='grep --color=auto'
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'
SYSTEM_ALIASES

    # Add eza aliases if eza is installed
    if command -v eza &>/dev/null; then
        cat >> "$alias_dir/system.zsh" <<'EZA_ALIASES'

# eza overrides (modern ls)
alias ls='eza --icons --group-directories-first'
alias ll='eza -la --icons --group-directories-first'
alias tree='eza --tree --icons'
EZA_ALIASES
    fi

    # --- adhd.zsh ---
    cat > "$alias_dir/adhd.zsh" <<'ADHD_ALIASES'
# ADHD toolkit aliases — pi-bootstrap v20
# Designed to fight context loss, time blindness, and forgotten aliases.

# Quick alias fuzzy finder
halp() { alias | fzf; }

# Context recovery — "what was I doing?"
whereami() {
    local C='\033[0;36m' B='\033[1m' D='\033[2m' G='\033[0;32m' R='\033[0m'

    echo ""
    printf "  ${B}${C}Where Am I?${R}\n"
    printf "  ${D}──────────────────────────────────────${R}\n"
    printf "  ${D}Dir:${R}  %s\n" "$(pwd)"
    printf "  ${D}User:${R} %s@%s\n" "$(whoami)" "$(hostname)"

    if git rev-parse --is-inside-work-tree &>/dev/null; then
        local branch=$(git branch --show-current 2>/dev/null)
        local changes=$(git status --short 2>/dev/null | wc -l | tr -d ' ')
        printf "  ${D}Git:${R}  ${G}%s${R} (%s uncommitted)\n" "$branch" "$changes"
    fi

    echo ""
    printf "  ${B}${C}Recent Commands${R}\n"
    printf "  ${D}──────────────────────────────────────${R}\n"
    fc -l -5 2>/dev/null | while IFS= read -r line; do
        printf "  ${D}%s${R}\n" "$line"
    done

    echo ""
    printf "  ${B}${C}Directory Contents${R}\n"
    printf "  ${D}──────────────────────────────────────${R}\n"
    command ls --color=auto -1 | head -10 | while IFS= read -r entry; do
        printf "  %s\n" "$entry"
    done
    local total=$(command ls -1 2>/dev/null | wc -l | tr -d ' ')
    if (( total > 10 )); then
        printf "  ${D}... and %d more${R}\n" $((total - 10))
    fi
    echo ""
}

# Daily activity journal — fight time blindness
today() {
    local C='\033[0;36m' B='\033[1m' D='\033[2m' G='\033[0;32m' R='\033[0m'

    echo ""
    printf "  ${B}${C}Today — $(date '+%A, %B %d')${R}\n"
    printf "  ${D}──────────────────────────────────────${R}\n"

    echo ""
    printf "  ${B}Recent commands:${R}\n"
    fc -l -20 2>/dev/null | while IFS= read -r line; do
        printf "  ${D}%s${R}\n" "$line"
    done

    echo ""
    printf "  ${B}Files modified today:${R}\n"
    local found=$(find . -maxdepth 3 -type f -mtime 0 \
        -not -path '*/\.*' -not -path '*/node_modules/*' 2>/dev/null | head -15)
    if [[ -n "$found" ]]; then
        echo "$found" | while IFS= read -r line; do
            printf "  ${D}%s${R}\n" "$line"
        done
    else
        printf "  ${D}(none in current directory)${R}\n"
    fi

    if git rev-parse --is-inside-work-tree &>/dev/null; then
        echo ""
        printf "  ${B}Git activity:${R}\n"
        local commits=$(git log --oneline --since="midnight" 2>/dev/null)
        if [[ -n "$commits" ]]; then
            echo "$commits" | while IFS= read -r line; do
                printf "  ${G}%s${R}\n" "$line"
            done
        else
            printf "  ${D}(no commits today)${R}\n"
        fi
    fi
    echo ""
}

# ntfy.sh notification helper
notify-done() {
    local msg="${1:-Task complete}"
    local topic_file="$HOME/.config/adhd-kit/ntfy-topic"
    local topic=""

    if [[ -f "$topic_file" ]]; then
        topic=$(<"$topic_file")
    fi

    if [[ -n "$topic" ]]; then
        curl -s -d "$msg" "https://ntfy.sh/$topic"
        echo "Notification sent to ntfy.sh/$topic"
    else
        echo "Set your ntfy.sh topic: echo 'your-topic' > ~/.config/adhd-kit/ntfy-topic"
    fi
}
ADHD_ALIASES

    # Create ntfy config dir
    mkdir -p "$HOME/.config/adhd-kit"

    success "Modular aliases created in $alias_dir"
    track_status "Modular Aliases" "OK"
}


#-------------------------------------------------------------------------------
# GENERATE .ZSHRC — THE MOST IMPORTANT FUNCTION
# This generates the shell config that the user will live in daily.
# Tier-conditional: full tier gets Starship, light/standard get P10k.
#-------------------------------------------------------------------------------
generate_zshrc() {
    header "GENERATING .zshrc"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would generate ~/.zshrc for tier=$TIER" | tee -a "$LOG_FILE"
        track_status "Generate .zshrc" "OK"
        return 0
    fi

    # Start building the .zshrc
    # We need some parts to expand NOW (like $TIER checks) and most parts
    # to remain literal zsh code. Strategy: write sections with mixed heredocs.

    # --- Header ---
    cat > "$HOME/.zshrc" <<'ZSHRC_STATIC_TOP'
#===============================================================================
# .zshrc — Generated by pi-bootstrap v20
# ADHD-Friendly Configuration with Antidote + Catppuccin Mocha
#
# Structure:
#   1. MOTD (before instant prompt)
#   2. Prompt init (p10k instant prompt or starship)
#   3. Antidote plugins
#   4. History, options, completions, keybindings
#   5. Tool integrations (fzf, zoxide)
#   6. Modular aliases (sourced from ~/.config/zsh/aliases/)
#   7. ADHD helpers (notifications, auto-ls, terminal title)
#===============================================================================

#-------------------------------------------------------------------------------
# MOTD (must run BEFORE instant prompt to avoid p10k console output warning)
#-------------------------------------------------------------------------------
if [[ -o login && -f /etc/profile.d/99-earthlume-motd.sh ]]; then
    bash /etc/profile.d/99-earthlume-motd.sh
fi

ZSHRC_STATIC_TOP

    # --- Tier-conditional: P10k instant prompt OR nothing (starship doesn't need it) ---
    if [[ "$TIER" != "full" ]]; then
        cat >> "$HOME/.zshrc" <<'ZSHRC_P10K_INSTANT'
#-------------------------------------------------------------------------------
# POWERLEVEL10K INSTANT PROMPT
# Must be near the top. Initialization code that may require console input
# (password prompts, [y/n] confirmations, etc.) must go above this block.
#-------------------------------------------------------------------------------
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

ZSHRC_P10K_INSTANT
    fi

    # --- Common sections ---
    cat >> "$HOME/.zshrc" <<'ZSHRC_COMMON'
#-------------------------------------------------------------------------------
# PATH
#-------------------------------------------------------------------------------
export PATH="$HOME/.local/bin:$PATH"

#-------------------------------------------------------------------------------
# ANTIDOTE PLUGIN MANAGER
#-------------------------------------------------------------------------------
source "${ZDOTDIR:-$HOME}/.antidote/antidote.zsh"
antidote load

#-------------------------------------------------------------------------------
# HISTORY
#-------------------------------------------------------------------------------
HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt HIST_IGNORE_ALL_DUPS    # No duplicate entries
setopt HIST_FIND_NO_DUPS       # Don't show dupes when searching
setopt SHARE_HISTORY           # Share history across terminals
setopt INC_APPEND_HISTORY      # Write immediately, not on exit

#-------------------------------------------------------------------------------
# SHELL OPTIONS
#-------------------------------------------------------------------------------
setopt CORRECT                 # Correct commands
setopt CORRECT_ALL             # Correct arguments too
setopt AUTO_CD                 # cd by just typing directory name
setopt AUTO_PUSHD              # Push dirs onto stack automatically
setopt PUSHD_IGNORE_DUPS       # No duplicate dirs in stack
setopt PUSHD_SILENT            # Don't print stack after pushd/popd
setopt COMPLETE_IN_WORD        # Complete from cursor position
setopt ALWAYS_TO_END           # Move cursor to end after completion
SPROMPT="Correct %R to %r? [nyae] "

#-------------------------------------------------------------------------------
# COMPLETION (cached, daily rebuild)
#-------------------------------------------------------------------------------
autoload -Uz compinit
if [[ -n ${ZDOTDIR:-$HOME}/.zcompdump(#qN.mh+24) ]]; then
  compinit
else
  compinit -C
fi
zstyle ':completion:*' menu select

#-------------------------------------------------------------------------------
# KEY BINDINGS
# Up/Down arrow partial history search:
# Type "git" then press Up to find previous git commands
#-------------------------------------------------------------------------------
autoload -U up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey "^[[A" up-line-or-beginning-search    # Up arrow
bindkey "^[[B" down-line-or-beginning-search  # Down arrow

#-------------------------------------------------------------------------------
# AUTOSUGGESTION CONFIG
#-------------------------------------------------------------------------------
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20
ZSH_AUTOSUGGEST_USE_ASYNC=1

#-------------------------------------------------------------------------------
# FZF INTEGRATION
#-------------------------------------------------------------------------------
[[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]] && source /usr/share/doc/fzf/examples/key-bindings.zsh
[[ -f /usr/share/doc/fzf/examples/completion.zsh ]] && source /usr/share/doc/fzf/examples/completion.zsh

#-------------------------------------------------------------------------------
# CATPPUCCIN FZF COLORS
#-------------------------------------------------------------------------------
export FZF_DEFAULT_OPTS=" \
  --color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8 \
  --color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc \
  --color=marker:#b4befe,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8 \
  --color=selected-bg:#45475a \
  --border=\"rounded\" --border-label=\"\" --preview-window=\"border-rounded\" \
  --prompt=\"> \" --marker=\">\" --pointer=\">\" --separator=\"-\" \
  --scrollbar=\"|\" --info=\"right\""

#-------------------------------------------------------------------------------
# ZOXIDE (smart cd)
#-------------------------------------------------------------------------------
command -v zoxide &>/dev/null && eval "$(zoxide init zsh)"

#-------------------------------------------------------------------------------
# AUTO-LS AFTER CD
#-------------------------------------------------------------------------------
autoload -Uz add-zsh-hook
__auto_ls() { ls --color=auto; }
add-zsh-hook chpwd __auto_ls

#-------------------------------------------------------------------------------
# COLORED MAN PAGES (easier to scan)
#-------------------------------------------------------------------------------
export LESS_TERMCAP_mb=$'\e[1;31m'    # begin bold (red)
export LESS_TERMCAP_md=$'\e[1;36m'    # begin bold mode (cyan — headings)
export LESS_TERMCAP_me=$'\e[0m'       # end bold mode
export LESS_TERMCAP_so=$'\e[1;33;44m' # begin standout (yellow on blue — search hits)
export LESS_TERMCAP_se=$'\e[0m'       # end standout
export LESS_TERMCAP_us=$'\e[1;32m'    # begin underline (green — flags/args)
export LESS_TERMCAP_ue=$'\e[0m'       # end underline

#-------------------------------------------------------------------------------
# TERMINAL TITLE + LONG COMMAND NOTIFICATION
# Title: shows user@host:dir — helps identify tabs/windows
# Bell: rings after commands >30s — catches your attention on task switch
# ntfy: sends push notification for commands >60s (if configured)
#-------------------------------------------------------------------------------
TBEEP=30
preexec() {
    _CMD_START=$EPOCHSECONDS
    _CMD_NAME="$1"
}
precmd() {
    print -Pn "\e]2;%n@%m: %~\a"
    if (( _CMD_START && EPOCHSECONDS - _CMD_START >= TBEEP )); then
        print "\a"
    fi
    # ntfy notification for very long commands (>60s)
    local _ntfy_topic
    [[ -f ~/.config/adhd-kit/ntfy-topic ]] && _ntfy_topic=$(<~/.config/adhd-kit/ntfy-topic)
    if [[ -n "${_ntfy_topic:-}" ]] && (( _CMD_START && EPOCHSECONDS - _CMD_START >= 60 )); then
        curl -s -d "Done ($(( EPOCHSECONDS - _CMD_START ))s): ${_CMD_NAME}" "https://ntfy.sh/${_ntfy_topic}" &>/dev/null &
    fi
    _CMD_START=0
}

#-------------------------------------------------------------------------------
# COMMAND NOT FOUND — suggest the right package
#-------------------------------------------------------------------------------
[[ -f /etc/zsh_command_not_found ]] && source /etc/zsh_command_not_found

#-------------------------------------------------------------------------------
# SOURCE MODULAR ALIASES
#-------------------------------------------------------------------------------
for f in ~/.config/zsh/aliases/*.zsh(N); do source "$f"; done

ZSHRC_COMMON

    # --- Tier-conditional: Starship init OR P10k init ---
    if [[ "$TIER" == "full" ]]; then
        cat >> "$HOME/.zshrc" <<'ZSHRC_STARSHIP'
#-------------------------------------------------------------------------------
# STARSHIP PROMPT (full tier)
#-------------------------------------------------------------------------------
eval "$(starship init zsh)"
ZSHRC_STARSHIP
    else
        cat >> "$HOME/.zshrc" <<'ZSHRC_P10K'
#-------------------------------------------------------------------------------
# POWERLEVEL10K PROMPT (light/standard tier)
#-------------------------------------------------------------------------------
source ~/.powerlevel10k/powerlevel10k.zsh-theme
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh
ZSHRC_P10K
    fi

    success ".zshrc generated for tier: $TIER"
    track_status "Generate .zshrc" "OK"
}


#-------------------------------------------------------------------------------
# INSTALL CUSTOM MOTD
#-------------------------------------------------------------------------------
install_motd() {
    header "INSTALLING CUSTOM MOTD"

    if [[ "$DO_MOTD" == false ]]; then
        log "Skipping MOTD (--no-motd flag set)"
        track_status "Custom MOTD" "SKIP"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would install MOTD to /etc/profile.d/" | tee -a "$LOG_FILE"
        track_status "Custom MOTD" "OK"
        return 0
    fi

    log "Creating dynamic MOTD script..."

    sudo tee /etc/profile.d/99-earthlume-motd.sh > /dev/null << 'MOTD_SCRIPT'
#!/bin/bash
#===============================================================================
# Earthlume's Fun Homelab — Dynamic MOTD
# Version: 20 — "I cast Detect Magic on the terminal"
#===============================================================================

# Colors
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_WHITE='\033[1;37m'

# Box width (inner content = 63 total - 4 for borders = 59)
BOX_W=59

# Hostname color from /etc/pi-role (prod=red, dev=green, monitor=blue, default=cyan)
HOST_COLOR="${C_CYAN}"
if [[ -f /etc/pi-role ]]; then
    case "$(cat /etc/pi-role | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')" in
        prod*)    HOST_COLOR="${C_RED}" ;;
        dev*)     HOST_COLOR="${C_GREEN}" ;;
        monitor*) HOST_COLOR="${C_BLUE}" ;;
    esac
fi

# Taglines — random on each login. Dry humor, D&D-themed, SA goon energy.
TAGLINES=(
    "It compiles. Ship it."
    "Works on my machine."
    "Working as intended. Probably."
    "TODO: document this later"
    "Powered by caffeine and spite"
    "Trust the process. Or don't."
    "Chaotic good infrastructure"
    "sudo make me a sandwich"
    "DNS: it's always DNS"
    "There's no place like 127.0.0.1"
    "Not a bug, a surprise feature"
    "Held together with zip ties and hope"
    "Future me problem"
    "chmod 777 and pray"
    "Over-engineered with love"
    "99% uptime, 1% existential dread"
    "Keep calm and blame the network"
    "Have you tried rebooting?"
    "Sage of Shadowdale says: check your logs"
    "Roll for Initiative. NAT 1. The server reboots."
    "You have encountered a wild segfault"
    "The DM says: your config file is cursed"
    "Charisma check failed. Access denied."
    "You find a scroll. It reads: man page."
    "Critical hit on uptime"
    "The bard casts Vicious Mockery on systemd"
    "Your party rests. The cron job does not."
    "Perception check: you notice the disk is 90% full"
    "The rogue pickpockets your SSH keys"
    "Long rest complete. All spell slots restored."
)

# Tips — shown ~30% of logins
TIPS=(
    "btop = pretty system monitor"
    "ncdu = find what's eating disk"
    "z dirname = jump to frequent dirs"
    "Ctrl+R = search command history"
    "temp = check CPU temperature"
    "ports = see what's listening"
    "!! = repeat last command"
    "sudo !! = last command as root"
    "Ctrl+L = clear screen"
    "halp = fuzzy-find your aliases"
    "whereami = instant context when lost"
    "today = see what you did today"
    "notify-done 'msg' = push to phone"
    "man pages are color-coded now"
    "cd into a dir = auto-ls for free"
    "dps = pretty docker ps"
    "gs = git status, gd = git diff"
    "mkcd dirname = mkdir + cd in one"
)

# Pick random tagline
TAGLINE="${TAGLINES[$((RANDOM % ${#TAGLINES[@]}))]}"

# Strip ANSI codes for length calculation
strip_ansi() {
    echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

# Print single line with right padding
boxline() {
    local content="$1"
    local plain=$(strip_ansi "$content")
    local len=${#plain}
    local pad=$((BOX_W - len))
    (( pad < 0 )) && pad=0
    printf "${C_CYAN}│${C_RESET} %b%*s ${C_CYAN}│${C_RESET}\n" "$content" "$pad" ""
}

# Print two-column line (left and right aligned)
boxline2() {
    local left="$1"
    local right="$2"
    local left_plain=$(strip_ansi "$left")
    local right_plain=$(strip_ansi "$right")
    local left_len=${#left_plain}
    local right_len=${#right_plain}
    local gap=$((BOX_W - left_len - right_len))
    (( gap < 1 )) && gap=1
    printf "${C_CYAN}│${C_RESET} %b%*s%b ${C_CYAN}│${C_RESET}\n" "$left" "$gap" "" "$right"
}

# ─── Gather system info ─────────────────────────────────────────────

HOSTNAME_UPPER=$(hostname | tr '[:lower:]' '[:upper:]')
UPTIME_STR=$(uptime -p 2>/dev/null) || UPTIME_STR="Up ?"
UPTIME_STR="${UPTIME_STR/up /Up }"

# Model (short version)
if [[ -f /proc/device-tree/model ]]; then
    PI_MODEL=$(tr -d '\0' < /proc/device-tree/model | sed 's/Raspberry Pi /RPi /')
else
    PI_MODEL="Linux"
fi

# OS info
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_INFO="${ID^} ${VERSION_ID:-}"
    [[ -n "${VERSION_CODENAME:-}" ]] && OS_INFO+=" (${VERSION_CODENAME})"
else
    OS_INFO="Linux"
fi

# Kernel (major.minor.patch)
KERNEL_VER=$(uname -r | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')

# Temperature with color coding
if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
    TEMP_RAW=$(cat /sys/class/thermal/thermal_zone0/temp)
    TEMP_C=$((TEMP_RAW / 1000))
    if (( TEMP_C < 50 )); then
        TEMP_COLOR="${C_GREEN}"
    elif (( TEMP_C < 65 )); then
        TEMP_COLOR="${C_YELLOW}"
    else
        TEMP_COLOR="${C_RED}"
    fi
    TEMP_STR="${TEMP_COLOR}${TEMP_C}°C${C_RESET}"
else
    TEMP_STR="${C_DIM}N/A${C_RESET}"
fi

# CPU usage
CPU_PCT=$(timeout 2 top -bn1 2>/dev/null | awk '/Cpu\(s\)/{print int($2)}')
[[ -z "$CPU_PCT" ]] && CPU_PCT="?"

# RAM with color
read -r RAM_USED RAM_TOTAL <<< "$(free -m | awk '/^Mem:/{print $3, $2}')"
if [[ -n "$RAM_TOTAL" && "$RAM_TOTAL" -gt 0 ]] 2>/dev/null; then
    RAM_PCT=$((RAM_USED * 100 / RAM_TOTAL))
else
    RAM_PCT=0
fi
if (( RAM_PCT < 70 )); then
    RAM_COLOR="${C_GREEN}"
elif (( RAM_PCT < 85 )); then
    RAM_COLOR="${C_YELLOW}"
else
    RAM_COLOR="${C_RED}"
fi

# Disk with color
read -r DISK_USED DISK_TOTAL DISK_PCT <<< "$(df -h / | awk 'NR==2{gsub(/%/,"",$5); print $3, $2, $5}')"
if (( DISK_PCT < 70 )); then
    DISK_COLOR="${C_GREEN}"
elif (( DISK_PCT < 85 )); then
    DISK_COLOR="${C_YELLOW}"
else
    DISK_COLOR="${C_RED}"
fi

# IP address, interface, and MAC
IP_ADDR=$(timeout 2 hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$IP_ADDR" ]] && IP_ADDR="unknown"
NET_IF=$(timeout 2 ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
[[ -z "$NET_IF" ]] && NET_IF="eth0"
MAC_ADDR=$(cat "/sys/class/net/${NET_IF}/address" 2>/dev/null || echo "unknown")

# Docker container count
DOCKER_COUNT=""
if command -v docker &>/dev/null; then
    local_containers=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$local_containers" -gt 0 ]] 2>/dev/null; then
        DOCKER_COUNT=" ${C_DIM}Docker${C_RESET} ${local_containers}"
    fi
fi

# Build stats line
STATS="${TEMP_STR}  ${C_DIM}CPU${C_RESET} ${CPU_PCT}%  ${C_DIM}RAM${C_RESET} ${RAM_COLOR}${RAM_PCT}%${C_RESET}  ${C_DIM}Disk${C_RESET} ${DISK_COLOR}${DISK_PCT}%${C_RESET} ${C_DIM}(${DISK_USED}/${DISK_TOTAL})${C_RESET}${DOCKER_COUNT}"

# ─── Print the MOTD ─────────────────────────────────────────────────

echo ""
printf "${C_CYAN}╭─────────────────────────────────────────────────────────────╮${C_RESET}\n"
boxline2 "${C_BOLD}${HOST_COLOR}${HOSTNAME_UPPER}${C_RESET}" "${C_DIM}lab.hoens.fun${C_RESET}"
boxline "${C_DIM}\"${TAGLINE}\"${C_RESET}"
printf "${C_CYAN}├─────────────────────────────────────────────────────────────┤${C_RESET}\n"
boxline2 "${PI_MODEL}" "${UPTIME_STR}"
boxline "${C_DIM}${OS_INFO} · Kernel ${KERNEL_VER}${C_RESET}"
boxline "${STATS}"
boxline "${IP_ADDR} ${C_DIM}(${NET_IF})${C_RESET}  ${C_DIM}MAC${C_RESET} ${MAC_ADDR}"

# Alias quick-reference
printf "${C_CYAN}├─────────────────────────────────────────────────────────────┤${C_RESET}\n"
boxline "${C_BOLD}${C_WHITE}Quick Reference${C_RESET}         ${C_DIM}type${C_RESET} ${C_CYAN}halp${C_RESET} ${C_DIM}for fuzzy alias search${C_RESET}"
boxline "${C_DIM}ll${C_RESET} list  ${C_DIM}..${C_RESET} up dir  ${C_DIM}update${C_RESET} apt  ${C_DIM}temp${C_RESET} heat"
boxline "${C_DIM}gs${C_RESET} git st ${C_DIM}gd${C_RESET} diff   ${C_DIM}myip${C_RESET} pub IP ${C_DIM}ports${C_RESET} listen"
boxline "${C_CYAN}whereami${C_RESET} ${C_DIM}context${C_RESET}  ${C_CYAN}today${C_RESET} ${C_DIM}activity${C_RESET}  ${C_CYAN}notify-done${C_RESET} ${C_DIM}push${C_RESET}"

# ~30% chance to show a tip
if (( RANDOM % 10 < 3 )); then
    TIP="${TIPS[$((RANDOM % ${#TIPS[@]}))]}"
    printf "${C_CYAN}├─────────────────────────────────────────────────────────────┤${C_RESET}\n"
    boxline "${C_DIM}tip: ${TIP}${C_RESET}"
fi

printf "${C_CYAN}╰─────────────────────────────────────────────────────────────╯${C_RESET}\n"
echo ""
MOTD_SCRIPT

    # Make it executable
    sudo chmod +x /etc/profile.d/99-earthlume-motd.sh

    # Remove the default Debian disclaimer (/etc/motd)
    if [[ -f /etc/motd ]] && [[ -s /etc/motd ]]; then
        log "Removing default /etc/motd disclaimer..."
        sudo truncate -s 0 /etc/motd
    fi

    # Disable default MOTD components
    if [[ -d /etc/update-motd.d ]]; then
        log "Disabling default MOTD scripts..."
        sudo chmod -x /etc/update-motd.d/* 2>/dev/null || true
    fi

    # Disable last login message
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        log "Disabling SSH last login message (drop-in)..."
        printf "PrintLastLog no\n" | sudo tee /etc/ssh/sshd_config.d/99-earthlume.conf >/dev/null
    elif [[ -f /etc/ssh/sshd_config ]]; then
        if ! grep -q "^PrintLastLog no" /etc/ssh/sshd_config; then
            if grep -qE '^\s*#?\s*PrintLastLog\b' /etc/ssh/sshd_config; then
                sudo sed -i -E 's/^\s*#?\s*PrintLastLog\b.*/PrintLastLog no/' /etc/ssh/sshd_config
            else
                echo "PrintLastLog no" | sudo tee -a /etc/ssh/sshd_config >/dev/null
            fi
        fi
    fi

    success "Custom MOTD installed"
    track_status "Custom MOTD" "OK"
}


#-------------------------------------------------------------------------------
# CHANGE DEFAULT SHELL
#-------------------------------------------------------------------------------
change_shell() {
    header "SETTING ZSH AS DEFAULT SHELL"

    if [[ "$DO_CHSH" == false ]]; then
        warn "Skipping shell change (--no-chsh flag set)"
        track_status "Change Shell" "SKIP"
        return 0
    fi

    local zsh_path
    zsh_path=$(command -v zsh)

    if [[ "$SHELL" == "$zsh_path" ]]; then
        success "zsh is already default shell"
        track_status "Change Shell" "OK"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would change shell to $zsh_path" | tee -a "$LOG_FILE"
        track_status "Change Shell" "OK"
        return 0
    fi

    # Detect if running non-interactively (piped install)
    if [[ ! -t 0 ]]; then
        warn "Non-interactive mode detected (piped install)"
        warn "Cannot change shell automatically — run this manually:"
        echo ""
        echo -e "    ${BOLD}chsh -s $zsh_path${NC}"
        echo ""
        warn "Then log out and back in."
        track_status "Change Shell" "SKIP"
        return 0
    fi

    log "Changing default shell to zsh..."
    if chsh -s "$zsh_path"; then
        success "Default shell changed to zsh"
        warn "Log out and back in (or reboot) for change to take effect"
        track_status "Change Shell" "OK"
    else
        error "chsh failed — run manually: chsh -s $zsh_path"
        track_status "Change Shell" "FAIL"
    fi
}

#-------------------------------------------------------------------------------
# SAFE SYSTEM OPTIMIZATIONS (--optimize flag)
#-------------------------------------------------------------------------------
apply_optimizations() {
    header "APPLYING SYSTEM OPTIMIZATIONS"

    if [[ "$DO_OPTIMIZE" == false ]]; then
        log "Skipping optimizations (use --optimize flag to enable)"
        track_status "Optimizations" "SKIP"
        return 0
    fi

    local opt_failures=0

    # Reduce swappiness (less aggressive swap on SD cards)
    if [[ -f /proc/sys/vm/swappiness ]] && [[ $(cat /proc/sys/vm/swappiness) -gt 10 ]]; then
        log "Reducing swappiness to 10..."
        if [[ "$DRY_RUN" == true ]]; then
            echo -e "  ${CYAN}[DRY RUN]${NC} Would reduce swappiness to 10" | tee -a "$LOG_FILE"
        elif echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf > /dev/null; then
            sudo sysctl -p /etc/sysctl.d/99-swappiness.conf 2>/dev/null
            success "Swappiness reduced"
        else
            error "Failed to set swappiness"
            ((opt_failures++)) || true
        fi
    else
        success "Swappiness already optimal"
    fi

    # Limit journal size (saves SD card writes)
    local jdrop="/etc/systemd/journald.conf.d/99-earthlume-limit.conf"
    if [[ -f "$jdrop" ]] && grep -qE '^\s*SystemMaxUse\s*=\s*50M\s*$' "$jdrop" 2>/dev/null; then
        success "Journald already limited (drop-in present)"
    else
        log "Limiting journald to 50MB..."
        if [[ "$DRY_RUN" == true ]]; then
            echo -e "  ${CYAN}[DRY RUN]${NC} Would limit journald to 50MB" | tee -a "$LOG_FILE"
        elif sudo mkdir -p /etc/systemd/journald.conf.d && \
             printf "[Journal]\nSystemMaxUse=50M\n" | sudo tee "$jdrop" >/dev/null; then
            sudo systemctl restart systemd-journald 2>/dev/null || true
            success "Journald limited"
        else
            error "Failed to configure journald"
            ((opt_failures++)) || true
        fi
    fi

    # Enable PCIe Gen 3 on Pi 5
    if [[ "$HAS_PCIE" == true ]] && [[ -n "${BOOT_CONFIG:-}" ]]; then
        if grep -qE '^\s*dtparam=pciex1_gen=3' "$BOOT_CONFIG" 2>/dev/null; then
            success "PCIe Gen 3 already enabled"
        else
            log "Enabling PCIe Gen 3 in $BOOT_CONFIG..."
            if [[ "$DRY_RUN" == true ]]; then
                echo -e "  ${CYAN}[DRY RUN]${NC} Would enable PCIe Gen 3" | tee -a "$LOG_FILE"
            elif echo -e "\n# PCIe Gen 3 — doubles NVMe/Hailo throughput (pi-bootstrap v20)\ndtparam=pciex1_gen=3" | sudo tee -a "$BOOT_CONFIG" >/dev/null; then
                success "PCIe Gen 3 enabled (takes effect after reboot)"
                warn "Reboot required for PCIe Gen 3"
            else
                error "Failed to enable PCIe Gen 3"
                ((opt_failures++)) || true
            fi
        fi
    fi

    # Fan curve for Pi 5
    if [[ -n "${BOOT_CONFIG:-}" ]] && [[ -f "$BOOT_CONFIG" ]]; then
        if grep -qE '^\s*dtparam=fan_temp0_hyst' "$BOOT_CONFIG" 2>/dev/null; then
            success "Fan curve already configured"
        elif [[ -d /sys/class/thermal/cooling_device0 ]]; then
            log "Setting fan curve in $BOOT_CONFIG..."
            if [[ "$DRY_RUN" == true ]]; then
                echo -e "  ${CYAN}[DRY RUN]${NC} Would configure fan curve" | tee -a "$LOG_FILE"
            elif cat <<'FANCURVE' | sudo tee -a "$BOOT_CONFIG" >/dev/null

# Fan curve — start early, ramp fast, keep cool (pi-bootstrap v20)
dtparam=fan_temp0=45000
dtparam=fan_temp0_hyst=5000
dtparam=fan_temp0_speed=75
dtparam=fan_temp1=50000
dtparam=fan_temp1_hyst=5000
dtparam=fan_temp1_speed=125
dtparam=fan_temp2=55000
dtparam=fan_temp2_hyst=5000
dtparam=fan_temp2_speed=250
FANCURVE
            then
                success "Fan curve configured (takes effect after reboot)"
            else
                error "Failed to set fan curve"
                ((opt_failures++)) || true
            fi
        fi
    fi

    if [[ $opt_failures -eq 0 ]]; then
        success "Optimizations applied"
        track_status "Optimizations" "OK"
    else
        track_status "Optimizations" "FAIL"
    fi
}

#-------------------------------------------------------------------------------
# HEALTH CHECK — baseline snapshot for known-good state
#-------------------------------------------------------------------------------
health_check() {
    header "HEALTH CHECK (baseline snapshot)"

    # vcgencmd sanity
    if command -v vcgencmd &>/dev/null; then
        local temp throttle firmware
        temp=$(vcgencmd measure_temp 2>/dev/null || echo "N/A")
        throttle=$(vcgencmd get_throttled 2>/dev/null || echo "N/A")
        firmware=$(vcgencmd version 2>/dev/null | head -1 || echo "N/A")

        log "  Temp:      $temp"
        log "  Throttle:  $throttle"
        log "  Firmware:  $firmware"

        # Decode throttle flags
        local flags="${throttle##*=}"
        if [[ "$flags" == "0x0" ]]; then
            success "No throttling detected — clean baseline"
        elif [[ "$flags" =~ ^0x[0-9a-fA-F]+$ ]]; then
            warn "Throttle flags: $flags (undervoltage or thermal event)"
            [[ $((flags & 0x1)) -ne 0 ]] && warn "  -> Under-voltage detected"
            [[ $((flags & 0x2)) -ne 0 ]] && warn "  -> ARM frequency capped"
            [[ $((flags & 0x4)) -ne 0 ]] && warn "  -> Currently throttled"
            [[ $((flags & 0x8)) -ne 0 ]] && warn "  -> Soft temperature limit active"
        else
            warn "Could not parse throttle flags: $flags"
        fi
    else
        log "  vcgencmd not available (not a Pi or not in PATH)"
    fi

    # dmesg error scan
    log ""
    log "  Scanning dmesg for warnings/errors..."
    local dmesg_issues
    dmesg_issues=$(dmesg --level=err,warn 2>/dev/null || sudo dmesg --level=err,warn 2>/dev/null || echo "")
    dmesg_issues=$(echo "$dmesg_issues" | grep -iE 'voltage|throttl|nvme|error|fail|orphan' | tail -10)
    if [[ -n "$dmesg_issues" ]]; then
        warn "dmesg flagged items (review in log):"
        while IFS= read -r line; do
            log "    $line"
        done <<< "$dmesg_issues"
    else
        success "dmesg clean — no voltage/NVMe/orphan issues"
    fi

    track_status "Health Check" "OK"
}

#-------------------------------------------------------------------------------
# WRITE /etc/pi-info — quick reference for MAC/IP
#-------------------------------------------------------------------------------
write_pi_info() {
    log "Writing /etc/pi-info..."

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY RUN]${NC} Would write /etc/pi-info" | tee -a "$LOG_FILE"
        return 0
    fi

    local net_if
    net_if=$(timeout 2 ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
    [[ -z "$net_if" ]] && net_if="eth0"
    local ip_addr mac_addr
    ip_addr=$(timeout 2 hostname -I 2>/dev/null | awk '{print $1}')
    mac_addr=$(cat "/sys/class/net/${net_if}/address" 2>/dev/null || echo "unknown")

    sudo tee /etc/pi-info >/dev/null <<EOF
# Pi network info — generated by pi-bootstrap v20 on $(date -Iseconds)
# Useful for OPNsense static leases, firewall rules, etc.
HOSTNAME=$(hostname)
MODEL=$PI_MODEL
INTERFACE=$net_if
IP_ADDRESS=${ip_addr:-unknown}
MAC_ADDRESS=${mac_addr}
EOF
    success "Wrote /etc/pi-info (MAC + IP bookmark)"
}


#-------------------------------------------------------------------------------
# UNINSTALL
#-------------------------------------------------------------------------------
uninstall_bootstrap() {
    header "UNINSTALLING PI-BOOTSTRAP"

    echo ""
    echo -e "${BOLD}This will remove the following:${NC}"
    echo "  - ~/.antidote (plugin manager)"
    echo "  - ~/.powerlevel10k (prompt theme)"
    echo "  - ~/.zsh_plugins.txt, ~/.zsh_plugins.zsh"
    echo "  - ~/.config/zsh/aliases/ (modular aliases)"
    echo "  - ~/.config/starship.toml"
    echo "  - ~/.config/bat/themes/Catppuccin*"
    echo "  - ~/.config/btop/themes/catppuccin*"
    echo "  - ~/.config/zellij/"
    echo "  - ~/.tmux.conf, ~/.tmux/plugins/"
    echo "  - /etc/profile.d/99-earthlume-motd.sh"
    echo ""
    echo -e "${YELLOW}NOTE: apt packages will NOT be removed.${NC}"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${CYAN}[DRY RUN] Would remove all of the above.${NC}"
        return 0
    fi

    # Prompt for confirmation
    if [[ -t 0 ]]; then
        echo -n "Proceed with uninstall? [y/N] "
        local yn
        read -r yn
        if [[ "$yn" != [yY]* ]]; then
            echo "Aborted."
            return 0
        fi
    else
        warn "Non-interactive mode — proceeding with uninstall"
    fi

    # Remove antidote
    if [[ -d "$HOME/.antidote" ]]; then
        rm -rf "$HOME/.antidote"
        success "Removed ~/.antidote"
    fi

    # Remove powerlevel10k
    if [[ -d "$HOME/.powerlevel10k" ]]; then
        rm -rf "$HOME/.powerlevel10k"
        success "Removed ~/.powerlevel10k"
    fi

    # Remove plugin files
    rm -f "$HOME/.zsh_plugins.txt" "$HOME/.zsh_plugins.zsh" 2>/dev/null
    success "Removed plugin files"

    # Remove modular aliases
    if [[ -d "$HOME/.config/zsh/aliases" ]]; then
        rm -rf "$HOME/.config/zsh/aliases"
        success "Removed modular aliases"
    fi

    # Remove starship config
    rm -f "$HOME/.config/starship.toml" 2>/dev/null

    # Remove catppuccin bat themes
    rm -f "$HOME/.config/bat/themes/Catppuccin"* 2>/dev/null
    # Rebuild bat cache if bat exists
    if command -v bat &>/dev/null; then
        bat cache --build &>/dev/null || true
    elif command -v batcat &>/dev/null; then
        batcat cache --build &>/dev/null || true
    fi

    # Remove catppuccin btop themes
    rm -f "$HOME/.config/btop/themes/catppuccin"* 2>/dev/null

    # Remove zellij config
    if [[ -d "$HOME/.config/zellij" ]]; then
        rm -rf "$HOME/.config/zellij"
        success "Removed zellij config"
    fi

    # Remove tmux config and plugins
    rm -f "$HOME/.tmux.conf" 2>/dev/null
    if [[ -d "$HOME/.tmux/plugins" ]]; then
        rm -rf "$HOME/.tmux/plugins"
        success "Removed tmux plugins"
    fi

    # Remove MOTD
    if [[ -f /etc/profile.d/99-earthlume-motd.sh ]]; then
        sudo rm -f /etc/profile.d/99-earthlume-motd.sh
        success "Removed custom MOTD"
    fi

    # Remove p10k config
    rm -f "$HOME/.p10k.zsh" 2>/dev/null

    # Restore backup if available
    local latest_backup
    latest_backup=$(ls -td "$HOME/.pi-bootstrap-backups/"* 2>/dev/null | head -1)
    if [[ -n "$latest_backup" && -d "$latest_backup" ]]; then
        echo ""
        echo -e "${BOLD}Found backup: $latest_backup${NC}"
        if [[ -t 0 ]]; then
            echo -n "Restore backed-up configs? [y/N] "
            local yn2
            read -r yn2
            if [[ "$yn2" == [yY]* ]]; then
                for file in "$latest_backup"/*; do
                    local basename
                    basename=$(basename "$file")
                    cp "$file" "$HOME/.$basename" 2>/dev/null || cp "$file" "$HOME/$basename" 2>/dev/null || true
                    success "Restored: $basename"
                done
            fi
        fi
    fi

    # Optionally switch back to bash
    if [[ -t 0 ]]; then
        echo ""
        echo -n "Change shell back to bash? [y/N] "
        local yn3
        read -r yn3
        if [[ "$yn3" == [yY]* ]]; then
            local bash_path
            bash_path=$(command -v bash)
            if chsh -s "$bash_path" 2>/dev/null; then
                success "Shell changed back to bash"
            else
                warn "chsh failed — run manually: chsh -s $bash_path"
            fi
        fi
    fi

    echo ""
    success "Uninstall complete. Log out and back in for changes to take effect."
}

#-------------------------------------------------------------------------------
# FINAL SUMMARY WITH STATUS REPORT
#-------------------------------------------------------------------------------
print_summary() {
    header "BOOTSTRAP COMPLETE"

    # Status report
    echo ""
    echo -e "${BOLD}INSTALLATION STATUS${NC}"
    echo "----------------------------------------------------------------------"

    local all_steps=(
        "Hardware Detection"
        "Backup Configs"
        "Time Sync"
        "OS Update"
        "Install Packages"
        "Antidote"
        "Plugins"
        "Powerlevel10k"
        "P10k Config"
        "Nerd Fonts"
        "Starship Config"
        "Generate .zshrc"
        "Catppuccin Theme"
        "tmux Config"
        "Modular Aliases"
        "Custom MOTD"
        "Change Shell"
        "Optimizations"
        "Health Check"
    )

    for step in "${all_steps[@]}"; do
        local status="${STATUS[$step]:-N/A}"
        case $status in
            OK)   echo -e "  ${GREEN}[ok]${NC}   $step" ;;
            FAIL) echo -e "  ${RED}[ERR]${NC}  $step" ;;
            SKIP) echo -e "  ${YELLOW}[--]${NC}   $step (skipped)" ;;
            N/A)  ;; # Don't show steps that weren't relevant to this tier
            *)    echo -e "  ${BLUE}[??]${NC}   $step" ;;
        esac
    done

    echo ""
    if [[ $FAILURES -gt 0 ]]; then
        echo -e "${RED}$FAILURES step(s) failed — review above for details${NC}"
    else
        echo -e "${GREEN}All steps completed successfully${NC}"
    fi

    # System summary
    echo ""
    echo -e "${BOLD}SYSTEM${NC}"
    echo "----------------------------------------------------------------------"
    echo "  Model:    $PI_MODEL"
    echo "  OS:       $OS_NAME"
    echo "  RAM:      ${RAM_MB} MB"
    echo "  Tier:     $TIER"
    echo ""

    # Files created
    echo -e "${BOLD}FILES CREATED${NC}"
    echo "----------------------------------------------------------------------"
    echo "  Config:   ~/.zshrc"
    if [[ "$TIER" != "full" ]]; then
        echo "  Prompt:   ~/.p10k.zsh"
    else
        echo "  Prompt:   ~/.config/starship.toml"
    fi
    echo "  Plugins:  ~/.zsh_plugins.txt"
    echo "  Aliases:  ~/.config/zsh/aliases/*.zsh"
    echo "  tmux:     ~/.tmux.conf"
    echo "  MOTD:     /etc/profile.d/99-earthlume-motd.sh"
    echo "  Pi Info:  /etc/pi-info"
    echo "  Backups:  $BACKUP_DIR"
    echo "  Log:      $LOG_FILE"
    echo ""

    # Next steps
    echo -e "${BOLD}NEXT STEPS${NC}"
    echo "----------------------------------------------------------------------"
    echo "  1. Start zsh:  exec zsh"
    if [[ "$TIER" != "full" ]]; then
        echo "  2. Set terminal font to 'MesloLGS NF' (for powerlevel10k icons)"
    fi
    echo "  3. Install tmux plugins: press prefix + I inside tmux"
    echo "  4. Set up ntfy.sh push notifications:"
    echo "     echo 'your-topic' > ~/.config/adhd-kit/ntfy-topic"
    echo ""

    echo -e "${DIM}For full hardware diagnostics: bash pi-bootstrap.sh --info-only${NC}"
    echo -e "${DIM}To undo everything: bash pi-bootstrap.sh --uninstall${NC}"
    echo ""
}

#-------------------------------------------------------------------------------
# MAIN EXECUTION
#-------------------------------------------------------------------------------

    # Banner
    echo ""
    echo -e "${BOLD}${CYAN}+====================================================================+${NC}"
    echo -e "${BOLD}${CYAN}|     PI-BOOTSTRAP — ADHD-Friendly Shell Setup  (v${VERSION})              |${NC}"
    echo -e "${BOLD}${CYAN}|     by Earthlume  ·  lab.hoens.fun                                |${NC}"
    echo -e "${BOLD}${CYAN}|     \"Roll for Initiative. You rolled a 20.\"                        |${NC}"
    echo -e "${BOLD}${CYAN}+====================================================================+${NC}"
    echo ""

    # Initialize log
    echo "=== pi-bootstrap.sh v${VERSION} started $(date -Iseconds) ===" > "$LOG_FILE"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}*** DRY RUN MODE — no changes will be made ***${NC}"
        echo ""
    fi

    # Info-only mode
    if [[ "$INFO_ONLY" == true ]]; then
        print_system_info
        return 0
    fi

    # Uninstall mode
    if [[ "$DO_UNINSTALL" == true ]]; then
        uninstall_bootstrap
        return 0
    fi

    # ── Full install pipeline ────────────────────────────────────────

    detect_system
    backup_configs
    verify_time_sync        || true
    update_os               || true
    install_core_packages   || true
    install_standard_packages || true
    install_full_packages   || true
    install_zoxide          || true
    install_uv              || true
    install_starship        || true
    install_zellij          || true
    install_antidote        || true
    create_plugin_list      || true
    install_p10k            || true
    install_fonts           || true
    generate_p10k_config    || true
    generate_starship_config || true
    configure_catppuccin    || true
    configure_tmux          || true
    create_modular_aliases  || true
    generate_zshrc
    install_motd            || true
    change_shell            || true
    apply_optimizations     || true
    health_check            || true
    write_pi_info           || true
    print_summary

    # Return failure count (don't use 'exit' — kills the shell when piped)
    return $FAILURES

}

main "$@"
