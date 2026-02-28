#!/bin/bash
#===============================================================================
# pi-bootstrap.sh — Earthlume's ADHD-Friendly Pi Shell Setup
# Version: 20
#
# WHAT:  Installs zsh + Antidote + Starship/P10k + Catppuccin Mocha
# WHY:   Reduce cognitive load; make CLI accessible and dopamine-friendly
# HOW:   Auto-detects hardware, picks light/standard/full tier
#
# USAGE: curl -fsSL <url> | bash
#    or: bash pi-bootstrap.sh [--dry-run] [--tier-override=full] [--help]
#
# FLAGS:
#   --optimize          Apply safe system tweaks (swappiness, journald, PCIe)
#   --update-os         Run apt update/upgrade (kernel held)
#   --no-chsh           Don't change default shell to zsh
#   --no-motd           Don't install custom MOTD
#   --info-only         Just print system info and exit
#   --dry-run           Show what would be installed without doing it
#   --tier-override=X   Force tier: light, standard, or full
#   --uninstall         Remove pi-bootstrap configs (keeps apt packages)
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# PINNED TOOL VERSIONS (update these when upgrading)
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
VERSION="20"
BACKUP_DIR="$HOME/.pi-bootstrap-backups/$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$HOME/.adhd-bootstrap.log"

# Tier thresholds
TIER_LIGHT_MAX_MB=900
TIER_STANDARD_MAX_MB=3800

# Colors
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

# Globals set by detect_system
PI_MODEL="" PI_SOC="" RAM_MB=0 TIER="" DPKG_ARCH="" UNAME_ARCH=""
OS_NAME="" OS_VERSION_ID="" KERNEL="" BITS=0 HAS_PCIE=false BOOT_CONFIG=""

#-------------------------------------------------------------------------------
# PARSE ARGUMENTS
#-------------------------------------------------------------------------------
DRY_RUN=false
DO_OPTIMIZE=false
DO_UPDATE=false
DO_CHSH=true
DO_MOTD=true
INFO_ONLY=false
TIER_OVERRIDE=""

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --optimize)        DO_OPTIMIZE=true ;;
            --update-os)       DO_UPDATE=true ;;
            --no-chsh)         DO_CHSH=false ;;
            --no-motd)         DO_MOTD=false ;;
            --info-only)       INFO_ONLY=true ;;
            --dry-run)         DRY_RUN=true ;;
            --tier-override=*) TIER_OVERRIDE="${arg#*=}" ;;
            --uninstall)       uninstall_bootstrap; exit $? ;;
            --help|-h)         show_help; exit 0 ;;
            *)                 echo -e "${YELLOW}Unknown flag: $arg${NC}" >&2 ;;
        esac
    done
}

show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

ADHD-Friendly Shell Bootstrap for Raspberry Pi (v${VERSION})

Options:
  --optimize          Apply safe system tweaks (swappiness, journald, PCIe Gen 3)
  --update-os         Run apt upgrade before installing (kernel/firmware held)
  --no-chsh           Don't change default shell to zsh
  --no-motd           Don't install custom MOTD
  --info-only         Print system diagnostics and exit
  --dry-run           Show what would be installed without doing it
  --tier-override=X   Force tier: light, standard, or full
  --uninstall         Remove pi-bootstrap configs (restores backups, keeps packages)
  --help              Show this help message

Tiers (auto-detected):
  light     <1GB RAM (Pi Zero, Pi 1)        — P10k, tmux, minimal tools
  standard  1-4GB RAM (Pi 2/3/4)            — P10k, tmux, btop
  full      >=4GB RAM + arm64 (Pi 4+, Pi 5) — Starship, Zellij, full toolkit
EOF
}

#-------------------------------------------------------------------------------
# LOGGING HELPERS
#-------------------------------------------------------------------------------
log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}✓${NC} $*" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $*" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}✗${NC} $*" | tee -a "$LOG_FILE"
}

header() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}  $*${NC}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
}

# Spinner — run a command with an animated progress indicator
spin() {
    local label="$1"
    shift

    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] $label"
        return 0
    fi

    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local start=$SECONDS

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
    local step="$1"
    local result="$2"
    STATUS["$step"]="$result"
    if [[ "$result" == "FAIL" ]]; then
        ((FAILURES++)) || true
    fi
}

#-------------------------------------------------------------------------------
# IDEMPOTENT HELPERS
#-------------------------------------------------------------------------------
install_if_missing() {
    local cmd="$1"
    shift
    if command -v "$cmd" &>/dev/null; then
        success "$cmd already installed"
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] Would install $cmd"
        return 0
    fi
    "$@"
}

ensure_line_in_file() {
    local line="$1" file="$2"
    grep -qF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

# Download a binary from a GitHub release
# Usage: download_github_release repo version asset_pattern binary_name [install_dir]
download_github_release() {
    local repo="$1" version="$2" asset="$3" binary="$4"
    local dest="${5:-/usr/local/bin}"
    local url="https://github.com/${repo}/releases/download/${version}/${asset}"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] Would download $repo $version ($asset)"
        return 0
    fi

    log "Downloading $repo $version..."
    if ! curl -fsSL "$url" -o "$tmp_dir/$asset"; then
        error "Failed to download $url"
        rm -rf "$tmp_dir"
        return 1
    fi

    case "$asset" in
        *.tar.gz|*.tgz)
            tar -xzf "$tmp_dir/$asset" -C "$tmp_dir"
            # Find the binary — might be in a subdirectory
            local found
            found=$(find "$tmp_dir" -name "$binary" -type f -executable 2>/dev/null | head -1)
            if [[ -z "$found" ]]; then
                found=$(find "$tmp_dir" -name "$binary" -type f 2>/dev/null | head -1)
            fi
            if [[ -n "$found" ]]; then
                sudo install -m 755 "$found" "$dest/$binary"
            else
                error "Binary '$binary' not found in archive"
                rm -rf "$tmp_dir"
                return 1
            fi
            ;;
        *.deb)
            sudo dpkg -i "$tmp_dir/$asset" || sudo apt-get install -f -y
            ;;
        *.zip)
            unzip -o "$tmp_dir/$asset" -d "$tmp_dir"
            local found
            found=$(find "$tmp_dir" -name "$binary" -type f 2>/dev/null | head -1)
            if [[ -n "$found" ]]; then
                sudo install -m 755 "$found" "$dest/$binary"
            fi
            ;;
        *)
            sudo install -m 755 "$tmp_dir/$asset" "$dest/$binary"
            ;;
    esac

    rm -rf "$tmp_dir"
    success "Installed $binary"
}

#-------------------------------------------------------------------------------
# SYSTEM DETECTION
#-------------------------------------------------------------------------------
detect_system() {
    header "DETECTING HARDWARE"

    # Architecture — use dpkg for userland arch (Pi can run 64-bit kernel with 32-bit userland)
    DPKG_ARCH=$(dpkg --print-architecture 2>/dev/null || echo "unknown")
    UNAME_ARCH=$(uname -m)
    log "Architecture: $DPKG_ARCH (kernel: $UNAME_ARCH)"

    # Pi Model
    if [[ -f /proc/device-tree/model ]]; then
        PI_MODEL=$(tr -d '\0' < /proc/device-tree/model)
    elif grep -q "Model" /proc/cpuinfo 2>/dev/null; then
        PI_MODEL=$(grep "Model" /proc/cpuinfo | cut -d: -f2 | xargs)
    else
        PI_MODEL="Unknown (not a Pi?)"
    fi
    log "Model: $PI_MODEL"

    # SoC detection via device-tree compatible string
    if [[ -f /proc/device-tree/compatible ]]; then
        local compat
        compat=$(tr -d '\0' < /proc/device-tree/compatible)
        case "$compat" in
            *bcm2712*) PI_SOC="bcm2712" ;;  # Pi 5
            *bcm2711*) PI_SOC="bcm2711" ;;  # Pi 4
            *bcm2837*) PI_SOC="bcm2837" ;;  # Pi 3 / Zero 2W
            *bcm2836*) PI_SOC="bcm2836" ;;  # Pi 2
            *bcm2835*) PI_SOC="bcm2835" ;;  # Pi 1 / Zero
            *)         PI_SOC="unknown"  ;;
        esac
    else
        PI_SOC="unknown"
    fi
    log "SoC: $PI_SOC"

    # RAM
    RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    log "RAM: ${RAM_MB} MB"

    # OS Info
    if [[ -f /etc/os-release ]]; then
        OS_NAME=$(. /etc/os-release && echo "${PRETTY_NAME:-Unknown}")
        OS_VERSION_ID=$(. /etc/os-release && echo "${VERSION_ID:-unknown}")
    else
        OS_NAME="Unknown"
        OS_VERSION_ID="unknown"
    fi
    log "OS: $OS_NAME"

    # Kernel
    KERNEL=$(uname -r)
    log "Kernel: $KERNEL"

    # Bits
    if [[ "$DPKG_ARCH" == "arm64" ]]; then
        BITS=64
    else
        BITS=32
    fi
    log "Bits: $BITS"

    # Storage
    read -r ROOT_SIZE ROOT_AVAIL ROOT_USED_PCT <<< "$(df -h / | awk 'NR==2 {print $2, $4, $5}')"
    log "Root filesystem: $ROOT_SIZE total, $ROOT_AVAIL available ($ROOT_USED_PCT used)"

    # Tier selection
    if [[ -n "$TIER_OVERRIDE" ]]; then
        TIER="$TIER_OVERRIDE"
        log "Tier override: $TIER"
    elif [[ $RAM_MB -le $TIER_LIGHT_MAX_MB ]]; then
        TIER="light"
    elif [[ $RAM_MB -le $TIER_STANDARD_MAX_MB ]]; then
        TIER="standard"
    else
        TIER="full"
    fi

    # Downgrade full to standard on 32-bit
    if [[ "$TIER" == "full" && "$DPKG_ARCH" != "arm64" ]]; then
        TIER="standard"
        log "Downgraded to standard tier (32-bit userland)"
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

    track_status "Hardware Detection" "OK"
}

#-------------------------------------------------------------------------------
# EXTENDED HARDWARE DETECTION (for --info-only)
#-------------------------------------------------------------------------------
detect_extended_hardware() {
    log "Gathering extended system info..."

    CPU_CORES=$(nproc 2>/dev/null || echo "?")
    CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "ARM")

    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        local temp_raw
        temp_raw=$(cat /sys/class/thermal/thermal_zone0/temp)
        TEMP_C=$((temp_raw / 1000))
    else
        TEMP_C="N/A"
    fi

    if command -v vcgencmd &>/dev/null; then
        THROTTLE_STATUS=$(timeout 3 vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo "N/A")
    else
        THROTTLE_STATUS="vcgencmd not available"
    fi

    if compgen -G "/dev/video*" > /dev/null 2>&1; then
        CAMERA_DEVICES=$(ls /dev/video* 2>/dev/null | tr '\n' ' ')
        [[ -z "$CAMERA_DEVICES" ]] && CAMERA_DEVICES="none"
    else
        CAMERA_DEVICES="none"
    fi

    if command -v libcamera-hello &>/dev/null; then
        LIBCAMERA="installed"
    else
        LIBCAMERA="not installed"
    fi

    if [[ -e /dev/i2c-1 ]]; then
        I2C_STATUS="enabled"
    else
        I2C_STATUS="disabled"
    fi

    if [[ -e /dev/spidev0.0 ]]; then
        SPI_STATUS="enabled"
    else
        SPI_STATUS="disabled"
    fi

    if [[ -d /sys/class/gpio ]]; then
        GPIO_STATUS="available"
    else
        GPIO_STATUS="not available"
    fi

    NET_INTERFACES=$(timeout 3 ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v lo | tr '\n' ' ' || echo "unknown")

    if command -v bluetoothctl &>/dev/null; then
        BT_STATUS="available"
    elif [[ -d /sys/class/bluetooth ]]; then
        BT_STATUS="available (no bluetoothctl)"
    else
        BT_STATUS="not detected"
    fi

    if [[ -n "${BOOT_CONFIG:-}" ]] && [[ -f "$BOOT_CONFIG" ]]; then
        BOOT_OVERLAYS=$(grep "^dtoverlay=" "$BOOT_CONFIG" 2>/dev/null | cut -d= -f2 | tr '\n' ', ' || echo "none")
        [[ -z "$BOOT_OVERLAYS" ]] && BOOT_OVERLAYS="none configured"
    else
        BOOT_OVERLAYS="unknown"
    fi
}

print_system_info() {
    detect_system
    detect_extended_hardware

    header "SYSTEM INFO"

    cat <<EOF

\`\`\`
═══════════════════════════════════════════════════════════
SYSTEM PROFILE — $(date -Iseconds)
═══════════════════════════════════════════════════════════

HARDWARE
--------
PI_MODEL:     $PI_MODEL
PI_SOC:       $PI_SOC
ARCH:         $DPKG_ARCH (kernel: $UNAME_ARCH, ${BITS}-bit)
CPU:          $CPU_MODEL ($CPU_CORES cores)
RAM_MB:       $RAM_MB
TEMP:         ${TEMP_C}°C
THROTTLE:     $THROTTLE_STATUS
TIER:         $TIER

STORAGE
-------
ROOT_SIZE:    ${ROOT_SIZE:-?}
ROOT_AVAIL:   ${ROOT_AVAIL:-?}
ROOT_USED:    ${ROOT_USED_PCT:-?}

OS
--
OS:           $OS_NAME
KERNEL:       $KERNEL
HOSTNAME:     $(hostname)
USER:         $(whoami)
BOOT_CONFIG:  ${BOOT_CONFIG:-not found}

INTERFACES
----------
I2C:          $I2C_STATUS
SPI:          $SPI_STATUS
GPIO:         $GPIO_STATUS
PCIe:         $HAS_PCIE
NETWORK:      $NET_INTERFACES
BLUETOOTH:    $BT_STATUS

PERIPHERALS
-----------
CAMERA:       $CAMERA_DEVICES
LIBCAMERA:    $LIBCAMERA
OVERLAYS:     $BOOT_OVERLAYS
═══════════════════════════════════════════════════════════
\`\`\`

EOF
}

#-------------------------------------------------------------------------------
# BACKUP EXISTING CONFIGS
#-------------------------------------------------------------------------------
backup_configs() {
    header "BACKING UP EXISTING CONFIGS"

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
            if [[ "$DRY_RUN" == true ]]; then
                log "[DRY RUN] Would back up: $file"
            else
                cp "$file" "$BACKUP_DIR/"
                success "Backed up: $file"
            fi
            ((backed_up++)) || true
        fi
    done

    log "Backups stored in: $BACKUP_DIR"

    if [[ $backed_up -gt 0 ]]; then
        track_status "Backup Configs" "OK"
    else
        track_status "Backup Configs" "SKIP"
    fi
}

#-------------------------------------------------------------------------------
# VERIFY TIME SYNC
#-------------------------------------------------------------------------------
verify_time_sync() {
    header "VERIFYING TIME SYNC"

    local sync_ok=false

    if timedatectl show --property=NTP --value 2>/dev/null | grep -qi "yes"; then
        local synced
        synced=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "no")
        if [[ "$synced" == "yes" ]]; then
            success "Time synced via systemd-timesyncd"
            sync_ok=true
        else
            warn "timesyncd active but not yet synchronized"
        fi
    elif systemctl is-active --quiet chronyd 2>/dev/null; then
        success "Time synced via chrony"
        sync_ok=true
    else
        warn "NTP not active — enabling systemd-timesyncd..."
        if [[ "$DRY_RUN" != true ]]; then
            sudo timedatectl set-ntp true 2>/dev/null && success "timesyncd enabled" || warn "Could not enable NTP"
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
    raspberrypi-kernel raspberrypi-kernel-headers raspberrypi-bootloader
    linux-image-rpi-v8 linux-image-rpi-2712
    linux-headers-rpi-v8 linux-headers-rpi-2712
)

update_os() {
    header "UPDATING OS PACKAGES"

    if [[ "$DO_UPDATE" == false ]]; then
        log "Skipping OS update (use --update-os to enable)"
        track_status "OS Update" "SKIP"
        return 0
    fi

    # Hold kernel packages
    log "Holding kernel/firmware packages..."
    local held=()
    for pkg in "${KERNEL_HOLD_PKGS[@]}"; do
        if dpkg -l "$pkg" &>/dev/null; then
            sudo apt-mark hold "$pkg" &>/dev/null && held+=("$pkg")
        fi
    done
    [[ ${#held[@]} -gt 0 ]] && success "Held ${#held[@]} kernel pkg(s)"

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

    [[ -f /var/run/reboot-required ]] && warn "Reboot required after updates"
}

#-------------------------------------------------------------------------------
# INSTALL PACKAGES
#-------------------------------------------------------------------------------
install_core_packages() {
    header "INSTALLING CORE PACKAGES"

    # Ensure package lists are fresh
    if [[ "$DO_UPDATE" == false ]]; then
        if ! spin "Refreshing package lists" \
            "${APT_ENV[@]}" apt-get update -qq; then
            track_status "Core Packages" "FAIL"
            return 1
        fi
    fi

    local packages=(
        zsh git curl wget fontconfig tmux fzf jq stow figlet fortune-mod tree
        bat fd-find ripgrep htop ncdu duf tealdeer
        neovim sqlite3 python3-venv
    )

    log "Installing: ${packages[*]}"
    if spin "Installing core packages (${#packages[@]} items)" \
        "${APT_ENV[@]}" apt-get install -y -qq "${APT_DPKG_OPTS[@]}" "${packages[@]}"; then
        track_status "Core Packages" "OK"
    else
        track_status "Core Packages" "FAIL"
        return 1
    fi

    # Create convenience symlinks for Debian-renamed packages
    if [[ "$DRY_RUN" != true ]]; then
        [[ ! -L /usr/local/bin/bat ]] && [[ -f /usr/bin/batcat ]] && \
            sudo ln -sfn /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true
        [[ ! -L /usr/local/bin/fd ]] && [[ -f /usr/bin/fdfind ]] && \
            sudo ln -sfn /usr/bin/fdfind /usr/local/bin/fd 2>/dev/null || true
    fi
}

install_standard_packages() {
    [[ "$TIER" == "light" ]] && return 0
    header "INSTALLING STANDARD-TIER PACKAGES"

    if spin "Installing btop" \
        "${APT_ENV[@]}" apt-get install -y -qq btop; then
        success "btop installed"
    else
        warn "btop install failed (non-critical)"
    fi
}

install_full_packages() {
    if [[ "$TIER" != "full" ]]; then
        track_status "Full Packages" "SKIP"
        return 0
    fi
    header "INSTALLING FULL-TIER PACKAGES"

    # eza
    if ! command -v eza &>/dev/null; then
        local eza_asset="eza_${UNAME_ARCH}-unknown-linux-gnu.tar.gz"
        spin "Installing eza" \
            download_github_release "eza-community/eza" "$PIN_EZA" "$eza_asset" "eza" || \
            warn "eza install failed (non-critical)"
    else
        success "eza already installed"
    fi

    # delta
    if ! command -v delta &>/dev/null; then
        local delta_asset="git-delta_${PIN_DELTA}_${DPKG_ARCH}.deb"
        spin "Installing delta" \
            download_github_release "dandavison/delta" "$PIN_DELTA" "$delta_asset" "delta" || \
            warn "delta install failed (non-critical)"
    else
        success "delta already installed"
    fi

    # dust
    if ! command -v dust &>/dev/null; then
        local dust_arch="$UNAME_ARCH"
        local dust_asset="dust-${PIN_DUST}-${dust_arch}-unknown-linux-gnu.tar.gz"
        spin "Installing dust" \
            download_github_release "bootandy/dust" "$PIN_DUST" "$dust_asset" "dust" || \
            warn "dust install failed (non-critical)"
    else
        success "dust already installed"
    fi

    # glow
    if ! command -v glow &>/dev/null; then
        local glow_arch="arm64"
        [[ "$DPKG_ARCH" == "armhf" ]] && glow_arch="armv7"
        local glow_asset="glow_${PIN_GLOW#v}_Linux_${glow_arch}.tar.gz"
        spin "Installing glow" \
            download_github_release "charmbracelet/glow" "$PIN_GLOW" "$glow_asset" "glow" || \
            warn "glow install failed (non-critical)"
    else
        success "glow already installed"
    fi

    # lazygit
    if ! command -v lazygit &>/dev/null; then
        local lg_arch="arm64"
        local lg_asset="lazygit_${PIN_LAZYGIT#v}_Linux_${lg_arch}.tar.gz"
        spin "Installing lazygit" \
            download_github_release "jesseduffield/lazygit" "$PIN_LAZYGIT" "$lg_asset" "lazygit" || \
            warn "lazygit install failed (non-critical)"
    else
        success "lazygit already installed"
    fi

    # lazydocker
    if ! command -v lazydocker &>/dev/null; then
        local ld_arch="arm64"
        local ld_asset="lazydocker_${PIN_LAZYDOCKER#v}_Linux_${ld_arch}.tar.gz"
        spin "Installing lazydocker" \
            download_github_release "jesseduffield/lazydocker" "$PIN_LAZYDOCKER" "$ld_asset" "lazydocker" || \
            warn "lazydocker install failed (non-critical)"
    else
        success "lazydocker already installed"
    fi

    # fastfetch
    if ! command -v fastfetch &>/dev/null; then
        local ff_asset="fastfetch-linux-${DPKG_ARCH}.deb"
        spin "Installing fastfetch" \
            download_github_release "fastfetch-cli/fastfetch" "$PIN_FASTFETCH" "$ff_asset" "fastfetch" || \
            warn "fastfetch install failed (non-critical)"
    else
        success "fastfetch already installed"
    fi

    track_status "Full Packages" "OK"
}

install_zoxide() {
    header "INSTALLING ZOXIDE"
    if command -v zoxide &>/dev/null; then
        success "zoxide already installed"
        return 0
    fi

    # Try apt first
    if apt-cache show zoxide &>/dev/null 2>&1; then
        spin "Installing zoxide via apt" \
            "${APT_ENV[@]}" apt-get install -y -qq zoxide && return 0
    fi

    # Fall back to GitHub binary
    local zo_arch="$UNAME_ARCH"
    local zo_asset="zoxide-0.9.6-${zo_arch}-unknown-linux-musl.tar.gz"
    spin "Installing zoxide from GitHub" \
        download_github_release "ajeetdsouza/zoxide" "v0.9.6" "$zo_asset" "zoxide" || \
        warn "zoxide install failed"
}

install_uv() {
    if command -v uv &>/dev/null; then
        success "uv already installed ($(uv --version 2>/dev/null || echo 'unknown'))"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] Would install uv"
        return 0
    fi

    log "Installing uv (Python package manager)..."
    local uv_script
    uv_script=$(curl -fsSL https://astral.sh/uv/install.sh 2>/dev/null) || true
    if [[ -n "$uv_script" ]]; then
        if spin "Installing uv" sh -c "$uv_script"; then
            success "uv installed"
        else
            warn "uv install failed (non-critical)"
        fi
    else
        warn "Could not download uv installer"
    fi
}

install_starship() {
    [[ "$TIER" != "full" ]] && return 0
    header "INSTALLING STARSHIP PROMPT"

    if command -v starship &>/dev/null; then
        success "starship already installed"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] Would install starship"
        return 0
    fi

    if spin "Installing starship" \
        bash -c 'curl -sS https://starship.rs/install.sh | sh -s -- -y'; then
        track_status "Starship" "OK"
    else
        warn "Starship install failed"
        track_status "Starship" "FAIL"
    fi
}

install_zellij() {
    [[ "$TIER" != "full" ]] && return 0
    [[ "$DPKG_ARCH" != "arm64" ]] && { log "Skipping Zellij (arm64 only)"; return 0; }

    header "INSTALLING ZELLIJ"

    if command -v zellij &>/dev/null; then
        success "zellij already installed"
        return 0
    fi

    local asset="zellij-aarch64-unknown-linux-musl.tar.gz"
    spin "Installing zellij" \
        download_github_release "zellij-org/zellij" "$PIN_ZELLIJ" "$asset" "zellij" || \
        warn "Zellij install failed (non-critical)"
}

#-------------------------------------------------------------------------------
# SHELL FRAMEWORK — ANTIDOTE
#-------------------------------------------------------------------------------
install_antidote() {
    header "INSTALLING ANTIDOTE PLUGIN MANAGER"

    local antidote_dir="${ZDOTDIR:-$HOME}/.antidote"

    # Detect existing oh-my-zsh
    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        warn "oh-my-zsh detected — v20 uses Antidote instead"
        warn "Your oh-my-zsh installation has been preserved (not deleted)"
        warn "Custom plugins in ~/.oh-my-zsh/custom/ are still available"
    fi

    if [[ -d "$antidote_dir" ]]; then
        success "Antidote already installed"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] Would install Antidote"
        track_status "Antidote" "OK"
        return 0
    fi

    if spin "Cloning Antidote" \
        git clone --depth=1 https://github.com/mattmc3/antidote.git "$antidote_dir"; then
        track_status "Antidote" "OK"
    else
        track_status "Antidote" "FAIL"
        return 1
    fi
}

create_plugin_list() {
    log "Creating plugin list..."
    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] Would create ~/.zsh_plugins.txt"
        track_status "Plugins" "OK"
        return 0
    fi

    cat > "$HOME/.zsh_plugins.txt" << 'PLUGINS'
zsh-users/zsh-completions
zsh-users/zsh-autosuggestions
zsh-users/zsh-syntax-highlighting
MichaelAquilina/zsh-you-should-use
olets/zsh-abbr kind:defer
PLUGINS
    success "Plugin list created"
    track_status "Plugins" "OK"
}

#-------------------------------------------------------------------------------
# PROMPT CONFIGURATION
#-------------------------------------------------------------------------------
install_p10k() {
    [[ "$TIER" == "full" ]] && return 0
    header "INSTALLING POWERLEVEL10K"

    local p10k_dir="$HOME/.powerlevel10k"

    if [[ -d "$p10k_dir" ]]; then
        success "Powerlevel10k already installed"
        return 0
    fi

    if spin "Cloning powerlevel10k" \
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$p10k_dir"; then
        track_status "Prompt" "OK"
    else
        track_status "Prompt" "FAIL"
        return 1
    fi
}

install_fonts() {
    [[ "$TIER" == "full" ]] && return 0
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
        if [[ ! -f "$font_dir/$decoded_font" ]]; then
            if ! spin "Downloading $decoded_font" \
                curl -fsSL -o "$font_dir/$decoded_font" "$base_url/$font"; then
                ((font_failures++)) || true
            fi
        fi
    done

    spin "Rebuilding font cache" fc-cache -f "$font_dir" || true

    if [[ $font_failures -eq 0 ]]; then
        success "Fonts installed (set terminal font to 'MesloLGS NF')"
        track_status "Fonts" "OK"
    else
        track_status "Fonts" "FAIL"
    fi
}

generate_p10k_config() {
    [[ "$TIER" == "full" ]] && return 0
    header "GENERATING POWERLEVEL10K CONFIG"

    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] Would generate .p10k.zsh"
        track_status "P10k Config" "OK"
        return 0
    fi

    if [[ "$TIER" == "standard" ]]; then
        _generate_p10k_standard
    else
        _generate_p10k_light
    fi

    rm -f "$HOME/.cache/p10k-instant-prompt-"*.zsh 2>/dev/null
    success ".p10k.zsh generated (tier: $TIER)"
    track_status "P10k Config" "OK"
}

_generate_p10k_standard() {
    cat > "$HOME/.p10k.zsh" << 'P10K_STD'
# Powerlevel10k config — standard tier (pi-bootstrap v20)
'builtin' 'local' '-a' 'p10k_config_opts'
[[ ! -o 'aliases'         ]] || p10k_config_opts+=('aliases')
[[ ! -o 'sh_glob'         ]] || p10k_config_opts+=('sh_glob')
[[ ! -o 'no_brace_expand' ]] || p10k_config_opts+=('no_brace_expand')
'builtin' 'setopt' 'no_aliases' 'no_sh_glob' 'brace_expand'

() {
  emulate -L zsh -o extended_glob
  unset -m '(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR'

  typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet
  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
    context dir vcs newline prompt_char
  )
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
    status command_execution_time background_jobs time
  )
  typeset -g POWERLEVEL9K_MODE=nerdfont-complete
  typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true
  typeset -g POWERLEVEL9K_SHORTEN_DIR_LENGTH=3
  typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_last
  typeset -g POWERLEVEL9K_DIR_FOREGROUND=31
  typeset -g POWERLEVEL9K_DIR_BACKGROUND=238
  typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=0
  typeset -g POWERLEVEL9K_VCS_CLEAN_BACKGROUND=2
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND=0
  typeset -g POWERLEVEL9K_VCS_UNTRACKED_BACKGROUND=3
  typeset -g POWERLEVEL9K_VCS_MODIFIED_FOREGROUND=0
  typeset -g POWERLEVEL9K_VCS_MODIFIED_BACKGROUND=3
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=2
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=1
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIINS_CONTENT_EXPANSION='❯'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VICMD_CONTENT_EXPANSION='❮'
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_THRESHOLD=3
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=0
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_BACKGROUND=3
  typeset -g POWERLEVEL9K_TIME_FORMAT='%D{%H:%M}'
  typeset -g POWERLEVEL9K_TIME_FOREGROUND=0
  typeset -g POWERLEVEL9K_TIME_BACKGROUND=7
  typeset -g POWERLEVEL9K_CONTEXT_ROOT_FOREGROUND=1
  typeset -g POWERLEVEL9K_CONTEXT_ROOT_BACKGROUND=0
  typeset -g POWERLEVEL9K_CONTEXT_{REMOTE,REMOTE_SUDO}_FOREGROUND=3
  typeset -g POWERLEVEL9K_CONTEXT_{REMOTE,REMOTE_SUDO}_BACKGROUND=0
  typeset -g POWERLEVEL9K_CONTEXT_FOREGROUND=3
  typeset -g POWERLEVEL9K_CONTEXT_BACKGROUND=0
  typeset -g POWERLEVEL9K_CONTEXT_TEMPLATE='%n@%m'
  typeset -g POWERLEVEL9K_CONTEXT_{DEFAULT,SUDO}_{CONTENT,VISUAL_IDENTIFIER}_EXPANSION=
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
    cat > "$HOME/.p10k.zsh" << 'P10K_LIGHT'
# Powerlevel10k config — light tier (pi-bootstrap v20)
'builtin' 'local' '-a' 'p10k_config_opts'
[[ ! -o 'aliases'         ]] || p10k_config_opts+=('aliases')
[[ ! -o 'sh_glob'         ]] || p10k_config_opts+=('sh_glob')
[[ ! -o 'no_brace_expand' ]] || p10k_config_opts+=('no_brace_expand')
'builtin' 'setopt' 'no_aliases' 'no_sh_glob' 'brace_expand'

() {
  emulate -L zsh -o extended_glob
  unset -m '(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR'

  typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet
  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(dir vcs prompt_char)
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(status)
  typeset -g POWERLEVEL9K_MODE=ascii
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=2
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=1
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIINS_CONTENT_EXPANSION='>'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VICMD_CONTENT_EXPANSION='<'
  typeset -g POWERLEVEL9K_SHORTEN_DIR_LENGTH=2
  typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_last
  typeset -g POWERLEVEL9K_DISABLE_GITSTATUS=true
  typeset -g POWERLEVEL9K_VCS_DISABLE_GITSTATUS_FORMATTING=true
  typeset -g POWERLEVEL9K_STATUS_OK=false
  typeset -g POWERLEVEL9K_STATUS_ERROR=true

  (( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
}

(( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
'builtin' 'unset' 'p10k_config_opts'
P10K_LIGHT
}

generate_starship_config() {
    [[ "$TIER" != "full" ]] && return 0
    header "GENERATING STARSHIP CONFIG"

    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] Would generate starship.toml"
        return 0
    fi

    mkdir -p "$HOME/.config"
    cat > "$HOME/.config/starship.toml" << 'STARSHIP'
# Starship config — Catppuccin Mocha (pi-bootstrap v20)

palette = "catppuccin_mocha"

format = """
[](surface0)\
$os\
$username\
$hostname\
[](bg:surface1 fg:surface0)\
$directory\
[](fg:surface1 bg:surface2)\
$git_branch\
$git_status\
[](fg:surface2 bg:overlay0)\
$cmd_duration\
[](fg:overlay0)\
$fill\
$time\
$line_break\
$character"""

[os]
disabled = true

[username]
show_always = false
style_user = "bg:surface0 fg:text"
style_root = "bg:surface0 fg:red bold"
format = '[$user]($style)'

[hostname]
ssh_only = true
style = "bg:surface0 fg:subtext1"
format = '[@$hostname]($style)'

[directory]
style = "bg:surface1 fg:text"
format = "[ $path ]($style)"
truncation_length = 3
truncation_symbol = ".../"

[git_branch]
symbol = ""
style = "bg:surface2 fg:text"
format = '[ $symbol $branch ]($style)'

[git_status]
style = "bg:surface2 fg:text"
format = '[$all_status$ahead_behind ]($style)'

[cmd_duration]
min_time = 3_000
style = "bg:overlay0 fg:text"
format = "[ $duration ]($style)"

[character]
success_symbol = "[>](bold green)"
error_symbol = "[>](bold red)"

[time]
disabled = false
time_format = "%H:%M"
style = "fg:subtext0"
format = '[$time]($style)'

[fill]
symbol = ' '

[palettes.catppuccin_mocha]
rosewater = "#f5e0dc"
flamingo = "#f2cdcd"
pink = "#f5c2e7"
mauve = "#cba6f7"
red = "#f38ba8"
maroon = "#eba0ac"
peach = "#fab387"
yellow = "#f9e2af"
green = "#a6e3a1"
teal = "#94e2d5"
sky = "#89dceb"
sapphire = "#74c7ec"
blue = "#89b4fa"
lavender = "#b4befe"
text = "#cdd6f4"
subtext1 = "#bac2de"
subtext0 = "#a6adc8"
overlay2 = "#9399b2"
overlay1 = "#7f849c"
overlay0 = "#6c7086"
surface2 = "#585b70"
surface1 = "#45475a"
surface0 = "#313244"
base = "#1e1e2e"
mantle = "#181825"
crust = "#11111b"
STARSHIP

    success "starship.toml generated with Catppuccin Mocha"
    track_status "Prompt" "OK"
}

#-------------------------------------------------------------------------------
# CATPPUCCIN MOCHA THEME
#-------------------------------------------------------------------------------
configure_catppuccin() {
    header "APPLYING CATPPUCCIN MOCHA THEME"

    configure_bat_theme
    configure_btop_theme
    configure_delta_theme
    configure_zellij_theme

    track_status "Catppuccin Theme" "OK"
}

configure_bat_theme() {
    command -v bat &>/dev/null || command -v batcat &>/dev/null || return 0

    local theme_dir="$HOME/.config/bat/themes"
    local theme_file="$theme_dir/Catppuccin Mocha.tmTheme"

    if [[ -f "$theme_file" ]]; then
        success "bat Catppuccin theme already present"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] Would install bat Catppuccin theme"
        return 0
    fi

    mkdir -p "$theme_dir"
    if curl -fsSL -o "$theme_file" \
        "https://raw.githubusercontent.com/catppuccin/bat/main/themes/Catppuccin%20Mocha.tmTheme" 2>/dev/null; then
        # Rebuild bat cache
        if command -v bat &>/dev/null; then
            bat cache --build &>/dev/null || true
        elif command -v batcat &>/dev/null; then
            batcat cache --build &>/dev/null || true
        fi
        success "bat Catppuccin theme installed"
    else
        warn "Could not download bat theme"
    fi

    # Set bat config
    mkdir -p "$HOME/.config/bat"
    cat > "$HOME/.config/bat/config" << 'BATCFG'
--theme="Catppuccin Mocha"
--style="numbers,changes,header"
BATCFG
}

configure_btop_theme() {
    command -v btop &>/dev/null || return 0

    local theme_dir="$HOME/.config/btop/themes"
    local theme_file="$theme_dir/catppuccin_mocha.theme"

    if [[ -f "$theme_file" ]]; then
        success "btop Catppuccin theme already present"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] Would install btop Catppuccin theme"
        return 0
    fi

    mkdir -p "$theme_dir"
    if curl -fsSL -o "$theme_file" \
        "https://raw.githubusercontent.com/catppuccin/btop/main/themes/catppuccin_mocha.theme" 2>/dev/null; then
        success "btop Catppuccin theme installed"
    else
        warn "Could not download btop theme"
    fi
}

configure_delta_theme() {
    command -v delta &>/dev/null || return 0

    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] Would configure delta in gitconfig"
        return 0
    fi

    # Only add if not already configured
    if grep -q '\[delta\]' "$HOME/.gitconfig" 2>/dev/null; then
        success "delta already configured in .gitconfig"
        return 0
    fi

    cat >> "$HOME/.gitconfig" << 'DELTACONF'

[core]
    pager = delta

[interactive]
    diffFilter = delta --color-only

[delta]
    navigate = true
    dark = true
    syntax-theme = "Catppuccin Mocha"
    minus-style = "syntax #3B1219"
    minus-emph-style = "syntax #5B2131"
    plus-style = "syntax #1B3224"
    plus-emph-style = "syntax #2B5738"
    line-numbers = true

[merge]
    conflictstyle = diff3

[diff]
    colorMoved = default
DELTACONF
    success "delta configured with Catppuccin"
}

configure_zellij_theme() {
    [[ "$TIER" != "full" ]] && return 0
    command -v zellij &>/dev/null || return 0

    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] Would configure Zellij theme"
        return 0
    fi

    mkdir -p "$HOME/.config/zellij"
    cat > "$HOME/.config/zellij/config.kdl" << 'ZELLIJCONF'
// Zellij config — Catppuccin Mocha (pi-bootstrap v20)
theme "catppuccin-mocha"

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
        cyan "#94e2d5"
        black "#1e1e2e"
        white "#cdd6f4"
    }
}
ZELLIJCONF
    success "Zellij configured with Catppuccin"
}

#-------------------------------------------------------------------------------
# TMUX CONFIGURATION
#-------------------------------------------------------------------------------
configure_tmux() {
    header "CONFIGURING TMUX"

    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] Would configure tmux"
        track_status "tmux Config" "OK"
        return 0
    fi

    # Install TPM
    local tpm_dir="$HOME/.tmux/plugins/tpm"
    if [[ ! -d "$tpm_dir" ]]; then
        if spin "Installing TPM (tmux plugin manager)" \
            git clone --depth=1 https://github.com/tmux-plugins/tpm "$tpm_dir"; then
            success "TPM installed"
        else
            warn "TPM install failed"
        fi
    else
        success "TPM already installed"
    fi

    # Generate tmux.conf
    cat > "$HOME/.tmux.conf" << 'TMUXCONF'
# tmux.conf — Catppuccin Mocha (pi-bootstrap v20)

# True color support
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",*256col*:Tc"

# Mouse support
set -g mouse on

# Scrollback
set -g history-limit 10000

# Start numbering at 1 (not 0)
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on

# Intuitive splits
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
unbind '"'
unbind %

# New window in current path
bind c new-window -c "#{pane_current_path}"

# Faster escape time
set -sg escape-time 10

# Focus events (for vim/neovim)
set -g focus-events on

# Reload config
bind r source-file ~/.tmux.conf \; display "Config reloaded"

# TPM plugins
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'catppuccin/tmux'

# Catppuccin config
set -g @catppuccin_flavor 'mocha'
set -g @catppuccin_window_status_style "rounded"
set -g @catppuccin_window_default_text " #W"
set -g @catppuccin_window_current_text " #W"

set -g status-right-length 100
set -g status-left-length 100
set -g status-left ""
set -g status-right "#{E:@catppuccin_status_application}"
set -agF status-right "#{E:@catppuccin_status_session}"
set -agF status-right "#{E:@catppuccin_status_date_time}"

# Initialize TPM (keep at bottom)
run '~/.tmux/plugins/tpm/tpm'
TMUXCONF

    success "tmux.conf generated with Catppuccin"
    track_status "tmux Config" "OK"
}

#-------------------------------------------------------------------------------
# MODULAR ALIASES
#-------------------------------------------------------------------------------
create_modular_aliases() {
    header "CREATING MODULAR ALIASES"

    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] Would create modular aliases"
        track_status "Modular Aliases" "OK"
        return 0
    fi

    local alias_dir="$HOME/.config/zsh/aliases"
    mkdir -p "$alias_dir"

    # --- docker.zsh ---
    cat > "$alias_dir/docker.zsh" << 'DOCKER_ALIASES'
# Docker aliases (pi-bootstrap v20)
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dcu='docker compose up -d'
alias dcd='docker compose down'
alias dlogs='docker compose logs -f'
alias dprune='docker system prune -af'
DOCKER_ALIASES

    # --- git.zsh ---
    cat > "$alias_dir/git.zsh" << 'GIT_ALIASES'
# Git aliases (pi-bootstrap v20)
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
    cat > "$alias_dir/navigation.zsh" << 'NAV_ALIASES'
# Navigation aliases (pi-bootstrap v20)
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

mkcd() { mkdir -p "$1" && cd "$1"; }
NAV_ALIASES

    # --- pi.zsh ---
    cat > "$alias_dir/pi.zsh" << 'PI_ALIASES'
# Raspberry Pi aliases (pi-bootstrap v20)
alias temp='vcgencmd measure_temp 2>/dev/null || echo "N/A"'
alias throttle='vcgencmd get_throttled 2>/dev/null || echo "vcgencmd not available"'
alias pimodel='cat /proc/device-tree/model 2>/dev/null && echo'
PI_ALIASES

    # --- system.zsh ---
    cat > "$alias_dir/system.zsh" << 'SYS_ALIASES'
# System aliases (pi-bootstrap v20)
alias update='sudo apt update && sudo apt upgrade -y'
alias ports='sudo ss -tulnp'
alias myip='curl -s ifconfig.me && echo'
alias cls='clear'
alias c='clear'
alias df='df -h'
alias du='du -h'
alias grep='grep --color=auto'

# Safety aliases
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# Listing
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
SYS_ALIASES

    # Add eza aliases if eza is available (full tier)
    if command -v eza &>/dev/null; then
        cat >> "$alias_dir/system.zsh" << 'EZA_ALIASES'

# eza (modern ls replacement)
alias ls='eza --icons --group-directories-first'
alias ll='eza -la --icons --group-directories-first'
alias tree='eza --tree --icons'
EZA_ALIASES
    fi

    # --- adhd.zsh ---
    cat > "$alias_dir/adhd.zsh" << 'ADHD_ALIASES'
# ADHD tools (pi-bootstrap v20)

# Fuzzy-search all aliases
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

# ntfy.sh notification
notify-done() {
    local msg="${1:-Task complete on $(hostname)}"
    local topic
    if [[ -f ~/.config/adhd-kit/ntfy-topic ]]; then
        topic=$(<~/.config/adhd-kit/ntfy-topic)
        topic=$(echo "$topic" | tr -d '[:space:]')
    fi
    if [[ -n "${topic:-}" ]]; then
        curl -s -d "$msg" "https://ntfy.sh/${topic}"
        echo "Notification sent to ntfy.sh/${topic}"
    else
        echo "Set your ntfy topic: mkdir -p ~/.config/adhd-kit && echo 'your-topic' > ~/.config/adhd-kit/ntfy-topic"
    fi
}
ADHD_ALIASES

    success "Modular aliases created ($(ls -1 "$alias_dir" | wc -l) files)"
    track_status "Modular Aliases" "OK"
}

#-------------------------------------------------------------------------------
# GENERATE .ZSHRC
#-------------------------------------------------------------------------------
generate_zshrc() {
    header "GENERATING .zshrc"

    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] Would generate .zshrc"
        track_status "Generate .zshrc" "OK"
        return 0
    fi

    # Write the common header
    cat > "$HOME/.zshrc" << 'ZSHRC_HEAD'
#===============================================================================
# .zshrc — Generated by pi-bootstrap v20
# ADHD-Friendly Configuration with Antidote + Catppuccin Mocha
#===============================================================================

#-------------------------------------------------------------------------------
# MOTD (must run BEFORE instant prompt to avoid p10k warning)
#-------------------------------------------------------------------------------
if [[ -o login && -f /etc/profile.d/99-earthlume-motd.sh ]]; then
    bash /etc/profile.d/99-earthlume-motd.sh
fi

ZSHRC_HEAD

    # Tier-specific prompt init
    if [[ "$TIER" == "full" ]]; then
        # Starship — no instant prompt needed
        cat >> "$HOME/.zshrc" << 'ZSHRC_STARSHIP_NOTE'
# Prompt: Starship (full tier — configured in ~/.config/starship.toml)
ZSHRC_STARSHIP_NOTE
    else
        # P10k instant prompt
        cat >> "$HOME/.zshrc" << 'ZSHRC_P10K_INSTANT'
#-------------------------------------------------------------------------------
# POWERLEVEL10K INSTANT PROMPT (must be near top of .zshrc)
#-------------------------------------------------------------------------------
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

ZSHRC_P10K_INSTANT
    fi

    # Common body
    cat >> "$HOME/.zshrc" << 'ZSHRC_BODY'
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
# HISTORY — searchable, deduplicated, shared across sessions
#-------------------------------------------------------------------------------
HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt HIST_IGNORE_ALL_DUPS    # No duplicate entries
setopt HIST_FIND_NO_DUPS       # Don't show dupes when searching
setopt SHARE_HISTORY           # Share history across terminals
setopt INC_APPEND_HISTORY      # Write immediately, not on exit

#-------------------------------------------------------------------------------
# SHELL OPTIONS — reduce friction
#-------------------------------------------------------------------------------
setopt CORRECT                 # Correct commands
setopt CORRECT_ALL             # Correct arguments too
SPROMPT="Correct %R to %r? [nyae] "
setopt AUTO_CD                 # cd by just typing directory name
setopt AUTO_PUSHD              # Push dirs onto stack automatically
setopt PUSHD_IGNORE_DUPS       # No duplicate dirs in stack
setopt PUSHD_SILENT            # Don't print stack after pushd/popd
setopt COMPLETE_IN_WORD        # Complete from cursor position
setopt ALWAYS_TO_END           # Move cursor to end after completion

#-------------------------------------------------------------------------------
# COMPLETION — cached daily rebuild
#-------------------------------------------------------------------------------
autoload -Uz compinit
if [[ -n ${ZDOTDIR:-$HOME}/.zcompdump(#qN.mh+24) ]]; then
    compinit
else
    compinit -C
fi
zstyle ':completion:*' menu select

#-------------------------------------------------------------------------------
# KEY BINDINGS — arrow key partial history search
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

# Catppuccin Mocha palette for fzf
export FZF_DEFAULT_OPTS=" \
  --color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8 \
  --color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc \
  --color=marker:#b4befe,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8 \
  --color=selected-bg:#45475a \
  --border=\"rounded\" --preview-window=\"border-rounded\" \
  --prompt=\"> \" --marker=\">\" --pointer=\">\" --separator=\"-\" \
  --scrollbar=\"|\" --info=\"right\""

#-------------------------------------------------------------------------------
# ZOXIDE (smart cd)
#-------------------------------------------------------------------------------
command -v zoxide &>/dev/null && eval "$(zoxide init zsh)"

#-------------------------------------------------------------------------------
# AUTO-LS AFTER CD (immediate spatial awareness)
#-------------------------------------------------------------------------------
autoload -Uz add-zsh-hook
__auto_ls() { ls --color=auto; }
add-zsh-hook chpwd __auto_ls

#-------------------------------------------------------------------------------
# COLORED MAN PAGES (easier to scan)
#-------------------------------------------------------------------------------
export LESS_TERMCAP_mb=$'\e[1;31m'
export LESS_TERMCAP_md=$'\e[1;36m'
export LESS_TERMCAP_me=$'\e[0m'
export LESS_TERMCAP_so=$'\e[1;33;44m'
export LESS_TERMCAP_se=$'\e[0m'
export LESS_TERMCAP_us=$'\e[1;32m'
export LESS_TERMCAP_ue=$'\e[0m'

#-------------------------------------------------------------------------------
# TERMINAL TITLE + LONG COMMAND NOTIFICATION
#-------------------------------------------------------------------------------
TBEEP=30
_CMD_START=0
_CMD_NAME=""

preexec() {
    _CMD_START=$EPOCHSECONDS
    _CMD_NAME="$1"
}

precmd() {
    # Set terminal title
    print -Pn "\e]2;%n@%m: %~\a"

    # Bell after long commands (catches attention on task switch)
    if (( _CMD_START && EPOCHSECONDS - _CMD_START >= TBEEP )); then
        print "\a"
    fi

    # ntfy.sh push notification for very long commands (>60s)
    local _ntfy_topic=""
    [[ -f ~/.config/adhd-kit/ntfy-topic ]] && _ntfy_topic=$(<~/.config/adhd-kit/ntfy-topic)
    _ntfy_topic=$(echo "${_ntfy_topic:-}" | tr -d '[:space:]')
    if [[ -n "$_ntfy_topic" ]] && (( _CMD_START && EPOCHSECONDS - _CMD_START >= 60 )); then
        curl -s -d "Done ($(( EPOCHSECONDS - _CMD_START ))s): ${_CMD_NAME}" \
            "https://ntfy.sh/${_ntfy_topic}" &>/dev/null &
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

ZSHRC_BODY

    # Tier-specific prompt init at the end
    if [[ "$TIER" == "full" ]]; then
        cat >> "$HOME/.zshrc" << 'ZSHRC_STARSHIP'
#-------------------------------------------------------------------------------
# STARSHIP PROMPT
#-------------------------------------------------------------------------------
eval "$(starship init zsh)"
ZSHRC_STARSHIP
    else
        cat >> "$HOME/.zshrc" << 'ZSHRC_P10K'
#-------------------------------------------------------------------------------
# POWERLEVEL10K
#-------------------------------------------------------------------------------
source ~/.powerlevel10k/powerlevel10k.zsh-theme
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh
ZSHRC_P10K
    fi

    success ".zshrc generated (tier: $TIER)"
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
        success "[DRY RUN] Would install MOTD"
        track_status "Custom MOTD" "OK"
        return 0
    fi

    log "Creating dynamic MOTD script..."

    sudo tee /etc/profile.d/99-earthlume-motd.sh > /dev/null << 'MOTD_SCRIPT'
#!/bin/bash
#===============================================================================
# Earthlume's Fun Homelab — Dynamic MOTD
# Version: 20
#===============================================================================

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_WHITE='\033[1;37m'
C_TEAL='\033[38;5;30m'

BOX_W=59

# Hostname color from /etc/pi-role
if [[ -f /etc/pi-role ]]; then
    case "$(cat /etc/pi-role | tr -d '[:space:]')" in
        prod|production) HOST_COLOR="${C_RED}" ;;
        dev|development) HOST_COLOR="${C_GREEN}" ;;
        monitor*)        HOST_COLOR='\033[0;34m' ;;
        *)               HOST_COLOR="${C_TEAL}" ;;
    esac
else
    HOST_COLOR="${C_TEAL}"
fi

# Taglines
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
    "Held together with zip ties"
    "Future me problem"
    "chmod 777 and pray"
    "Over-engineered with love"
    "99% uptime, 1% dread"
    "Keep calm and blame the network"
    "Have you tried rebooting?"
    "The Sage of Shadowdale says: read the logs"
    "The Sage of Shadowdale says: always check DNS first"
    "The Sage of Shadowdale says: backups are love letters to your future self"
    "The Sage of Shadowdale says: a reboot solves 90% of problems"
    "The Sage of Shadowdale says: never deploy on Friday"
    "The Sage of Shadowdale says: if it ain't broke, don't upgrade it"
    "Cowie approves of this session"
    "Gemma walked across the keyboard. Check recent commits."
)

TIPS=(
    "btop = pretty system monitor"
    "ncdu = find what's eating disk"
    "z dirname = jump to frequent dirs"
    "Ctrl+R = fuzzy search command history"
    "temp = check CPU temperature"
    "ports = see what's listening"
    "!! = repeat last command"
    "sudo !! = last command as root"
    "Ctrl+L = clear screen"
    "halp = fuzzy-search all aliases"
    "whereami = instant context when lost"
    "today = see what you did today"
    "notify-done = push notification via ntfy"
    "man pages are color-coded now!"
    "cd into a dir = auto-ls for free"
    "zsh-you-should-use will remind you of aliases"
    "prefix+| = tmux vertical split"
    "prefix+- = tmux horizontal split"
)

TAGLINE="${TAGLINES[$((RANDOM % ${#TAGLINES[@]}))]}"

strip_ansi() {
    echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

boxline() {
    local content="$1"
    local plain=$(strip_ansi "$content")
    local len=${#plain}
    local pad=$((BOX_W - len))
    (( pad < 0 )) && pad=0
    printf "${C_CYAN}│${C_RESET} %b%*s ${C_CYAN}│${C_RESET}\n" "$content" "$pad" ""
}

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

# Gather system info
HOSTNAME_UPPER=$(hostname | tr '[:lower:]' '[:upper:]')
UPTIME_STR=$(uptime -p 2>/dev/null) || UPTIME_STR="Up ?"
UPTIME_STR="${UPTIME_STR/up /Up }"

if [[ -f /proc/device-tree/model ]]; then
    PI_MODEL=$(tr -d '\0' < /proc/device-tree/model | sed 's/Raspberry Pi /RPi /')
else
    PI_MODEL="Linux"
fi

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_INFO="${ID^} ${VERSION_ID:-}"
    [[ -n "$VERSION_CODENAME" ]] && OS_INFO+=" (${VERSION_CODENAME})"
else
    OS_INFO="Linux"
fi

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

CPU_PCT=$(timeout 2 top -bn1 2>/dev/null | awk '/Cpu\(s\)/{print int($2)}')
[[ -z "$CPU_PCT" ]] && CPU_PCT="?"

read -r RAM_USED RAM_TOTAL <<< "$(free -m | awk '/^Mem:/{print $3, $2}')"
RAM_PCT=$((RAM_USED * 100 / RAM_TOTAL))
if (( RAM_PCT < 70 )); then RAM_COLOR="${C_GREEN}"
elif (( RAM_PCT < 85 )); then RAM_COLOR="${C_YELLOW}"
else RAM_COLOR="${C_RED}"; fi

read -r DISK_USED DISK_TOTAL DISK_PCT <<< "$(df -h / | awk 'NR==2{gsub(/%/,"",$5); print $3, $2, $5}')"
if (( DISK_PCT < 70 )); then DISK_COLOR="${C_GREEN}"
elif (( DISK_PCT < 85 )); then DISK_COLOR="${C_YELLOW}"
else DISK_COLOR="${C_RED}"; fi

IP_ADDR=$(timeout 2 hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$IP_ADDR" ]] && IP_ADDR="unknown"
NET_IF=$(timeout 2 ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
[[ -z "$NET_IF" ]] && NET_IF="eth0"
MAC_ADDR=$(cat "/sys/class/net/${NET_IF}/address" 2>/dev/null || echo "unknown")

STATS="${TEMP_STR}  ${C_DIM}CPU${C_RESET} ${CPU_PCT}%  ${C_DIM}RAM${C_RESET} ${RAM_COLOR}${RAM_PCT}%${C_RESET}  ${C_DIM}Disk${C_RESET} ${DISK_COLOR}${DISK_PCT}%${C_RESET} ${C_DIM}(${DISK_USED}/${DISK_TOTAL})${C_RESET}"

# Print the MOTD
echo ""
printf "${C_CYAN}╭─────────────────────────────────────────────────────────────╮${C_RESET}\n"
boxline2 "${C_BOLD}${HOST_COLOR}${HOSTNAME_UPPER}${C_RESET}" "${C_DIM}lab.hoens.fun${C_RESET}"
boxline "${C_DIM}\"${TAGLINE}\"${C_RESET}"
printf "${C_CYAN}├─────────────────────────────────────────────────────────────┤${C_RESET}\n"
boxline2 "${PI_MODEL}" "${UPTIME_STR}"
boxline "${C_DIM}${OS_INFO} · Kernel ${KERNEL_VER}${C_RESET}"
boxline "${STATS}"
boxline "${IP_ADDR} ${C_DIM}(${NET_IF})${C_RESET}  ${C_DIM}MAC${C_RESET} ${MAC_ADDR}"

# Docker container status
if command -v docker &>/dev/null; then
    local running=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
    local total=$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$total" -gt 0 ]]; then
        printf "${C_CYAN}├─────────────────────────────────────────────────────────────┤${C_RESET}\n"
        boxline "${C_DIM}Docker${C_RESET}  ${C_GREEN}${running}${C_RESET}/${total} containers running"
    fi
fi

# Alias quick reference
printf "${C_CYAN}├─────────────────────────────────────────────────────────────┤${C_RESET}\n"
boxline "${C_BOLD}${C_WHITE}Quick Reference${C_RESET}         ${C_DIM}type${C_RESET} ${C_CYAN}halp${C_RESET} ${C_DIM}to fuzzy-search all${C_RESET}"
boxline "${C_DIM}ll${C_RESET} list  ${C_DIM}..${C_RESET} up dir  ${C_DIM}update${C_RESET} apt  ${C_DIM}temp${C_RESET} heat"
boxline "${C_DIM}gs${C_RESET} git st ${C_DIM}gd${C_RESET} diff   ${C_DIM}myip${C_RESET} pub IP ${C_DIM}ports${C_RESET} listen"
boxline "${C_CYAN}whereami${C_RESET} ${C_DIM}context${C_RESET}  ${C_CYAN}today${C_RESET} ${C_DIM}activity${C_RESET}  ${C_CYAN}notify-done${C_RESET} ${C_DIM}ntfy${C_RESET}"

# ~30% chance to show a tip
if (( RANDOM % 10 < 3 )); then
    TIP="${TIPS[$((RANDOM % ${#TIPS[@]}))]}"
    printf "${C_CYAN}├─────────────────────────────────────────────────────────────┤${C_RESET}\n"
    boxline "${C_DIM}tip: ${TIP}${C_RESET}"
fi

printf "${C_CYAN}╰─────────────────────────────────────────────────────────────╯${C_RESET}\n"
echo ""
MOTD_SCRIPT

    sudo chmod +x /etc/profile.d/99-earthlume-motd.sh

    # Remove default Debian MOTD
    if [[ -f /etc/motd ]] && [[ -s /etc/motd ]]; then
        sudo truncate -s 0 /etc/motd
    fi

    # Disable default MOTD scripts
    if [[ -d /etc/update-motd.d ]]; then
        sudo chmod -x /etc/update-motd.d/* 2>/dev/null || true
    fi

    # Disable SSH last login message
    if [[ -d /etc/ssh/sshd_config.d ]]; then
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
        success "[DRY RUN] Would change shell to zsh"
        track_status "Change Shell" "OK"
        return 0
    fi

    # Detect non-interactive (piped install)
    if [[ ! -t 0 ]]; then
        warn "Non-interactive mode — run manually:"
        echo -e "    ${BOLD}chsh -s $zsh_path${NC}"
        track_status "Change Shell" "SKIP"
        return 0
    fi

    log "Changing default shell to zsh..."
    if chsh -s "$zsh_path"; then
        success "Default shell changed to zsh"
        warn "Log out and back in for change to take effect"
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
        log "Skipping optimizations (use --optimize to enable)"
        track_status "Optimizations" "SKIP"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] Would apply system optimizations"
        track_status "Optimizations" "OK"
        return 0
    fi

    local opt_failures=0

    # Reduce swappiness
    if [[ $(cat /proc/sys/vm/swappiness) -gt 10 ]]; then
        log "Reducing swappiness to 10..."
        if echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf > /dev/null; then
            sudo sysctl -p /etc/sysctl.d/99-swappiness.conf 2>/dev/null
            success "Swappiness reduced"
        else
            ((opt_failures++)) || true
        fi
    else
        success "Swappiness already optimal"
    fi

    # Limit journal size
    local jdrop="/etc/systemd/journald.conf.d/99-earthlume-limit.conf"
    if [[ -f "$jdrop" ]] && grep -qE '^\s*SystemMaxUse\s*=\s*50M\s*$' "$jdrop" 2>/dev/null; then
        success "Journald already limited"
    else
        log "Limiting journald to 50MB..."
        if sudo mkdir -p /etc/systemd/journald.conf.d && \
           printf "[Journal]\nSystemMaxUse=50M\n" | sudo tee "$jdrop" >/dev/null; then
            sudo systemctl restart systemd-journald 2>/dev/null || true
            success "Journald limited"
        else
            ((opt_failures++)) || true
        fi
    fi

    # PCIe Gen 3 on Pi 5
    if [[ "$HAS_PCIE" == true ]] && [[ -n "${BOOT_CONFIG:-}" ]]; then
        if grep -qE '^\s*dtparam=pciex1_gen=3' "$BOOT_CONFIG" 2>/dev/null; then
            success "PCIe Gen 3 already enabled"
        else
            log "Enabling PCIe Gen 3 in $BOOT_CONFIG..."
            if echo -e "\n# PCIe Gen 3 (pi-bootstrap)\ndtparam=pciex1_gen=3" | sudo tee -a "$BOOT_CONFIG" >/dev/null; then
                success "PCIe Gen 3 enabled (reboot required)"
            else
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
            if cat << 'FANCURVE' | sudo tee -a "$BOOT_CONFIG" >/dev/null

# Fan curve — start early, ramp fast (pi-bootstrap)
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
                success "Fan curve configured (reboot required)"
            else
                ((opt_failures++)) || true
            fi
        fi
    fi

    if [[ $opt_failures -eq 0 ]]; then
        track_status "Optimizations" "OK"
    else
        track_status "Optimizations" "FAIL"
    fi
}

#-------------------------------------------------------------------------------
# HEALTH CHECK
#-------------------------------------------------------------------------------
health_check() {
    header "HEALTH CHECK (baseline snapshot)"

    if command -v vcgencmd &>/dev/null; then
        local temp throttle firmware
        temp=$(vcgencmd measure_temp 2>/dev/null || echo "N/A")
        throttle=$(vcgencmd get_throttled 2>/dev/null || echo "N/A")
        firmware=$(vcgencmd version 2>/dev/null | head -1 || echo "N/A")

        log "  Temp:      $temp"
        log "  Throttle:  $throttle"
        log "  Firmware:  $firmware"

        local flags="${throttle##*=}"
        if [[ "$flags" == "0x0" ]]; then
            success "No throttling detected"
        elif [[ "$flags" =~ ^0x[0-9a-fA-F]+$ ]]; then
            warn "Throttle flags: $flags"
            [[ $((flags & 0x1)) -ne 0 ]] && warn "  Under-voltage detected"
            [[ $((flags & 0x2)) -ne 0 ]] && warn "  ARM frequency capped"
            [[ $((flags & 0x4)) -ne 0 ]] && warn "  Currently throttled"
            [[ $((flags & 0x8)) -ne 0 ]] && warn "  Soft temperature limit"
        fi
    else
        log "  vcgencmd not available"
    fi

    # dmesg error scan
    log "  Scanning dmesg..."
    local dmesg_issues
    dmesg_issues=$(dmesg --level=err,warn 2>/dev/null || sudo dmesg --level=err,warn 2>/dev/null)
    dmesg_issues=$(echo "$dmesg_issues" | grep -iE 'voltage|throttl|nvme|error|fail|orphan' | tail -10)
    if [[ -n "$dmesg_issues" ]]; then
        warn "dmesg flagged items (see log)"
        while IFS= read -r line; do
            log "    $line"
        done <<< "$dmesg_issues"
    else
        success "dmesg clean"
    fi

    track_status "Health Check" "OK"
}

#-------------------------------------------------------------------------------
# WRITE /etc/pi-info
#-------------------------------------------------------------------------------
write_pi_info() {
    if [[ "$DRY_RUN" == true ]]; then
        success "[DRY RUN] Would write /etc/pi-info"
        return 0
    fi

    log "Writing /etc/pi-info..."

    local net_if
    net_if=$(timeout 2 ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
    [[ -z "$net_if" ]] && net_if="eth0"
    local ip_addr mac_addr
    ip_addr=$(timeout 2 hostname -I 2>/dev/null | awk '{print $1}')
    mac_addr=$(cat "/sys/class/net/${net_if}/address" 2>/dev/null || echo "unknown")

    sudo tee /etc/pi-info >/dev/null <<EOF
# Pi network info — pi-bootstrap v${VERSION} on $(date -Iseconds)
HOSTNAME=$(hostname)
MODEL=$PI_MODEL
INTERFACE=$net_if
IP_ADDRESS=${ip_addr:-unknown}
MAC_ADDRESS=${mac_addr}
EOF
    success "Wrote /etc/pi-info"
}

#-------------------------------------------------------------------------------
# UNINSTALL
#-------------------------------------------------------------------------------
uninstall_bootstrap() {
    echo ""
    echo -e "${BOLD}${CYAN}PI-BOOTSTRAP UNINSTALL${NC}"
    echo ""
    echo "This will remove pi-bootstrap configuration files:"
    echo "  - ~/.antidote/"
    echo "  - ~/.powerlevel10k/"
    echo "  - ~/.zsh_plugins.txt, ~/.zsh_plugins.zsh"
    echo "  - ~/.config/zsh/aliases/"
    echo "  - ~/.config/starship.toml"
    echo "  - ~/.config/bat/themes/Catppuccin*"
    echo "  - ~/.config/btop/themes/catppuccin*"
    echo "  - ~/.config/zellij/"
    echo "  - ~/.tmux.conf, ~/.tmux/plugins/"
    echo "  - /etc/profile.d/99-earthlume-motd.sh"
    echo ""
    echo "Installed packages (zsh, fzf, bat, etc.) will NOT be removed."
    echo ""

    if [[ -t 0 ]]; then
        echo -n "Proceed? [y/N] "
        read -r yn
        [[ "$yn" != [yY]* ]] && { echo "Cancelled."; return 0; }
    else
        echo "Non-interactive mode — proceeding with uninstall"
    fi

    rm -rf "$HOME/.antidote"
    rm -rf "$HOME/.powerlevel10k"
    rm -f "$HOME/.zsh_plugins.txt" "$HOME/.zsh_plugins.zsh"
    rm -rf "$HOME/.config/zsh/aliases"
    rm -f "$HOME/.config/starship.toml"
    rm -f "$HOME/.config/bat/themes/Catppuccin"* 2>/dev/null
    rm -f "$HOME/.config/btop/themes/catppuccin"* 2>/dev/null
    rm -rf "$HOME/.config/zellij"
    rm -f "$HOME/.tmux.conf"
    rm -rf "$HOME/.tmux/plugins"
    sudo rm -f /etc/profile.d/99-earthlume-motd.sh 2>/dev/null || true

    # Restore backup if available
    local latest_backup
    latest_backup=$(ls -1d "$HOME/.pi-bootstrap-backups/"* 2>/dev/null | tail -1)
    if [[ -n "$latest_backup" ]] && [[ -d "$latest_backup" ]]; then
        echo ""
        echo "Restoring configs from: $latest_backup"
        for f in "$latest_backup"/*; do
            [[ -f "$f" ]] && cp "$f" "$HOME/" && echo "  Restored: $(basename "$f")"
        done
    fi

    echo ""
    echo -e "${GREEN}Uninstall complete.${NC}"
    echo "To switch back to bash: chsh -s /bin/bash"
    return 0
}

#-------------------------------------------------------------------------------
# FINAL SUMMARY
#-------------------------------------------------------------------------------
print_summary() {
    header "BOOTSTRAP COMPLETE"

    echo ""
    echo -e "${BOLD}INSTALLATION STATUS${NC}"
    echo "───────────────────────────────────────────────────────────"

    local all_steps=(
        "Hardware Detection" "Backup Configs" "Time Sync" "OS Update"
        "Core Packages" "Full Packages" "Antidote" "Plugins" "Prompt"
        "P10k Config" "Fonts" "Generate .zshrc" "Catppuccin Theme"
        "tmux Config" "Modular Aliases" "Custom MOTD" "Change Shell"
        "Optimizations" "Health Check"
    )

    for step in "${all_steps[@]}"; do
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
        echo -e "${RED}$FAILURES step(s) failed — review above for details${NC}"
    else
        echo -e "${GREEN}All steps completed successfully${NC}"
    fi

    echo ""
    echo -e "${BOLD}SYSTEM${NC}"
    echo "───────────────────────────────────────────────────────────"
    echo "  Model:    $PI_MODEL"
    echo "  OS:       $OS_NAME"
    echo "  RAM:      ${RAM_MB} MB"
    echo "  Arch:     $DPKG_ARCH"
    echo "  Tier:     $TIER"
    echo ""

    echo -e "${BOLD}FILES CREATED${NC}"
    echo "───────────────────────────────────────────────────────────"
    echo "  Config:    ~/.zshrc"
    echo "  Plugins:   ~/.zsh_plugins.txt"
    echo "  Aliases:   ~/.config/zsh/aliases/*.zsh"
    if [[ "$TIER" == "full" ]]; then
        echo "  Prompt:    ~/.config/starship.toml"
    else
        echo "  Prompt:    ~/.p10k.zsh"
    fi
    echo "  tmux:      ~/.tmux.conf"
    echo "  MOTD:      /etc/profile.d/99-earthlume-motd.sh"
    echo "  Pi Info:   /etc/pi-info"
    echo "  Backups:   $BACKUP_DIR"
    echo "  Log:       $LOG_FILE"
    echo ""

    echo -e "${BOLD}NEXT STEPS${NC}"
    echo "───────────────────────────────────────────────────────────"
    echo "  1. Log out and back in (or run: exec zsh)"
    if [[ "$TIER" != "full" ]]; then
        echo "  2. Set terminal font to 'MesloLGS NF'"
        echo "  3. Run 'p10k configure' to customize prompt per machine"
    fi
    echo ""

    echo -e "${BOLD}NTFY.SH NOTIFICATIONS${NC}"
    echo "───────────────────────────────────────────────────────────"
    echo "  Get push notifications when long commands finish:"
    echo "    mkdir -p ~/.config/adhd-kit"
    echo "    echo 'your-topic' > ~/.config/adhd-kit/ntfy-topic"
    echo "  Subscribe at https://ntfy.sh or the ntfy mobile app."
    echo ""

    echo -e "${DIM}Full diagnostics: bash pi-bootstrap.sh --info-only${NC}"
    echo -e "${DIM}Undo everything:  bash pi-bootstrap.sh --uninstall${NC}"
    echo ""
}

#-------------------------------------------------------------------------------
# MAIN
#-------------------------------------------------------------------------------
main() {
    parse_args "$@"

    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║   PI-BOOTSTRAP — ADHD-Friendly Shell Setup  (v${VERSION})       ║${NC}"
    echo -e "${BOLD}${CYAN}║   by Earthlume · lab.hoens.fun                          ║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Initialize log
    echo "=== pi-bootstrap.sh v${VERSION} started $(date -Iseconds) ===" > "$LOG_FILE"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}DRY RUN MODE — no changes will be made${NC}"
        echo ""
    fi

    # Info-only mode
    if [[ "$INFO_ONLY" == true ]]; then
        print_system_info
        return 0
    fi

    # Full install
    detect_system
    backup_configs
    verify_time_sync       || true
    update_os              || true
    install_core_packages  || true
    install_standard_packages || true
    install_zoxide         || true
    install_uv             || true
    install_full_packages  || true
    install_starship       || true
    install_zellij         || true
    install_antidote       || true
    create_plugin_list     || true
    install_p10k           || true
    install_fonts          || true
    generate_p10k_config   || true
    generate_starship_config || true
    generate_zshrc
    configure_catppuccin   || true
    configure_tmux         || true
    create_modular_aliases || true
    install_motd           || true
    change_shell           || true
    apply_optimizations    || true
    health_check           || true
    write_pi_info          || true
    print_summary

    return $FAILURES
}

main "$@"
