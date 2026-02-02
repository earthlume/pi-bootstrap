#!/bin/bash
#===============================================================================
# pi-bootstrap.sh — Echolume's ADHD-Friendly Pi Shell Setup
# Version: 4
#
# WHAT:  Installs zsh + oh-my-zsh + powerlevel10k with sane defaults
# WHY:   Reduce cognitive load; make CLI accessible
# HOW:   Auto-detects hardware, picks FULL or LITE tier
#
# USAGE: curl -fsSL <url> | bash
#    or: bash pi-bootstrap.sh [--optimize] [--update-os] [--no-chsh] [--info-only]
#
# FLAGS:
#   --optimize   Apply safe system tweaks (swappiness, journald limits)
#   --update-os  Run apt upgrade (may include kernel/firmware packages)
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

# Status tracking
declare -A STATUS
FAILURES=0

#-------------------------------------------------------------------------------
# PARSE ARGUMENTS
#-------------------------------------------------------------------------------
DO_OPTIMIZE=false
DO_UPDATE_OS=false
DO_CHSH=true
DO_MOTD=true
INFO_ONLY=false

for arg in "$@"; do
    case $arg in
        --optimize)   DO_OPTIMIZE=true ;;
        --update-os)  DO_UPDATE_OS=true ;;
        --no-chsh)    DO_CHSH=false ;;
        --no-motd)    DO_MOTD=false ;;
        --info-only)  INFO_ONLY=true ;;
        --help|-h)
            echo "Usage: $0 [--optimize] [--update-os] [--no-chsh] [--no-motd] [--info-only]"
            echo ""
            echo "Flags:"
            echo "  --optimize   Apply safe system tweaks (swappiness, journald)"
            echo "  --update-os  Run apt upgrade (may include kernel/firmware packages)"
            echo "  --no-chsh    Don't change default shell to zsh"
            echo "  --no-motd    Don't install custom MOTD"
            echo "  --info-only  Just print system info and exit"
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
    
    track_status "Hardware Detection" "OK"
}

#-------------------------------------------------------------------------------
# EXTENDED HARDWARE DETECTION (for summary)
#-------------------------------------------------------------------------------
detect_extended_hardware() {
    # CPU info
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
    if command -v vcgencmd &>/dev/null; then
        THROTTLE_STATUS=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2 || echo "N/A")
    else
        THROTTLE_STATUS="vcgencmd not available"
    fi
    
    # Camera detection (v4 fix: use compgen instead of -d on device node)
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
    
    # I2C status
    if [[ -e /dev/i2c-1 ]]; then
        I2C_STATUS="enabled"
        if command -v i2cdetect &>/dev/null; then
            I2C_DEVICES=$(i2cdetect -y 1 2>/dev/null | grep -c "^[0-9]" || echo "0")
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
        USB_DEVICES=$(lsusb 2>/dev/null | wc -l || echo "0")
        USB_DEVICE_LIST=$(lsusb 2>/dev/null | grep -v "hub" | head -5 || echo "none")
    else
        USB_DEVICES="lsusb not available"
        USB_DEVICE_LIST=""
    fi
    
    # Network interfaces
    NET_INTERFACES=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v lo | tr '\n' ' ' || echo "unknown")
    
    # WiFi status
    if command -v iwconfig &>/dev/null; then
        WIFI_INTERFACE=$(iwconfig 2>/dev/null | grep -o "^wlan[0-9]" | head -1 || echo "none")
    else
        WIFI_INTERFACE=$(ip link show 2>/dev/null | grep -o "wlan[0-9]" | head -1 || echo "none")
    fi
    
    # Bluetooth
    if command -v bluetoothctl &>/dev/null; then
        BT_STATUS="available"
    elif [[ -d /sys/class/bluetooth ]]; then
        BT_STATUS="available (no bluetoothctl)"
    else
        BT_STATUS="not detected"
    fi
    
    # Boot config location (varies by OS version)
    if [[ -f /boot/firmware/config.txt ]]; then
        BOOT_CONFIG="/boot/firmware/config.txt"
    elif [[ -f /boot/config.txt ]]; then
        BOOT_CONFIG="/boot/config.txt"
    else
        BOOT_CONFIG="not found"
    fi
    
    # Check for common Pi overlays/settings
    if [[ -f "$BOOT_CONFIG" && "$BOOT_CONFIG" != "not found" ]]; then
        BOOT_OVERLAYS=$(grep "^dtoverlay=" "$BOOT_CONFIG" 2>/dev/null | cut -d= -f2 | tr '\n' ', ' || echo "none")
        [[ -z "$BOOT_OVERLAYS" ]] && BOOT_OVERLAYS="none configured"
    else
        BOOT_OVERLAYS="unknown"
    fi
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
# UPDATE OS (optional)
#-------------------------------------------------------------------------------
update_os() {
    header "UPDATING OS PACKAGES"
    
    if [[ "$DO_UPDATE_OS" == false ]]; then
        log "Skipping OS update (use --update-os flag to enable)"
        track_status "OS Update" "SKIP"
        return 0
    fi
    
    log "Running apt update..."
    if sudo apt-get update -qq; then
        success "Package lists updated"
    else
        error "apt update failed"
        track_status "OS Update" "FAIL"
        return 1
    fi
    
    log "Running apt upgrade (this may take a while)..."
    if sudo apt-get upgrade -y -qq; then
        success "OS packages upgraded"
        track_status "OS Update" "OK"
    else
        error "apt upgrade failed"
        track_status "OS Update" "FAIL"
        return 1
    fi
    
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
    
    log "Updating package lists..."
    if ! sudo apt-get update -qq; then
        error "apt update failed"
        track_status "Install Packages" "FAIL"
        return 1
    fi
    
    local packages=(
        zsh
        git
        curl
        wget
        fontconfig
        # Useful utilities
        htop
        ncdu
        tree
        jq
    )
    
    log "Installing: ${packages[*]}"
    if sudo apt-get install -y -qq "${packages[@]}"; then
        success "Packages installed"
        track_status "Install Packages" "OK"
    else
        error "Package installation failed"
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
    
    log "Installing oh-my-zsh (unattended)..."
    if RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"; then
        success "oh-my-zsh installed"
        track_status "Oh-My-Zsh" "OK"
    else
        error "oh-my-zsh installation failed"
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
        log "Installing zsh-autosuggestions..."
        if git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$autosug_dir"; then
            success "zsh-autosuggestions installed"
        else
            error "zsh-autosuggestions failed"
            ((plugin_failures++)) || true
        fi
    else
        warn "zsh-autosuggestions already present"
    fi
    
    # zsh-syntax-highlighting
    local synhi_dir="$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
    if [[ ! -d "$synhi_dir" ]]; then
        log "Installing zsh-syntax-highlighting..."
        if git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting "$synhi_dir"; then
            success "zsh-syntax-highlighting installed"
        else
            error "zsh-syntax-highlighting failed"
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
        log "Cloning powerlevel10k..."
        if git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$p10k_dir"; then
            success "powerlevel10k installed"
            track_status "Powerlevel10k" "OK"
        else
            error "powerlevel10k installation failed"
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
            log "Downloading: $decoded_font"
            if ! curl -fsSL -o "$font_dir/$decoded_font" "$base_url/$font"; then
                warn "Failed to download $decoded_font"
                ((font_failures++)) || true
            fi
        fi
    done
    
    # Rebuild font cache
    log "Rebuilding font cache..."
    fc-cache -f "$font_dir" 2>/dev/null || true
    
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

# Path to oh-my-zsh installation
export ZSH="$HOME/.oh-my-zsh"

# Theme: powerlevel10k
ZSH_THEME="powerlevel10k/powerlevel10k"

# Enable instant prompt (faster startup)
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
# Version: 4 (hardened)
#===============================================================================

# Colors
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_MAGENTA='\033[0;35m'
C_CYAN='\033[0;36m'
C_WHITE='\033[0;37m'

# Taglines — random on each login
TAGLINES=(
    "It compiles. Ship it."
    "Works on my machine ™"
    "Working as intended. Probably."
    "TODO: document this later"
    "¯\\_(ツ)_/¯ but it works"
    "Powered by caffeine and spite"
    "Trust the process. Or don't."
    "Chaotic good infrastructure"
    "sudo make me a sandwich"
    "DNS: it's always DNS"
    "There's no place like 127.0.0.1"
    "I'll refactor this tomorrow"
    "Not a bug, a surprise feature"
    "Held together with zip ties and optimism"
    "Future me problem"
    "git commit -m 'fixed stuff'"
    "chmod 777 and pray"
    "Over-engineered with love"
    "99% uptime, 1% existential dread"
    "Keep calm and blame the network"
)

# Pick random tagline
TAGLINE="${TAGLINES[$RANDOM % ${#TAGLINES[@]}]}"

# Safe padding helper: prevents negative widths -> printf errors (v4 fix)
pad() { local n="$1"; (( n < 0 )) && n=0; printf '%*s' "$n" ''; }

# Gather system info
HOSTNAME_UPPER=$(hostname | tr '[:lower:]' '[:upper:]')
UPTIME_STR=$(uptime -p 2>/dev/null | sed 's/up //' || echo "unknown")

# Temperature with color coding
if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
    TEMP_RAW=$(cat /sys/class/thermal/thermal_zone0/temp)
    TEMP_C=$((TEMP_RAW / 1000))
    if [[ $TEMP_C -lt 50 ]]; then
        TEMP_COLOR="${C_GREEN}"
    elif [[ $TEMP_C -lt 65 ]]; then
        TEMP_COLOR="${C_YELLOW}"
    else
        TEMP_COLOR="${C_RED}"
    fi
    TEMP_STR="${TEMP_COLOR}${TEMP_C}°C${C_RESET}"
else
    TEMP_STR="${C_DIM}N/A${C_RESET}"
fi

# CPU usage
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print int($2)}' 2>/dev/null || echo "?")

# RAM
RAM_TOTAL=$(free -m | awk '/^Mem:/ {print $2}')
RAM_USED=$(free -m | awk '/^Mem:/ {print $3}')
RAM_PCT=$((RAM_USED * 100 / RAM_TOTAL))
if [[ $RAM_PCT -lt 70 ]]; then
    RAM_COLOR="${C_GREEN}"
elif [[ $RAM_PCT -lt 85 ]]; then
    RAM_COLOR="${C_YELLOW}"
else
    RAM_COLOR="${C_RED}"
fi
RAM_STR="${RAM_COLOR}${RAM_USED}/${RAM_TOTAL}M (${RAM_PCT}%)${C_RESET}"

# Disk usage
DISK_INFO=$(df -h / | awk 'NR==2 {print $3"/"$2" ("$5")"}')
DISK_PCT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
if [[ $DISK_PCT -lt 70 ]]; then
    DISK_COLOR="${C_GREEN}"
elif [[ $DISK_PCT -lt 85 ]]; then
    DISK_COLOR="${C_YELLOW}"
else
    DISK_COLOR="${C_RED}"
fi
DISK_STR="${DISK_COLOR}${DISK_INFO}${C_RESET}"

# IP address
IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")

# Get interface name (v4 fix: use awk instead of grep -oP for portability)
if command -v ip &>/dev/null; then
    NET_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' || true)
    [[ -z "$NET_IF" ]] && NET_IF="eth0"
else
    NET_IF="eth0"
fi

# Model (short version)
if [[ -f /proc/device-tree/model ]]; then
    PI_MODEL=$(tr -d '\0' < /proc/device-tree/model | sed 's/Raspberry Pi /RPi /')
else
    PI_MODEL="Linux"
fi

# Print the MOTD (v4 fix: use pad() to prevent negative printf widths)
echo ""
echo -e "${C_CYAN}╭─────────────────────────────────────────────────────────────────╮${C_RESET}"
echo -e "${C_CYAN}│${C_RESET}   ${C_BOLD}${C_MAGENTA}█▀▀ ${HOSTNAME_UPPER}${C_RESET}$(pad $((43 - ${#HOSTNAME_UPPER})))${C_CYAN}│${C_RESET}"
echo -e "${C_CYAN}│${C_RESET}   ${C_DIM}lab.hoens.fun${C_RESET}       ${C_DIM}\"${TAGLINE}\"${C_RESET}$(pad $((30 - ${#TAGLINE})))${C_CYAN}│${C_RESET}"
echo -e "${C_CYAN}├─────────────────────────────────────────────────────────────────┤${C_RESET}"
echo -e "${C_CYAN}│${C_RESET}   ${C_DIM}Model${C_RESET}   ${PI_MODEL}$(pad $((52 - ${#PI_MODEL})))${C_CYAN}│${C_RESET}"
echo -e "${C_CYAN}│${C_RESET}   ${C_DIM}Uptime${C_RESET}  ${UPTIME_STR}$(pad $((52 - ${#UPTIME_STR})))${C_CYAN}│${C_RESET}"
echo -e "${C_CYAN}│${C_RESET}   ${C_DIM}Temp${C_RESET}    ${TEMP_STR}$(pad 43)${C_CYAN}│${C_RESET}"
echo -e "${C_CYAN}│${C_RESET}   ${C_DIM}CPU${C_RESET}     ${CPU_USAGE}%          ${C_DIM}RAM${C_RESET}  ${RAM_STR}$(pad 22)${C_CYAN}│${C_RESET}"
echo -e "${C_CYAN}│${C_RESET}   ${C_DIM}Disk${C_RESET}    ${DISK_STR}$(pad 37)${C_CYAN}│${C_RESET}"
echo -e "${C_CYAN}│${C_RESET}   ${C_DIM}IP${C_RESET}      ${IP_ADDR} ${C_DIM}(${NET_IF})${C_RESET}$(pad $((42 - ${#IP_ADDR} - ${#NET_IF})))${C_CYAN}│${C_RESET}"
echo -e "${C_CYAN}├─────────────────────────────────────────────────────────────────┤${C_RESET}"
echo -e "${C_CYAN}│${C_RESET}   ${C_DIM}Quick:${C_RESET} temp · update · ports · htop · duf                    ${C_CYAN}│${C_RESET}"
echo -e "${C_CYAN}╰─────────────────────────────────────────────────────────────────╯${C_RESET}"
echo ""
MOTD_SCRIPT

    # Make it executable
    sudo chmod +x /etc/profile.d/99-echolume-motd.sh
    
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
    detect_extended_hardware
    
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
    echo "  4. To customize prompt: p10k configure"
    
    # File locations
    echo ""
    echo -e "${BOLD}FILES CREATED${NC}"
    echo "───────────────────────────────────────────────────────────"
    echo "  Config:   ~/.zshrc, ~/.p10k.zsh"
    echo "  MOTD:     /etc/profile.d/99-echolume-motd.sh"
    echo "  Backups:  $BACKUP_DIR"
    echo "  Log:      $LOG_FILE"
    
    # System profile
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  SYSTEM PROFILE — PASTE TO COSMO FOR FURTHER SETUP${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    
    cat <<EOF

\`\`\`
BOOTSTRAP REPORT — $(date -Iseconds)
════════════════════════════════════════════════════════════

HARDWARE
  Model:        $PI_MODEL
  Architecture: $ARCH ($BITS-bit)
  CPU:          $CPU_CORES cores
  RAM:          ${RAM_MB} MB
  Temperature:  ${TEMP_C}°C
  Throttle:     $THROTTLE_STATUS
  Tier:         $TIER

STORAGE
  Total:        $ROOT_SIZE
  Available:    $ROOT_AVAIL
  Used:         $ROOT_USED_PCT

SOFTWARE
  OS:           $OS_NAME
  Kernel:       $KERNEL
  Hostname:     $(hostname)
  User:         $(whoami)
  Shell:        $SHELL → $(which zsh)

INTERFACES
  I2C:          $I2C_STATUS
  SPI:          $SPI_STATUS
  GPIO:         $GPIO_STATUS
  PCIe:         $HAS_PCIE
  WiFi:         $WIFI_INTERFACE
  Bluetooth:    $BT_STATUS
  Network:      $NET_INTERFACES

PERIPHERALS
  Camera:       $CAMERA_DEVICES
  Libcamera:    $LIBCAMERA
  USB devices:  $USB_DEVICES
  Overlays:     $BOOT_OVERLAYS

BOOTSTRAP STATUS
  Failures:     $FAILURES
  Tier:         $TIER
  Optimized:    $DO_OPTIMIZE
  OS Updated:   $DO_UPDATE_OS
  MOTD:         $DO_MOTD

DETECTED USB DEVICES
$USB_DEVICE_LIST

SUGGESTED NEXT STEPS FOR COSMO
  • Project type: [DESCRIBE YOUR PROJECT HERE]
  • Need camera? $( [[ "$CAMERA_DEVICES" == "none detected" ]] && echo "Yes - need to enable/configure" || echo "Detected: $CAMERA_DEVICES" )
  • Need I2C?    $( [[ "$I2C_STATUS" == "disabled" ]] && echo "Yes - run: sudo raspi-config" || echo "Already enabled" )
  • Need SPI?    $( [[ "$SPI_STATUS" == "disabled" ]] && echo "Yes - run: sudo raspi-config" || echo "Already enabled" )

════════════════════════════════════════════════════════════
\`\`\`

EOF
}

#-------------------------------------------------------------------------------
# MAIN
#-------------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║     PI-BOOTSTRAP — ADHD-Friendly Shell Setup  (v4)        ║${NC}"
    echo -e "${BOLD}${CYAN}║     by Echolume · lab.hoens.fun                           ║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Initialize log
    echo "=== pi-bootstrap.sh v4 started $(date -Iseconds) ===" > "$LOG_FILE"
    
    # Info-only mode
    if [[ "$INFO_ONLY" == true ]]; then
        print_system_info
        exit 0
    fi
    
    # Full install
    detect_system
    backup_configs
    update_os
    install_packages
    install_ohmyzsh
    install_plugins
    install_p10k
    install_fonts
    generate_zshrc
    generate_p10k_config
    install_motd
    change_shell
    apply_optimizations
    print_summary
    
    # Exit with failure count (0 = success)
    exit $FAILURES
}

main "$@"