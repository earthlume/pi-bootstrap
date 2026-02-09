#!/bin/bash
#===============================================================================
# pi-bootstrap.sh — Echolume's ADHD-Friendly Pi Shell Setup
# Version: 18
#
# WHAT:  Installs zsh + oh-my-zsh + powerlevel10k with sane defaults
# WHY:   Reduce cognitive load; make CLI accessible
# HOW:   Auto-detects hardware, picks FULL or LITE tier
#
# USAGE: curl -fsSL <url> | bash
#    or: bash pi-bootstrap.sh [--optimize] [--no-update] [--no-chsh] [--info-only]
#
# FLAGS:
#   --optimize   Apply safe system tweaks (swappiness, journald limits)
#   --no-update  Skip apt update/upgrade (default: updates run with kernel held)
#   --no-chsh    Don't change default shell to zsh
#   --info-only  Just print system info and exit (for pasting back to Cosmo)
#   --no-motd    Skip MOTD installation
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# CONFIGURATION
#-------------------------------------------------------------------------------
BACKUP_DIR="$HOME/.pi-bootstrap-backups/$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$HOME/pi-bootstrap.log"
ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

# Tier thresholds
MIN_RAM_FOR_FULL_MB=1800  # ~2GB threshold (actual reports ~1.8-1.9GB usable)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'
DIM='\033[2m'

# Status tracking
declare -A STATUS
FAILURES=0

#-------------------------------------------------------------------------------
# PARSE ARGUMENTS
#-------------------------------------------------------------------------------
DO_OPTIMIZE=false
DO_UPDATE=true
DO_CHSH=true
DO_MOTD=true
INFO_ONLY=false

for arg in "$@"; do
    case $arg in
        --optimize)   DO_OPTIMIZE=true ;;
        --no-update)  DO_UPDATE=false ;;
        --no-chsh)    DO_CHSH=false ;;
        --no-motd)    DO_MOTD=false ;;
        --info-only)  INFO_ONLY=true ;;
        --help|-h)
            echo "Usage: $0 [--optimize] [--no-update] [--no-chsh] [--no-motd] [--info-only]"
            echo ""
            echo "Flags:"
            echo "  --optimize    Apply safe system tweaks (swappiness, journald)"
            echo "  --no-update   Skip apt update/upgrade (runs by default, kernel held)"
            echo "  --no-chsh     Don't change default shell to zsh"
            echo "  --no-motd     Don't install custom MOTD"
            echo "  --info-only   Just print system info and exit"
            exit 0
            ;;
    esac
done

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
# Usage: spin "Descriptive label" command arg1 arg2 ...
# Returns the command's exit code. Output goes to log file.
spin() {
    local label="$1"
    shift
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local start=$SECONDS

    # Run command in background, redirect output to log
    # Subshell wrapper: set +e so set -e doesn't kill us, and capture the
    # real exit code via wait.
    ( "$@" ) >> "$LOG_FILE" 2>&1 &
    local pid=$!

    # Animate while process runs (|| true guards against set -e)
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(( SECONDS - start ))
        local mins=$(( elapsed / 60 ))
        local secs=$(( elapsed % 60 ))
        printf "\r  ${CYAN}%s${NC} %s ${DIM}%d:%02d${NC} " "${frames[i++ % ${#frames[@]}]}" "$label" "$mins" "$secs"
        sleep 0.1
    done

    # Get exit code (capture before || true so we keep the real code)
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
# SYSTEM DETECTION
#-------------------------------------------------------------------------------
detect_system() {
    header "DETECTING HARDWARE"
    
    # Architecture
    ARCH=$(uname -m)
    log "Architecture: $ARCH"
    
    # Pi Model (from device tree or /proc/cpuinfo)
    if [[ -f /proc/device-tree/model ]]; then
        PI_MODEL=$(tr -d '\0' < /proc/device-tree/model)
    elif grep -q "Model" /proc/cpuinfo 2>/dev/null; then
        PI_MODEL=$(grep "Model" /proc/cpuinfo | cut -d: -f2 | xargs)
    else
        PI_MODEL="Unknown (not a Pi?)"
    fi
    log "Model: $PI_MODEL"
    
    # RAM in MB
    RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    RAM_MB=$((RAM_KB / 1024))
    log "RAM: ${RAM_MB} MB"
    
    # OS Info
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_NAME="${PRETTY_NAME:-Unknown}"
        OS_VERSION_ID="${VERSION_ID:-unknown}"
    else
        OS_NAME="Unknown"
        OS_VERSION_ID="unknown"
    fi
    log "OS: $OS_NAME"
    
    # Kernel
    KERNEL=$(uname -r)
    log "Kernel: $KERNEL"
    
    # Bits (32 vs 64)
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        BITS=64
    else
        BITS=32
    fi
    log "Bits: $BITS"
    
    # Storage
    ROOT_SIZE=$(df -h / | awk 'NR==2 {print $2}')
    ROOT_AVAIL=$(df -h / | awk 'NR==2 {print $4}')
    ROOT_USED_PCT=$(df -h / | awk 'NR==2 {print $5}')
    log "Root filesystem: $ROOT_SIZE total, $ROOT_AVAIL available ($ROOT_USED_PCT used)"
    
    # Decide tier
    if [[ $RAM_MB -ge $MIN_RAM_FOR_FULL_MB && $BITS -eq 64 ]]; then
        TIER="FULL"
    else
        TIER="LITE"
    fi
    log "Selected tier: ${BOLD}$TIER${NC}"
    
    # Check for special hardware
    HAS_PCIE=false
    if [[ -d /sys/bus/pci/devices ]] && ls /sys/bus/pci/devices/ 2>/dev/null | grep -q .; then
        HAS_PCIE=true
    fi
    log "PCIe detected: $HAS_PCIE"

    # Boot config location (needed for PCIe Gen 3 optimization)
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
# EXTENDED HARDWARE DETECTION (for summary)
#-------------------------------------------------------------------------------
detect_extended_hardware() {
    log "Gathering system info for summary..."
    
    # CPU info
    log "  → CPU info..."
    CPU_CORES=$(nproc 2>/dev/null || echo "?")
    CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "ARM")
    
    # Temperature
    if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
        TEMP_RAW=$(cat /sys/class/thermal/thermal_zone0/temp)
        TEMP_C=$((TEMP_RAW / 1000))
    else
        TEMP_C="N/A"
    fi
    
    # Throttling status (Pi-specific)
    log "  → Throttle status..."
    if command -v vcgencmd &>/dev/null; then
        THROTTLE_STATUS=$(timeout 3 vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo "N/A")
    else
        THROTTLE_STATUS="vcgencmd not available"
    fi
    
    # Camera detection (v4 fix: use compgen instead of -d on device node)
    log "  → Camera detection..."
    if compgen -G "/dev/video*" > /dev/null 2>&1; then
        CAMERA_DEVICES=$(ls /dev/video* 2>/dev/null | tr '\n' ' ')
        [[ -z "$CAMERA_DEVICES" ]] && CAMERA_DEVICES="none detected"
    else
        CAMERA_DEVICES="none detected"
    fi
    
    # Check for libcamera (newer Pi camera stack)
    if command -v libcamera-hello &>/dev/null; then
        LIBCAMERA="installed"
    else
        LIBCAMERA="not installed"
    fi
    
    # I2C status (with timeout to prevent hang)
    log "  → I2C status..."
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
    
    # USB devices (with timeout)
    log "  → USB devices..."
    if command -v lsusb &>/dev/null; then
        USB_DEVICES=$(timeout 5 lsusb 2>/dev/null | wc -l || echo "0")
        USB_DEVICE_LIST=$(timeout 5 lsusb 2>/dev/null | grep -vi "hub" | head -5 || echo "none")
    else
        USB_DEVICES="lsusb not available"
        USB_DEVICE_LIST=""
    fi
    
    # Network interfaces (with timeout)
    log "  → Network interfaces..."
    NET_INTERFACES=$(timeout 3 ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v lo | tr '\n' ' ' || echo "unknown")
    
    # WiFi status
    if command -v iwconfig &>/dev/null; then
        WIFI_INTERFACE=$(timeout 3 iwconfig 2>/dev/null | grep -o "^wlan[0-9]" | head -1 || echo "none")
    else
        WIFI_INTERFACE=$(timeout 3 ip link show 2>/dev/null | grep -o "wlan[0-9]" | head -1 || echo "none")
    fi
    
    # Bluetooth
    log "  → Bluetooth..."
    if command -v bluetoothctl &>/dev/null; then
        BT_STATUS="available"
    elif [[ -d /sys/class/bluetooth ]]; then
        BT_STATUS="available (no bluetoothctl)"
    else
        BT_STATUS="not detected"
    fi
    
    # Boot config location (varies by OS version)
    # NOTE: may already be set by detect_system(); only set if unset
    log "  → Boot config..."
    if [[ -z "${BOOT_CONFIG:-}" ]]; then
        if [[ -f /boot/firmware/config.txt ]]; then
            BOOT_CONFIG="/boot/firmware/config.txt"
        elif [[ -f /boot/config.txt ]]; then
            BOOT_CONFIG="/boot/config.txt"
        else
            BOOT_CONFIG=""
        fi
    fi
    
    # Check for common Pi overlays/settings
    if [[ -f "$BOOT_CONFIG" && "$BOOT_CONFIG" != "not found" ]]; then
        BOOT_OVERLAYS=$(grep "^dtoverlay=" "$BOOT_CONFIG" 2>/dev/null | cut -d= -f2 | tr '\n' ', ' || echo "none")
        [[ -z "$BOOT_OVERLAYS" ]] && BOOT_OVERLAYS="none configured"
    else
        BOOT_OVERLAYS="unknown"
    fi
    
    log "  → Done gathering info"
}

#-------------------------------------------------------------------------------
# PRINT SYSTEM INFO (for pasting back)
#-------------------------------------------------------------------------------
print_system_info() {
    detect_system
    detect_extended_hardware
    
    header "SYSTEM INFO — PASTE THIS BACK TO COSMO"
    
    cat <<EOF

\`\`\`
═══════════════════════════════════════════════════════════
SYSTEM PROFILE — $(date -Iseconds)
═══════════════════════════════════════════════════════════

HARDWARE
--------
PI_MODEL:     $PI_MODEL
ARCH:         $ARCH ($BITS-bit)
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
BOOT_CONFIG:  $BOOT_CONFIG

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
═══════════════════════════════════════════════════════════
\`\`\`

EOF
    
    # Additional info if Pi 5
    if echo "$PI_MODEL" | grep -qi "pi 5"; then
        echo "--- Pi 5 Specific ---"
        if [[ -f "$BOOT_CONFIG" ]]; then
            echo "PCIe config:"
            grep -i pcie "$BOOT_CONFIG" 2>/dev/null || echo "(no pcie settings found)"
        fi
    fi
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
        track_status "Backup Configs" "SKIP"
    fi
}

#-------------------------------------------------------------------------------
# UPDATE OS (runs by default; skip with --no-update)
#-------------------------------------------------------------------------------
# Strategy: apt update + apt upgrade with kernel/firmware packages held.
#   - DEBIAN_FRONTEND=noninteractive  → suppresses all interactive prompts
#   - dpkg --force-confold             → keeps YOUR config files on conflicts
#   - apt-mark hold on kernel pkgs     → prevents kernel upgrades that break
#                                        DKMS modules (Hailo, camera, etc.)
#   - apt upgrade (NOT full-upgrade)   → never removes packages
#-------------------------------------------------------------------------------
APT_ENV=(sudo env DEBIAN_FRONTEND=noninteractive)
APT_DPKG_OPTS=(-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)

# Kernel/firmware packages to hold during upgrade
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
        log "Skipping OS update (--no-update flag set)"
        track_status "OS Update" "SKIP"
        return 0
    fi

    # Hold kernel packages to prevent DKMS breakage
    log "Holding kernel/firmware packages..."
    local held=()
    for pkg in "${KERNEL_HOLD_PKGS[@]}"; do
        if dpkg -l "$pkg" &>/dev/null; then
            sudo apt-mark hold "$pkg" &>/dev/null && held+=("$pkg")
        fi
    done
    if [[ ${#held[@]} -gt 0 ]]; then
        success "Held ${#held[@]} kernel pkg(s): ${held[*]}"
    else
        log "No installed kernel packages found to hold (non-Pi or custom setup)"
    fi

    # Update package lists
    if ! spin "Refreshing package lists" \
        "${APT_ENV[@]}" apt-get update -qq; then
        track_status "OS Update" "FAIL"
        return 1
    fi

    # Upgrade packages (safe: never removes, never touches held kernel)
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
# INSTALL PACKAGES
#-------------------------------------------------------------------------------
install_packages() {
    header "INSTALLING PACKAGES"

    # Ensure package lists are fresh (skips if update_os already ran)
    if [[ "$DO_UPDATE" == false ]]; then
        if ! spin "Refreshing package lists" \
            "${APT_ENV[@]}" apt-get update -qq; then
            track_status "Install Packages" "FAIL"
            return 1
        fi
    fi

    local packages=(
        zsh
        git
        curl
        wget
        fontconfig
        # Useful utilities
        btop
        ncdu
        tree
        jq
    )

    log "Installing: ${packages[*]}"
    if spin "Installing packages (${#packages[@]} items)" \
        "${APT_ENV[@]}" apt-get install -y -qq "${APT_DPKG_OPTS[@]}" "${packages[@]}"; then
        track_status "Install Packages" "OK"
    else
        track_status "Install Packages" "FAIL"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# INSTALL OH-MY-ZSH
#-------------------------------------------------------------------------------
install_ohmyzsh() {
    header "INSTALLING OH-MY-ZSH"
    
    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        warn "oh-my-zsh already installed, skipping"
        track_status "Oh-My-Zsh" "SKIP"
        return 0
    fi
    
    # Download install script first, then run with spinner
    local omz_script
    omz_script=$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh) || {
        error "Failed to download oh-my-zsh installer"
        track_status "Oh-My-Zsh" "FAIL"
        return 1
    }

    if spin "Installing oh-my-zsh" \
        env RUNZSH=no CHSH=no sh -c "$omz_script"; then
        track_status "Oh-My-Zsh" "OK"
    else
        track_status "Oh-My-Zsh" "FAIL"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# INSTALL ZSH PLUGINS
#-------------------------------------------------------------------------------
install_plugins() {
    header "INSTALLING ZSH PLUGINS"
    
    # Ensure custom dir exists
    mkdir -p "$ZSH_CUSTOM/plugins"
    
    local plugin_failures=0
    
    # zsh-autosuggestions
    local autosug_dir="$ZSH_CUSTOM/plugins/zsh-autosuggestions"
    if [[ ! -d "$autosug_dir" ]]; then
        if ! spin "Cloning zsh-autosuggestions" \
            git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$autosug_dir"; then
            ((plugin_failures++)) || true
        fi
    else
        warn "zsh-autosuggestions already present"
    fi

    # zsh-syntax-highlighting
    local synhi_dir="$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
    if [[ ! -d "$synhi_dir" ]]; then
        if ! spin "Cloning zsh-syntax-highlighting" \
            git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting "$synhi_dir"; then
            ((plugin_failures++)) || true
        fi
    else
        warn "zsh-syntax-highlighting already present"
    fi
    
    # z (directory jumper) - comes with oh-my-zsh, just needs enabling
    success "z plugin ready (bundled with oh-my-zsh)"
    
    if [[ $plugin_failures -eq 0 ]]; then
        track_status "Zsh Plugins" "OK"
    else
        track_status "Zsh Plugins" "FAIL"
    fi
}

#-------------------------------------------------------------------------------
# INSTALL POWERLEVEL10K
#-------------------------------------------------------------------------------
install_p10k() {
    header "INSTALLING POWERLEVEL10K"
    
    local p10k_dir="$ZSH_CUSTOM/themes/powerlevel10k"
    
    if [[ ! -d "$p10k_dir" ]]; then
        if spin "Cloning powerlevel10k" \
            git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$p10k_dir"; then
            track_status "Powerlevel10k" "OK"
        else
            track_status "Powerlevel10k" "FAIL"
            return 1
        fi
    else
        warn "powerlevel10k already present"
        track_status "Powerlevel10k" "SKIP"
    fi
}

#-------------------------------------------------------------------------------
# INSTALL FONTS (for powerlevel10k icons)
#-------------------------------------------------------------------------------
install_fonts() {
    header "INSTALLING NERD FONTS"
    
    local font_dir="$HOME/.local/share/fonts"
    mkdir -p "$font_dir"
    
    # MesloLGS NF (recommended for p10k)
    local fonts=(
        "MesloLGS%20NF%20Regular.ttf"
        "MesloLGS%20NF%20Bold.ttf"
        "MesloLGS%20NF%20Italic.ttf"
        "MesloLGS%20NF%20Bold%20Italic.ttf"
    )
    
    local base_url="https://github.com/romkatv/powerlevel10k-media/raw/master"
    local font_failures=0
    
    for font in "${fonts[@]}"; do
        local decoded_font=$(echo "$font" | sed 's/%20/ /g')
        if [[ ! -f "$font_dir/$decoded_font" ]]; then
            if ! spin "Downloading $decoded_font" \
                curl -fsSL -o "$font_dir/$decoded_font" "$base_url/$font"; then
                ((font_failures++)) || true
            fi
        fi
    done

    # Rebuild font cache
    spin "Rebuilding font cache" fc-cache -f "$font_dir" || true
    
    if [[ $font_failures -eq 0 ]]; then
        success "Fonts installed (configure your terminal to use 'MesloLGS NF')"
        track_status "Nerd Fonts" "OK"
    else
        warn "Some fonts failed to download"
        track_status "Nerd Fonts" "FAIL"
    fi
}

#-------------------------------------------------------------------------------
# GENERATE ZSHRC
#-------------------------------------------------------------------------------
generate_zshrc() {
    header "GENERATING .zshrc"
    
    # Plugin list differs by tier
    if [[ "$TIER" == "FULL" ]]; then
        local plugins="git z zsh-autosuggestions zsh-syntax-highlighting"
    else
        # LITE: fewer plugins for resource savings
        local plugins="git z zsh-autosuggestions"
    fi
    
    cat > "$HOME/.zshrc" <<'ZSHRC_HEADER'
#===============================================================================
# .zshrc — Generated by pi-bootstrap.sh
# ADHD-Friendly Configuration
#===============================================================================

#-------------------------------------------------------------------------------
# MOTD (must run BEFORE instant prompt to avoid p10k warning)
#-------------------------------------------------------------------------------
if [[ -o login && -f /etc/profile.d/99-echolume-motd.sh ]]; then
    bash /etc/profile.d/99-echolume-motd.sh
fi

# Path to oh-my-zsh installation
export ZSH="$HOME/.oh-my-zsh"

# Theme: powerlevel10k
ZSH_THEME="powerlevel10k/powerlevel10k"

# Enable instant prompt (faster startup) — must come after MOTD
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

ZSHRC_HEADER

    # Add plugins line
    echo "plugins=($plugins)" >> "$HOME/.zshrc"
    
    cat >> "$HOME/.zshrc" <<'ZSHRC_BODY'

# Load oh-my-zsh
source $ZSH/oh-my-zsh.sh

#-------------------------------------------------------------------------------
# ADHD-FRIENDLY SETTINGS
#-------------------------------------------------------------------------------

# History: searchable, deduplicated, shared across sessions
HISTSIZE=50000
SAVEHIST=50000
setopt HIST_IGNORE_ALL_DUPS    # No duplicate entries
setopt HIST_FIND_NO_DUPS       # Don't show dupes when searching
setopt SHARE_HISTORY           # Share history across terminals
setopt INC_APPEND_HISTORY      # Write immediately, not on exit

# Auto-correction (suggest fixes for typos)
setopt CORRECT                 # Correct commands
setopt CORRECT_ALL             # Correct arguments too
SPROMPT="Correct %R to %r? [nyae] "

# Directory navigation made easy
setopt AUTO_CD                 # cd by just typing directory name
setopt AUTO_PUSHD              # Push dirs onto stack automatically
setopt PUSHD_IGNORE_DUPS       # No duplicate dirs in stack
setopt PUSHD_SILENT            # Don't print stack after pushd/popd

# Completion improvements
setopt COMPLETE_IN_WORD        # Complete from cursor position
setopt ALWAYS_TO_END           # Move cursor to end after completion
zstyle ':completion:*' menu select  # Arrow-key menu for completions

#-------------------------------------------------------------------------------
# SAFETY ALIASES (confirm before overwrite/delete)
#-------------------------------------------------------------------------------
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

#-------------------------------------------------------------------------------
# USEFUL ALIASES
#-------------------------------------------------------------------------------
# ls improvements
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'

# Grep with color
alias grep='grep --color=auto'

# Clear screen
alias cls='clear'
alias c='clear'

# Quick navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# System shortcuts
alias update='sudo apt update && sudo apt upgrade -y'
alias reboot='sudo reboot'
alias shutdown='sudo shutdown -h now'

# Disk usage (human readable)
alias df='df -h'
alias du='du -h'
alias duf='du -sh * | sort -h'  # Folder sizes, sorted

# Process shortcuts
alias psg='ps aux | grep -v grep | grep'
alias topcpu='ps aux --sort=-%cpu | head -11'
alias topmem='ps aux --sort=-%mem | head -11'

# Network
alias myip='curl -s ifconfig.me && echo'
alias ports='sudo ss -tulnp'

# Raspberry Pi specific
alias temp='/opt/vc/bin/vcgencmd measure_temp 2>/dev/null || cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk "{print \$1/1000\" C\"}"'
alias throttle='vcgencmd get_throttled 2>/dev/null || echo "vcgencmd not available"'

# Git shortcuts (if you use git)
alias gs='git status'
alias gd='git diff'
alias gl='git log --oneline -20'
alias gp='git pull'

#-------------------------------------------------------------------------------
# ALIAS MANAGER
#-------------------------------------------------------------------------------
# Usage: aliases              — show all custom aliases
#        aliases search <str> — filter aliases by keyword
#        aliases add <name> <command>  — add a custom alias
#        aliases remove <name>         — remove a custom alias
#        aliases help          — show usage
CUSTOM_ALIAS_FILE="$HOME/.zsh_custom_aliases"
[[ -f "$CUSTOM_ALIAS_FILE" ]] && source "$CUSTOM_ALIAS_FILE"

aliases() {
    local C_R='\033[0m' C_B='\033[1m' C_D='\033[2m' C_C='\033[0;36m' C_G='\033[0;32m' C_Y='\033[1;33m' C_W='\033[1;37m' C_RED='\033[0;31m'
    local subcmd="${1:-}"

    _aliases_header() {
        printf "${C_C}╭────────────────────────────────────────────────────────╮${C_R}\n"
        printf "${C_C}│${C_R} ${C_B}${C_W}Pi-Bootstrap Alias Manager${C_R}                             ${C_C}│${C_R}\n"
        printf "${C_C}├────────────────────────────────────────────────────────┤${C_R}\n"
    }
    _aliases_footer() {
        printf "${C_C}╰────────────────────────────────────────────────────────╯${C_R}\n"
    }
    _aliases_section() {
        printf "${C_C}│${C_R}                                                        ${C_C}│${C_R}\n"
        printf "${C_C}│${C_R} ${C_B}${C_Y}%s${C_R}%*s${C_C}│${C_R}\n" "$1" $((55 - ${#1})) ""
        printf "${C_C}│${C_R} ${C_D}%s${C_R}%*s${C_C}│${C_R}\n" "────────────────────────────────────────────────────" 3 ""
    }
    _aliases_row() {
        local name="$1" desc="$2"
        local padname=12
        local padded=$(printf "%-${padname}s" "$name")
        local total=$(( ${#padded} + ${#desc} ))
        local gap=$((53 - total))
        (( gap < 0 )) && gap=0
        printf "${C_C}│${C_R}  ${C_G}%-${padname}s${C_R} ${C_D}%s${C_R}%*s${C_C}│${C_R}\n" "$name" "$desc" "$gap" ""
    }

    case "$subcmd" in
        help|-h|--help)
            _aliases_header
            _aliases_section "Usage"
            _aliases_row "aliases" "show all aliases"
            _aliases_row "aliases search" "<keyword> — filter list"
            _aliases_row "aliases add" "<name> <cmd> — add alias"
            _aliases_row "aliases remove" "<name> — remove alias"
            _aliases_row "aliases help" "this help message"
            _aliases_footer
            ;;
        search)
            local query="${2:-}"
            if [[ -z "$query" ]]; then
                echo "Usage: aliases search <keyword>"
                return 1
            fi
            _aliases_header
            _aliases_section "Search: $query"
            alias | grep -i "$query" | while IFS= read -r line; do
                local aname="${line%%=*}"
                local acmd="${line#*=}"
                acmd="${acmd#\'}"
                acmd="${acmd%\'}"
                [[ ${#acmd} -gt 38 ]] && acmd="${acmd:0:35}..."
                _aliases_row "$aname" "$acmd"
            done
            _aliases_footer
            ;;
        add)
            local aname="${2:-}" acmd="${*:3}"
            if [[ -z "$aname" || -z "$acmd" ]]; then
                echo "Usage: aliases add <name> <command>"
                return 1
            fi
            echo "alias $aname='$acmd'" >> "$CUSTOM_ALIAS_FILE"
            eval "alias $aname='$acmd'"
            printf "${C_G}✓${C_R} Alias ${C_B}%s${C_R} → %s  ${C_D}(saved to %s)${C_R}\n" "$aname" "$acmd" "$CUSTOM_ALIAS_FILE"
            ;;
        remove|rm)
            local aname="${2:-}"
            if [[ -z "$aname" ]]; then
                echo "Usage: aliases remove <name>"
                return 1
            fi
            if [[ -f "$CUSTOM_ALIAS_FILE" ]] && grep -q "^alias $aname=" "$CUSTOM_ALIAS_FILE"; then
                sed -i "/^alias $aname=/d" "$CUSTOM_ALIAS_FILE"
                unalias "$aname" 2>/dev/null
                printf "${C_RED}✗${C_R} Alias ${C_B}%s${C_R} removed  ${C_D}(updated %s)${C_R}\n" "$aname" "$CUSTOM_ALIAS_FILE"
            else
                echo "Alias '$aname' not found in custom aliases."
                echo "Note: built-in aliases from .zshrc cannot be removed here."
                return 1
            fi
            ;;
        *)
            _aliases_header
            _aliases_section "Safety"
            _aliases_row "rm" "confirm before delete (rm -i)"
            _aliases_row "cp" "confirm before overwrite (cp -i)"
            _aliases_row "mv" "confirm before overwrite (mv -i)"
            _aliases_section "Screen"
            _aliases_row "cls / c" "clear screen"
            _aliases_section "Navigation"
            _aliases_row ".." "up one directory"
            _aliases_row "..." "up two directories"
            _aliases_row "...." "up three directories"
            _aliases_section "Listing & Search"
            _aliases_row "ll" "detailed list (ls -lah)"
            _aliases_row "la" "show hidden files (ls -A)"
            _aliases_row "l" "compact columns (ls -CF)"
            _aliases_row "grep" "colorized grep"
            _aliases_section "System"
            _aliases_row "update" "apt update + upgrade"
            _aliases_row "reboot" "sudo reboot"
            _aliases_row "shutdown" "sudo shutdown now"
            _aliases_row "df" "disk free (human-readable)"
            _aliases_row "du" "disk usage (human-readable)"
            _aliases_row "duf" "folder sizes, sorted"
            _aliases_section "Processes"
            _aliases_row "psg" "<name> — search processes"
            _aliases_row "topcpu" "top CPU consumers"
            _aliases_row "topmem" "top memory consumers"
            _aliases_section "Network"
            _aliases_row "myip" "show public IP"
            _aliases_row "ports" "listening ports"
            _aliases_section "Raspberry Pi"
            _aliases_row "temp" "CPU temperature"
            _aliases_row "throttle" "throttle status"
            _aliases_section "Git"
            _aliases_row "gs" "git status"
            _aliases_row "gd" "git diff"
            _aliases_row "gl" "git log (last 20)"
            _aliases_row "gp" "git pull"
            _aliases_section "ADHD Tools"
            _aliases_row "whereami" "context: dir + git + recent cmds"
            _aliases_row "today" "what did I do today?"
            _aliases_row "trash" "<file> — safe delete with undo"
            _aliases_row "trash list" "show trashed files"
            _aliases_row "trash restore" "<n> — bring file back"
            _aliases_row "aliases" "this cheat sheet"

            # Show custom aliases if any exist
            if [[ -f "$CUSTOM_ALIAS_FILE" ]] && [[ -s "$CUSTOM_ALIAS_FILE" ]]; then
                _aliases_section "Custom (~/.zsh_custom_aliases)"
                while IFS= read -r line; do
                    if [[ "$line" =~ ^alias\ ([^=]+)=\'(.+)\'$ ]]; then
                        local cname="${match[1]}" ccmd="${match[2]}"
                        [[ ${#ccmd} -gt 38 ]] && ccmd="${ccmd:0:35}..."
                        _aliases_row "$cname" "$ccmd"
                    fi
                done < "$CUSTOM_ALIAS_FILE"
            fi

            printf "${C_C}│${C_R}                                                        ${C_C}│${C_R}\n"
            printf "${C_C}│${C_R} ${C_D}Type ${C_C}aliases help${C_D} for add/remove/search commands${C_R}       ${C_C}│${C_R}\n"
            _aliases_footer
            ;;
    esac
}

#-------------------------------------------------------------------------------
# AUTO-LS AFTER CD (immediate spatial awareness)
#-------------------------------------------------------------------------------
autoload -Uz add-zsh-hook
__auto_ls() { ls --color=auto; }
add-zsh-hook chpwd __auto_ls

#-------------------------------------------------------------------------------
# COLORED MAN PAGES (scannable, not a wall of monochrome text)
#-------------------------------------------------------------------------------
export LESS_TERMCAP_mb=$'\e[1;31m'     # begin bold
export LESS_TERMCAP_md=$'\e[1;36m'     # begin blink — cyan headings
export LESS_TERMCAP_me=$'\e[0m'        # end bold/blink
export LESS_TERMCAP_so=$'\e[1;33;44m'  # begin standout — yellow on blue
export LESS_TERMCAP_se=$'\e[0m'        # end standout
export LESS_TERMCAP_us=$'\e[1;32m'     # begin underline — green
export LESS_TERMCAP_ue=$'\e[0m'        # end underline

#-------------------------------------------------------------------------------
# LONG-COMMAND NOTIFICATION (bell after 10s+ commands)
#   Terminal will flash/bounce when you've tabbed away
#-------------------------------------------------------------------------------
__cmd_timer_preexec() { __cmd_start=$SECONDS; }
__cmd_timer_precmd() {
    if (( ${__cmd_start:-0} > 0 )); then
        local elapsed=$(( SECONDS - __cmd_start ))
        if (( elapsed >= 10 )); then
            printf '\a'
        fi
    fi
    unset __cmd_start
}
add-zsh-hook preexec __cmd_timer_preexec
add-zsh-hook precmd __cmd_timer_precmd

#-------------------------------------------------------------------------------
# TRASH (safe delete with undo — less anxiety than rm -i)
#-------------------------------------------------------------------------------
TRASH_DIR="$HOME/.local/share/Trash"

trash() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: trash <file> [file2 ...]"
        echo "       trash list          — show trashed files"
        echo "       trash restore <n>   — restore file by number"
        echo "       trash empty         — permanently delete all"
        return 1
    fi

    case "$1" in
        list)
            if [[ ! -d "$TRASH_DIR" ]] || [[ -z "$(command ls -A "$TRASH_DIR" 2>/dev/null)" ]]; then
                echo "Trash is empty."
                return 0
            fi
            echo "Trashed files (newest first):"
            echo "──────────────────────────────────────"
            local i=1
            local files=("${(@f)$(command ls -lt "$TRASH_DIR" | tail -n +2)}")
            for line in "${files[@]}"; do
                printf "  %3d) %s\n" "$i" "$line"
                ((i++))
            done
            echo ""
            echo "Restore with: trash restore <number>"
            ;;
        restore)
            local n="${2:-}"
            if [[ -z "$n" ]]; then
                echo "Usage: trash restore <number>"
                echo "Run 'trash list' to see available files."
                return 1
            fi
            local file=$(command ls -t "$TRASH_DIR" 2>/dev/null | sed -n "${n}p")
            if [[ -z "$file" ]]; then
                echo "No file at position $n."
                return 1
            fi
            # Strip __trashed_<timestamp> suffix to recover original name
            local original="${file%.__trashed_*}"
            [[ -z "$original" ]] && original="$file"
            if [[ -e "$original" ]]; then
                echo "Warning: '$original' already exists in current directory."
                echo -n "Overwrite? [y/N] "
                read -r yn
                [[ "$yn" != [yY]* ]] && return 1
            fi
            command mv "$TRASH_DIR/$file" "./$original"
            echo "Restored: $original"
            ;;
        empty)
            if [[ ! -d "$TRASH_DIR" ]] || [[ -z "$(command ls -A "$TRASH_DIR" 2>/dev/null)" ]]; then
                echo "Trash is already empty."
                return 0
            fi
            local count=$(command ls -1 "$TRASH_DIR" | wc -l | tr -d ' ')
            echo -n "Permanently delete $count item(s)? [y/N] "
            read -r yn
            if [[ "$yn" == [yY]* ]]; then
                command rm -rf "$TRASH_DIR"/*
                echo "Trash emptied."
            fi
            ;;
        *)
            mkdir -p "$TRASH_DIR"
            for f in "$@"; do
                if [[ ! -e "$f" ]]; then
                    echo "Not found: $f"
                    continue
                fi
                local base="$(basename "$f")"
                local dest="${base}.__trashed_$(date +%s)"
                command mv "$f" "$TRASH_DIR/$dest"
                echo "Trashed: $f"
            done
            ;;
    esac
}

#-------------------------------------------------------------------------------
# WHEREAMI (context recovery — "what was I doing?")
#-------------------------------------------------------------------------------
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

#-------------------------------------------------------------------------------
# TODAY (daily activity journal — fight time blindness)
#-------------------------------------------------------------------------------
today() {
    local C='\033[0;36m' B='\033[1m' D='\033[2m' G='\033[0;32m' Y='\033[1;33m' R='\033[0m'

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

#-------------------------------------------------------------------------------
# AUTOSUGGESTION CONFIG
#-------------------------------------------------------------------------------
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20

#-------------------------------------------------------------------------------
# LOAD P10K CONFIG
#-------------------------------------------------------------------------------
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh

#-------------------------------------------------------------------------------
# CUSTOM PATH ADDITIONS (add your own below)
#-------------------------------------------------------------------------------
# export PATH="$HOME/.local/bin:$PATH"

ZSHRC_BODY

    success ".zshrc generated"
    track_status "Generate .zshrc" "OK"
}

#-------------------------------------------------------------------------------
# GENERATE P10K CONFIG (pre-configured, no wizard needed)
#-------------------------------------------------------------------------------
generate_p10k_config() {
    header "GENERATING POWERLEVEL10K CONFIG"
    
    if [[ "$TIER" == "FULL" ]]; then
        generate_p10k_full
    else
        generate_p10k_lite
    fi
    
    success ".p10k.zsh generated (tier: $TIER)"
    track_status "Generate .p10k.zsh" "OK"
}

generate_p10k_full() {
    # Full config with all the bells and whistles
    cat > "$HOME/.p10k.zsh" <<'P10K_FULL'
# Powerlevel10k config — FULL tier
# Pre-configured for ADHD-friendly visibility

'builtin' 'local' '-a' 'p10k_config_opts'
[[ ! -o 'aliases'         ]] || p10k_config_opts+=('aliases')
[[ ! -o 'sh_glob'         ]] || p10k_config_opts+=('sh_glob')
[[ ! -o 'no_brace_expand' ]] || p10k_config_opts+=('no_brace_expand')
'builtin' 'setopt' 'no_aliases' 'no_sh_glob' 'brace_expand'

() {
  emulate -L zsh -o extended_glob

  unset -m '(POWERLEVEL9K_*|DEFAULT_USER)~POWERLEVEL9K_GITSTATUS_DIR'

  # Instant prompt mode
  typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet

  # Left prompt: user context, directory, git
  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
    context                 # user@hostname
    dir                     # current directory
    vcs                     # git status
    newline                 # line break
    prompt_char             # prompt symbol
  )

  # Right prompt: status, command time, background jobs
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
    status                  # exit code of last command
    command_execution_time  # how long last command took
    background_jobs         # background job indicator
    time                    # current time
  )

  # Basic style
  typeset -g POWERLEVEL9K_MODE=nerdfont-complete
  typeset -g POWERLEVEL9K_PROMPT_ON_NEWLINE=false
  typeset -g POWERLEVEL9K_RPROMPT_ON_NEWLINE=false
  typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true

  # Directory: show last 3 segments, truncate long names
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

  # Prompt character (shows red on error)
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=2
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=1
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIINS_CONTENT_EXPANSION='❯'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VICMD_CONTENT_EXPANSION='❮'

  # Command execution time (show if > 3 seconds)
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_THRESHOLD=3
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_FOREGROUND=0
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_BACKGROUND=3

  # Time format
  typeset -g POWERLEVEL9K_TIME_FORMAT='%D{%H:%M}'
  typeset -g POWERLEVEL9K_TIME_FOREGROUND=0
  typeset -g POWERLEVEL9K_TIME_BACKGROUND=7

  # Context: show user@host only when SSH or root
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

  # Transient prompt (clean up old prompts)
  typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=off

  (( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
}

(( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
'builtin' 'unset' 'p10k_config_opts'
P10K_FULL
}

generate_p10k_lite() {
    # Minimal config for Pi Zero / low-resource devices
    cat > "$HOME/.p10k.zsh" <<'P10K_LITE'
# Powerlevel10k config — LITE tier (for Pi Zero / low RAM)
# Minimal segments for speed

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
    dir                     # current directory
    vcs                     # git status (lightweight)
    prompt_char             # prompt symbol
  )

  # Minimal right prompt
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
    status                  # exit code only on error
  )

  # Use ASCII for compatibility
  typeset -g POWERLEVEL9K_MODE=ascii

  # Simple prompt char
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=2
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_{VIINS,VICMD,VIVIS,VIOWR}_FOREGROUND=1
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VIINS_CONTENT_EXPANSION='>'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_{OK,ERROR}_VICMD_CONTENT_EXPANSION='<'

  # Directory
  typeset -g POWERLEVEL9K_SHORTEN_DIR_LENGTH=2
  typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_last

  # Disable gitstatus (use fallback) for speed on low-end hardware
  typeset -g POWERLEVEL9K_DISABLE_GITSTATUS=true
  typeset -g POWERLEVEL9K_VCS_DISABLE_GITSTATUS_FORMATTING=true

  # Status only on error
  typeset -g POWERLEVEL9K_STATUS_OK=false
  typeset -g POWERLEVEL9K_STATUS_ERROR=true

  (( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
}

(( ${#p10k_config_opts} )) && setopt ${p10k_config_opts[@]}
'builtin' 'unset' 'p10k_config_opts'
P10K_LITE
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
    
    log "Creating dynamic MOTD script..."
    
    # Create the MOTD script
    sudo tee /etc/profile.d/99-echolume-motd.sh > /dev/null << 'MOTD_SCRIPT'
#!/bin/bash
#===============================================================================
# Echolume's Fun Homelab — Dynamic MOTD
# lab.hoens.fun
# Version: 18
#===============================================================================

# Colors
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_WHITE='\033[1;37m'

# Box width (inner content = 63 total - 4 for borders = 59)
BOX_W=59

# Taglines — random on each login
TAGLINES=(
    "It compiles. Ship it."
    "Works on my machine"
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
    "aliases = show all shortcuts"
    "aliases add <name> <cmd> = custom alias"
    "aliases search <keyword> = filter list"
    "whereami = instant context when lost"
    "today = see what you did today"
    "trash <file> = safe delete with undo"
    "trash list = see what you trashed"
    "man pages are color-coded now!"
    "cd into a dir = auto-ls for free"
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

# Gather system info
HOSTNAME_UPPER=$(hostname | tr '[:lower:]' '[:upper:]')
UPTIME_STR=$(uptime -p 2>/dev/null | sed 's/up /Up /' || echo "Up ?")

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
    [[ -n "$VERSION_CODENAME" ]] && OS_INFO+=" (${VERSION_CODENAME})"
else
    OS_INFO="Linux"
fi

# Kernel (just major.minor.patch)
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

# CPU usage (with timeout)
CPU_PCT=$(timeout 2 top -bn1 2>/dev/null | awk '/Cpu\(s\)/{print int($2)}')
[[ -z "$CPU_PCT" ]] && CPU_PCT="?"

# RAM with color
read -r RAM_USED RAM_TOTAL <<< $(free -m | awk '/^Mem:/{print $3, $2}')
RAM_PCT=$((RAM_USED * 100 / RAM_TOTAL))
if (( RAM_PCT < 70 )); then
    RAM_COLOR="${C_GREEN}"
elif (( RAM_PCT < 85 )); then
    RAM_COLOR="${C_YELLOW}"
else
    RAM_COLOR="${C_RED}"
fi

# Disk with color
read -r DISK_USED DISK_TOTAL DISK_PCT <<< $(df -h / | awk 'NR==2{gsub(/%/,"",$5); print $3, $2, $5}')
if (( DISK_PCT < 70 )); then
    DISK_COLOR="${C_GREEN}"
elif (( DISK_PCT < 85 )); then
    DISK_COLOR="${C_YELLOW}"
else
    DISK_COLOR="${C_RED}"
fi

# IP address and interface
IP_ADDR=$(timeout 2 hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$IP_ADDR" ]] && IP_ADDR="unknown"
NET_IF=$(timeout 2 ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
[[ -z "$NET_IF" ]] && NET_IF="eth0"

# Build stats line
STATS="${TEMP_STR}  ${C_DIM}CPU${C_RESET} ${CPU_PCT}%  ${C_DIM}RAM${C_RESET} ${RAM_COLOR}${RAM_PCT}%${C_RESET}  ${C_DIM}Disk${C_RESET} ${DISK_COLOR}${DISK_PCT}%${C_RESET} ${C_DIM}(${DISK_USED}/${DISK_TOTAL})${C_RESET}"

# Print the MOTD
echo ""
printf "${C_CYAN}╭─────────────────────────────────────────────────────────────╮${C_RESET}\n"
boxline2 "${C_BOLD}${C_WHITE}${HOSTNAME_UPPER}${C_RESET}" "${C_DIM}lab.hoens.fun${C_RESET}"
boxline "${C_DIM}\"${TAGLINE}\"${C_RESET}"
printf "${C_CYAN}├─────────────────────────────────────────────────────────────┤${C_RESET}\n"
boxline2 "${PI_MODEL}" "${UPTIME_STR}"
boxline "${C_DIM}${OS_INFO} · Kernel ${KERNEL_VER}${C_RESET}"
boxline "${STATS}"
boxline "${IP_ADDR} ${C_DIM}(${NET_IF})${C_RESET}"

# Alias quick-reference
printf "${C_CYAN}├─────────────────────────────────────────────────────────────┤${C_RESET}\n"
boxline "${C_BOLD}${C_WHITE}Quick Reference${C_RESET}         ${C_DIM}type${C_RESET} ${C_CYAN}aliases${C_RESET} ${C_DIM}for full list${C_RESET}"
boxline "${C_DIM}ll${C_RESET} list  ${C_DIM}..${C_RESET} up dir  ${C_DIM}update${C_RESET} apt  ${C_DIM}temp${C_RESET} heat"
boxline "${C_DIM}gs${C_RESET} git st ${C_DIM}gd${C_RESET} diff   ${C_DIM}myip${C_RESET} pub IP ${C_DIM}ports${C_RESET} listen"
boxline "${C_CYAN}whereami${C_RESET} ${C_DIM}context${C_RESET}  ${C_CYAN}today${C_RESET} ${C_DIM}activity${C_RESET}  ${C_CYAN}trash${C_RESET} ${C_DIM}safe rm${C_RESET}"

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
    sudo chmod +x /etc/profile.d/99-echolume-motd.sh
    
    # Remove the default Debian disclaimer (/etc/motd)
    if [[ -f /etc/motd ]] && [[ -s /etc/motd ]]; then
        log "Removing default /etc/motd disclaimer..."
        sudo truncate -s 0 /etc/motd
    fi
    
    # Disable default MOTD components that clutter the login
    if [[ -d /etc/update-motd.d ]]; then
        log "Disabling default MOTD scripts..."
        sudo chmod -x /etc/update-motd.d/* 2>/dev/null || true
    fi
    
    # Disable last login message (we have our own now)
    # v4 fix: Prefer sshd_config.d drop-in to avoid duplicating lines in sshd_config
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        log "Disabling SSH last login message (drop-in)..."
        printf "PrintLastLog no\n" | sudo tee /etc/ssh/sshd_config.d/99-echolume.conf >/dev/null
    elif [[ -f /etc/ssh/sshd_config ]]; then
        if ! grep -q "^PrintLastLog no" /etc/ssh/sshd_config; then
            log "Disabling SSH last login message..."
            # Replace existing setting if present; otherwise append once
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
    
    local zsh_path=$(which zsh)
    
    if [[ "$SHELL" == "$zsh_path" ]]; then
        success "zsh is already default shell"
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
# SAFE SYSTEM OPTIMIZATIONS (optional)
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
    if [[ $(cat /proc/sys/vm/swappiness) -gt 10 ]]; then
        log "Reducing swappiness to 10..."
        if echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf > /dev/null; then
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
    # v4 fix: Use drop-in config instead of editing main journald.conf
    local jdrop="/etc/systemd/journald.conf.d/99-echolume-limit.conf"
    if [[ -f "$jdrop" ]] && grep -qE '^\s*SystemMaxUse\s*=\s*50M\s*$' "$jdrop" 2>/dev/null; then
        success "Journald already limited (drop-in present)"
    else
        log "Limiting journald to 50MB (drop-in: $jdrop)..."
        if sudo mkdir -p /etc/systemd/journald.conf.d && \
           printf "[Journal]\nSystemMaxUse=50M\n" | sudo tee "$jdrop" >/dev/null; then
            sudo systemctl restart systemd-journald 2>/dev/null || true
            success "Journald limited"
        else
            error "Failed to configure journald"
            ((opt_failures++)) || true
        fi
    fi
    
    # Enable PCIe Gen 3 on Pi 5 (if PCIe detected and not already set)
    # Pi 5 defaults to Gen 2; Gen 3 doubles NVMe/Hailo throughput.
    # Safe: the Pi 5 PCIe controller supports Gen 3 natively.
    if [[ "$HAS_PCIE" == true ]] && [[ -n "${BOOT_CONFIG:-}" ]]; then
        if grep -qE '^\s*dtparam=pciex1_gen=3' "$BOOT_CONFIG" 2>/dev/null; then
            success "PCIe Gen 3 already enabled"
        else
            log "Enabling PCIe Gen 3 in $BOOT_CONFIG..."
            if echo -e "\n# PCIe Gen 3 — doubles NVMe/Hailo throughput (pi-bootstrap)\ndtparam=pciex1_gen=3" | sudo tee -a "$BOOT_CONFIG" >/dev/null; then
                success "PCIe Gen 3 enabled (takes effect after reboot)"
                warn "Reboot required for PCIe Gen 3"
            else
                error "Failed to enable PCIe Gen 3"
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
# FINAL SUMMARY WITH STATUS REPORT
#-------------------------------------------------------------------------------
print_summary() {
    # NOTE: We intentionally do NOT call detect_extended_hardware() here
    # to avoid hangs on slow devices. Use --info-only for full diagnostics.
    
    header "BOOTSTRAP COMPLETE"
    
    # Status report
    echo ""
    echo -e "${BOLD}INSTALLATION STATUS${NC}"
    echo "───────────────────────────────────────────────────────────"
    
    for step in "Hardware Detection" "Backup Configs" "OS Update" "Install Packages" \
                "Oh-My-Zsh" "Zsh Plugins" "Powerlevel10k" "Nerd Fonts" \
                "Generate .zshrc" "Generate .p10k.zsh" "Custom MOTD" "Change Shell" "Optimizations"; do
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
    
    # Next steps
    echo ""
    echo -e "${BOLD}NEXT STEPS${NC}"
    echo "───────────────────────────────────────────────────────────"
    echo "  1. Run: chsh -s $(which zsh)  (if not done automatically)"
    echo "  2. Log out and back in (or run: exec zsh)"
    echo "  3. Configure your terminal font to 'MesloLGS NF'"
    echo ""
    
    # File locations
    echo -e "${BOLD}FILES CREATED${NC}"
    echo "───────────────────────────────────────────────────────────"
    echo "  Config:   ~/.zshrc, ~/.p10k.zsh"
    echo "  MOTD:     /etc/profile.d/99-echolume-motd.sh"
    echo "  Backups:  $BACKUP_DIR"
    echo "  Log:      $LOG_FILE"
    echo ""
    
    # Quick system summary (using data already collected in detect_system)
    echo -e "${BOLD}SYSTEM${NC}"
    echo "───────────────────────────────────────────────────────────"
    echo "  Model:    $PI_MODEL"
    echo "  OS:       $OS_NAME"
    echo "  RAM:      ${RAM_MB} MB"
    echo "  Tier:     $TIER"
    echo ""
    
    echo -e "${DIM}For full hardware diagnostics: bash pi-bootstrap.sh --info-only${NC}"
    echo ""
}

#-------------------------------------------------------------------------------
# MAIN
#-------------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║     PI-BOOTSTRAP — ADHD-Friendly Shell Setup  (v18)       ║${NC}"
    echo -e "${BOLD}${CYAN}║     by Echolume · lab.hoens.fun                           ║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Initialize log
    echo "=== pi-bootstrap.sh v18 started $(date -Iseconds) ===" > "$LOG_FILE"
    
    # Info-only mode
    if [[ "$INFO_ONLY" == true ]]; then
        print_system_info
        return 0
    fi
    
    # Full install
    detect_system
    backup_configs
    update_os          || true
    install_packages   || true
    install_ohmyzsh    || true
    install_plugins    || true
    install_p10k       || true
    install_fonts      || true
    generate_zshrc
    generate_p10k_config
    install_motd       || true
    change_shell       || true
    apply_optimizations || true
    print_summary
    
    # Return failure count (don't use 'exit' - it logs out when piped)
    return $FAILURES
}

main "$@"
