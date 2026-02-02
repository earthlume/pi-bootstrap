#!/bin/bash
#===============================================================================
# pi-bootstrap.sh — Abe's ADHD-Friendly Pi Shell Setup
# 
# WHAT:  Installs zsh + oh-my-zsh + powerlevel10k with sane defaults
# WHY:   Reduce cognitive load; make CLI accessible
# HOW:   Auto-detects hardware, picks FULL or LITE tier
#
# USAGE: curl -fsSL <url> | bash
#    or: bash pi-bootstrap.sh [--optimize] [--no-chsh] [--info-only]
#
# FLAGS:
#   --optimize   Apply safe system tweaks (swappiness, journald limits)
#   --no-chsh    Don't change default shell to zsh
#   --info-only  Just print system info and exit (for pasting back to Claude)
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

#-------------------------------------------------------------------------------
# PARSE ARGUMENTS
#-------------------------------------------------------------------------------
DO_OPTIMIZE=false
DO_CHSH=true
INFO_ONLY=false

for arg in "$@"; do
    case $arg in
        --optimize)   DO_OPTIMIZE=true ;;
        --no-chsh)    DO_CHSH=false ;;
        --info-only)  INFO_ONLY=true ;;
        --help|-h)
            echo "Usage: $0 [--optimize] [--no-chsh] [--info-only]"
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
    else
        OS_NAME="Unknown"
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
    log "Root filesystem: $ROOT_SIZE total, $ROOT_AVAIL available"
    
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
}

#-------------------------------------------------------------------------------
# PRINT SYSTEM INFO (for pasting back)
#-------------------------------------------------------------------------------
print_system_info() {
    detect_system
    
    header "SYSTEM INFO — PASTE THIS BACK TO CLAUDE"
    
    cat <<EOF

\`\`\`
PI_MODEL:    $PI_MODEL
ARCH:        $ARCH ($BITS-bit)
RAM_MB:      $RAM_MB
OS:          $OS_NAME
KERNEL:      $KERNEL
TIER:        $TIER
HAS_PCIE:    $HAS_PCIE
ROOT_SIZE:   $ROOT_SIZE
ROOT_AVAIL:  $ROOT_AVAIL
HOSTNAME:    $(hostname)
USER:        $(whoami)
DATE:        $(date -Iseconds)
\`\`\`

EOF
    
    # Additional info if Pi 5
    if echo "$PI_MODEL" | grep -qi "pi 5"; then
        echo "--- Pi 5 Specific ---"
        if [[ -f /boot/firmware/config.txt ]]; then
            echo "PCIe config in /boot/firmware/config.txt:"
            grep -i pcie /boot/firmware/config.txt 2>/dev/null || echo "(no pcie settings found)"
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
    
    for file in "${files_to_backup[@]}"; do
        if [[ -f "$file" ]]; then
            cp "$file" "$BACKUP_DIR/"
            success "Backed up: $file"
        fi
    done
    
    log "Backups stored in: $BACKUP_DIR"
}

#-------------------------------------------------------------------------------
# INSTALL PACKAGES
#-------------------------------------------------------------------------------
install_packages() {
    header "INSTALLING PACKAGES"
    
    log "Updating package lists..."
    sudo apt-get update -qq
    
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
    sudo apt-get install -y -qq "${packages[@]}"
    success "Packages installed"
}

#-------------------------------------------------------------------------------
# INSTALL OH-MY-ZSH
#-------------------------------------------------------------------------------
install_ohmyzsh() {
    header "INSTALLING OH-MY-ZSH"
    
    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        warn "oh-my-zsh already installed, skipping"
        return 0
    fi
    
    log "Installing oh-my-zsh (unattended)..."
    RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    success "oh-my-zsh installed"
}

#-------------------------------------------------------------------------------
# INSTALL ZSH PLUGINS
#-------------------------------------------------------------------------------
install_plugins() {
    header "INSTALLING ZSH PLUGINS"
    
    # Ensure custom dir exists
    mkdir -p "$ZSH_CUSTOM/plugins"
    
    # zsh-autosuggestions
    local autosug_dir="$ZSH_CUSTOM/plugins/zsh-autosuggestions"
    if [[ ! -d "$autosug_dir" ]]; then
        log "Installing zsh-autosuggestions..."
        git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$autosug_dir"
        success "zsh-autosuggestions installed"
    else
        warn "zsh-autosuggestions already present"
    fi
    
    # zsh-syntax-highlighting
    local synhi_dir="$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
    if [[ ! -d "$synhi_dir" ]]; then
        log "Installing zsh-syntax-highlighting..."
        git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting "$synhi_dir"
        success "zsh-syntax-highlighting installed"
    else
        warn "zsh-syntax-highlighting already present"
    fi
    
    # z (directory jumper) - comes with oh-my-zsh, just needs enabling
    success "z plugin ready (bundled with oh-my-zsh)"
}

#-------------------------------------------------------------------------------
# INSTALL POWERLEVEL10K
#-------------------------------------------------------------------------------
install_p10k() {
    header "INSTALLING POWERLEVEL10K"
    
    local p10k_dir="$ZSH_CUSTOM/themes/powerlevel10k"
    
    if [[ ! -d "$p10k_dir" ]]; then
        log "Cloning powerlevel10k..."
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$p10k_dir"
        success "powerlevel10k installed"
    else
        warn "powerlevel10k already present"
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
    
    for font in "${fonts[@]}"; do
        local decoded_font=$(echo "$font" | sed 's/%20/ /g')
        if [[ ! -f "$font_dir/$decoded_font" ]]; then
            log "Downloading: $decoded_font"
            curl -fsSL -o "$font_dir/$decoded_font" "$base_url/$font" || warn "Failed to download $decoded_font"
        fi
    done
    
    # Rebuild font cache
    log "Rebuilding font cache..."
    fc-cache -f "$font_dir" 2>/dev/null || true
    success "Fonts installed (configure your terminal to use 'MesloLGS NF')"
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
# CHANGE DEFAULT SHELL
#-------------------------------------------------------------------------------
change_shell() {
    header "SETTING ZSH AS DEFAULT SHELL"
    
    if [[ "$DO_CHSH" == false ]]; then
        warn "Skipping shell change (--no-chsh flag set)"
        return 0
    fi
    
    local zsh_path=$(which zsh)
    
    if [[ "$SHELL" == "$zsh_path" ]]; then
        success "zsh is already default shell"
        return 0
    fi
    
    # Detect if running non-interactively (piped)
    if [[ ! -t 0 ]]; then
        warn "Non-interactive mode detected (piped install)"
        warn "Cannot change shell automatically — run this manually:"
        echo ""
        echo -e "    ${BOLD}chsh -s $zsh_path${NC}"
        echo ""
        warn "Then log out and back in."
        return 0
    fi
    
    log "Changing default shell to zsh..."
    if chsh -s "$zsh_path"; then
        success "Default shell changed to zsh"
        warn "Log out and back in (or reboot) for change to take effect"
    else
        error "chsh failed — run manually: chsh -s $zsh_path"
    fi
}

#-------------------------------------------------------------------------------
# SAFE SYSTEM OPTIMIZATIONS (optional)
#-------------------------------------------------------------------------------
apply_optimizations() {
    header "APPLYING SYSTEM OPTIMIZATIONS"
    
    if [[ "$DO_OPTIMIZE" == false ]]; then
        log "Skipping optimizations (use --optimize flag to enable)"
        return 0
    fi
    
    # Reduce swappiness (less aggressive swap on SD cards)
    if [[ $(cat /proc/sys/vm/swappiness) -gt 10 ]]; then
        log "Reducing swappiness to 10..."
        echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf > /dev/null
        sudo sysctl -p /etc/sysctl.d/99-swappiness.conf
        success "Swappiness reduced"
    else
        success "Swappiness already optimal"
    fi
    
    # Limit journal size (saves SD card writes)
    if [[ -f /etc/systemd/journald.conf ]]; then
        if ! grep -q "^SystemMaxUse=50M" /etc/systemd/journald.conf; then
            log "Limiting journald to 50MB..."
            sudo sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=50M/' /etc/systemd/journald.conf
            sudo sed -i 's/^SystemMaxUse=.*/SystemMaxUse=50M/' /etc/systemd/journald.conf
            sudo systemctl restart systemd-journald
            success "Journald limited"
        else
            success "Journald already limited"
        fi
    fi
    
    success "Optimizations applied"
}

#-------------------------------------------------------------------------------
# FINAL SUMMARY
#-------------------------------------------------------------------------------
print_summary() {
    header "SETUP COMPLETE"
    
    cat <<EOF

${GREEN}✓ Installation Summary${NC}
  • zsh + oh-my-zsh installed
  • powerlevel10k theme configured (tier: $TIER)
  • Plugins: zsh-autosuggestions, zsh-syntax-highlighting, z
  • ADHD-friendly aliases and settings applied
  • Backups saved to: $BACKUP_DIR
  • Log saved to: $LOG_FILE

${YELLOW}⚠ NEXT STEPS${NC}
  1. ${BOLD}Log out and back in${NC} (or run: exec zsh)
  2. ${BOLD}Configure your terminal font${NC} to 'MesloLGS NF'
     (For SSH: configure your local terminal, not the Pi)
  3. On first zsh launch, p10k wizard may run — you can skip it
     (config is already generated)

${CYAN}═══════════════════════════════════════════════════════════${NC}
${CYAN}  SYSTEM INFO — PASTE BACK TO CLAUDE IF NEEDED${NC}
${CYAN}═══════════════════════════════════════════════════════════${NC}

\`\`\`
PI_MODEL:    $PI_MODEL
ARCH:        $ARCH ($BITS-bit)
RAM_MB:      $RAM_MB
OS:          $OS_NAME
KERNEL:      $KERNEL
TIER:        $TIER
HAS_PCIE:    $HAS_PCIE
HOSTNAME:    $(hostname)
USER:        $(whoami)
DATE:        $(date -Iseconds)
BOOTSTRAP:   pi-bootstrap.sh completed
\`\`\`

EOF
}

#-------------------------------------------------------------------------------
# MAIN
#-------------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║     PI-BOOTSTRAP — ADHD-Friendly Shell Setup              ║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Initialize log
    echo "=== pi-bootstrap.sh started $(date -Iseconds) ===" > "$LOG_FILE"
    
    # Info-only mode
    if [[ "$INFO_ONLY" == true ]]; then
        print_system_info
        exit 0
    fi
    
    # Full install
    detect_system
    backup_configs
    install_packages
    install_ohmyzsh
    install_plugins
    install_p10k
    install_fonts
    generate_zshrc
    generate_p10k_config
    change_shell
    apply_optimizations
    print_summary
}

main "$@"
