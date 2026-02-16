#!/bin/bash
#===============================================================================
# elminster-web-stack.sh — Project Elminster Phase 2: Web Stack
# Version: 1
#
# WHAT:  Deploys Docker + Caddy + Open WebUI + Dockge on Elminster
# WHY:   Give Mary a browser chat UI, give Abe a container dashboard
# HOW:   Docker Compose stacks with Caddy TLS via Cloudflare DNS-01
#
# USAGE: sudo bash elminster-web-stack.sh
#    or: sudo bash elminster-web-stack.sh [--skip-docker] [--skip-caddy]
#                                         [--skip-dockge] [--skip-webui]
#                                         [--teardown] [--status]
#
# FLAGS:
#   --skip-docker  Skip Docker Engine installation (already installed)
#   --skip-caddy   Skip Caddy deployment
#   --skip-dockge  Skip Dockge deployment
#   --skip-webui   Skip Open WebUI deployment
#   --teardown     Remove everything (interactive, confirms each step)
#   --status       Show status of all services and exit
#
# PREREQS:
#   - Elminster dropin.sh v3 complete (Ollama + 15 models)
#   - Cloudflare API token with Zone:DNS:Edit on hoens.fun
#   - Run as root (sudo)
#
# ARCHITECTURE:
#   Mary's phone → https://chat.lab.hoens.fun   → Caddy → Open WebUI → Ollama
#   Abe's browser → https://dockge.lab.hoens.fun → Caddy → Dockge
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# CONFIGURATION
#-------------------------------------------------------------------------------
LOG_FILE="/var/log/elminster-web-stack.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACKS_SRC="$SCRIPT_DIR/stacks"

# Paths on the target system
CADDY_DIR="/etc/caddy"
CADDY_DATA="/var/lib/caddy"
DOCKGE_DIR="/opt/dockge"
STACKS_DIR="/opt/stacks"
WEBUI_DIR="/opt/stacks/open-webui"

# Network
ELMINSTER_IP="10.0.0.70"
OLLAMA_PORT="11434"
WEBUI_PORT="8080"
DOCKGE_PORT="5001"

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
SKIP_DOCKER=false
SKIP_CADDY=false
SKIP_DOCKGE=false
SKIP_WEBUI=false
DO_TEARDOWN=false
DO_STATUS=false

for arg in "$@"; do
    case $arg in
        --skip-docker)  SKIP_DOCKER=true ;;
        --skip-caddy)   SKIP_CADDY=true ;;
        --skip-dockge)  SKIP_DOCKGE=true ;;
        --skip-webui)   SKIP_WEBUI=true ;;
        --teardown)     DO_TEARDOWN=true ;;
        --status)       DO_STATUS=true ;;
        --help|-h)
            echo "Usage: sudo $0 [--skip-docker] [--skip-caddy] [--skip-dockge] [--skip-webui] [--teardown] [--status]"
            echo ""
            echo "Flags:"
            echo "  --skip-docker  Skip Docker Engine installation"
            echo "  --skip-caddy   Skip Caddy deployment"
            echo "  --skip-dockge  Skip Dockge deployment"
            echo "  --skip-webui   Skip Open WebUI deployment"
            echo "  --teardown     Remove all web stack components (interactive)"
            echo "  --status       Show status of all services"
            exit 0
            ;;
        *) echo -e "${YELLOW}⚠ Unknown flag: $arg${NC}" >&2 ;;
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
spin() {
    local label="$1"
    shift
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
# PREFLIGHT CHECKS
#-------------------------------------------------------------------------------
preflight() {
    header "PREFLIGHT CHECKS"

    # Must be root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (sudo)"
        exit 1
    fi
    success "Running as root"

    # Check architecture
    local arch
    arch=$(uname -m)
    if [[ "$arch" != "aarch64" ]]; then
        warn "Expected aarch64, got $arch — proceeding anyway"
    else
        success "Architecture: $arch"
    fi

    # Check OS
    if [[ -f /etc/os-release ]]; then
        local os_name
        os_name=$(. /etc/os-release && echo "${PRETTY_NAME:-Unknown}")
        log "OS: $os_name"
    fi

    # Check Ollama is running
    if curl -sf "http://localhost:${OLLAMA_PORT}/api/tags" > /dev/null 2>&1; then
        local model_count
        model_count=$(curl -sf "http://localhost:${OLLAMA_PORT}/api/tags" | grep -c '"name"' || true)
        success "Ollama running — $model_count models available"
    else
        warn "Ollama not responding on port $OLLAMA_PORT"
        warn "Open WebUI will start but won't be able to chat until Ollama is running"
    fi

    # Check source stacks directory exists
    if [[ ! -d "$STACKS_SRC" ]]; then
        error "Stacks directory not found at $STACKS_SRC"
        error "Make sure you're running from the pi-bootstrap repo directory"
        exit 1
    fi
    success "Stacks source directory found"

    # Check available disk space (need at least 5GB)
    local avail_gb
    avail_gb=$(df -BG / | tail -1 | awk '{print $4}' | tr -d 'G')
    if [[ $avail_gb -lt 5 ]]; then
        error "Only ${avail_gb}GB free — need at least 5GB"
        exit 1
    fi
    success "Disk space: ${avail_gb}GB available"

    track_status "Preflight" "OK"
}

#-------------------------------------------------------------------------------
# DOCKER ENGINE INSTALLATION
#-------------------------------------------------------------------------------
install_docker() {
    header "INSTALLING DOCKER ENGINE"

    if [[ "$SKIP_DOCKER" == true ]]; then
        log "Skipping Docker installation (--skip-docker)"
        track_status "Docker" "SKIP"
        return 0
    fi

    # Check if Docker is already installed
    if command -v docker &> /dev/null; then
        local docker_ver
        docker_ver=$(docker --version 2>/dev/null || echo "unknown")
        success "Docker already installed: $docker_ver"
        track_status "Docker" "OK"
        return 0
    fi

    log "Installing Docker CE from official Docker repo..."

    # Install prerequisites
    spin "Installing prerequisites" \
        apt-get update
    spin "Installing ca-certificates and curl" \
        apt-get install -y ca-certificates curl gnupg

    # Add Docker's official GPG key
    log "Adding Docker GPG key..."
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi
    success "Docker GPG key added"

    # Add Docker repository
    # Note: Debian 13 (trixie) may not have a Docker repo yet — fall back to bookworm
    local version_codename
    version_codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}")

    # Check if Docker has a repo for this version, fall back to bookworm
    local repo_codename="$version_codename"
    if ! curl -sfL "https://download.docker.com/linux/debian/dists/${version_codename}/Release" > /dev/null 2>&1; then
        warn "Docker repo not found for $version_codename — using bookworm"
        repo_codename="bookworm"
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $repo_codename stable" \
        > /etc/apt/sources.list.d/docker.list
    success "Docker repository added (using $repo_codename)"

    # Install Docker packages
    spin "Updating package lists" \
        apt-get update
    spin "Installing Docker Engine" \
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Enable and start Docker
    systemctl enable docker
    systemctl start docker

    # Verify
    if docker run --rm hello-world >> "$LOG_FILE" 2>&1; then
        success "Docker verified working"
        docker rmi hello-world >> "$LOG_FILE" 2>&1 || true
    else
        error "Docker hello-world test failed"
        track_status "Docker" "FAIL"
        return 1
    fi

    local docker_ver
    docker_ver=$(docker --version 2>/dev/null || echo "unknown")
    success "Docker installed: $docker_ver"
    track_status "Docker" "OK"
}

#-------------------------------------------------------------------------------
# CLOUDFLARE TOKEN SETUP
#-------------------------------------------------------------------------------
setup_cloudflare_token() {
    header "CLOUDFLARE API TOKEN"

    # Check if token already exists
    if [[ -f "$CADDY_DIR/.env" ]]; then
        if grep -q "CLOUDFLARE_API_TOKEN=" "$CADDY_DIR/.env" 2>/dev/null; then
            success "Cloudflare API token already configured"
            return 0
        fi
    fi

    # Check environment variable
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        log "Using CLOUDFLARE_API_TOKEN from environment"
    else
        # Interactive prompt
        echo ""
        echo -e "${BOLD}Caddy needs a Cloudflare API token for TLS certificates.${NC}"
        echo -e "Token name: ${CYAN}Elminster Caddy ACME${NC}"
        echo -e "Required permissions: ${CYAN}Zone: DNS: Edit${NC} on ${CYAN}hoens.fun${NC}"
        echo ""
        read -rsp "Paste Cloudflare API token (input hidden): " CLOUDFLARE_API_TOKEN
        echo ""

        if [[ -z "$CLOUDFLARE_API_TOKEN" ]]; then
            error "No token provided — Caddy cannot obtain TLS certificates"
            track_status "Cloudflare Token" "FAIL"
            return 1
        fi
    fi

    # Write token to env file with restricted permissions
    mkdir -p "$CADDY_DIR"
    echo "CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}" > "$CADDY_DIR/.env"
    chmod 600 "$CADDY_DIR/.env"
    chown root:root "$CADDY_DIR/.env"
    success "Token saved to $CADDY_DIR/.env (mode 600, root only)"
    track_status "Cloudflare Token" "OK"
}

#-------------------------------------------------------------------------------
# CADDY DEPLOYMENT
#-------------------------------------------------------------------------------
deploy_caddy() {
    header "DEPLOYING CADDY (REVERSE PROXY + TLS)"

    if [[ "$SKIP_CADDY" == true ]]; then
        log "Skipping Caddy deployment (--skip-caddy)"
        track_status "Caddy" "SKIP"
        return 0
    fi

    # Set up Cloudflare token first
    setup_cloudflare_token || {
        track_status "Caddy" "FAIL"
        return 1
    }

    # Create data directories
    mkdir -p "$CADDY_DIR"
    mkdir -p "$CADDY_DATA"

    # Copy Caddyfile
    if [[ -f "$STACKS_SRC/caddy/Caddyfile" ]]; then
        cp "$STACKS_SRC/caddy/Caddyfile" "$CADDY_DIR/Caddyfile"
        success "Caddyfile installed to $CADDY_DIR/"
    else
        error "Caddyfile not found at $STACKS_SRC/caddy/Caddyfile"
        track_status "Caddy" "FAIL"
        return 1
    fi

    # Copy Dockerfile for custom Caddy build
    if [[ -f "$STACKS_SRC/caddy/Dockerfile" ]]; then
        cp "$STACKS_SRC/caddy/Dockerfile" "$CADDY_DIR/Dockerfile"
        success "Caddy Dockerfile installed"
    else
        error "Caddy Dockerfile not found"
        track_status "Caddy" "FAIL"
        return 1
    fi

    # Copy docker-compose.yml
    cp "$STACKS_SRC/caddy/docker-compose.yml" "$CADDY_DIR/docker-compose.yml"

    # Build custom Caddy image with Cloudflare DNS plugin
    log "Building custom Caddy image with Cloudflare DNS plugin..."
    spin "Building caddy-cloudflare image" \
        docker compose -f "$CADDY_DIR/docker-compose.yml" --env-file "$CADDY_DIR/.env" build

    # Start Caddy
    log "Starting Caddy..."
    spin "Starting Caddy container" \
        docker compose -f "$CADDY_DIR/docker-compose.yml" --env-file "$CADDY_DIR/.env" up -d

    # Wait for Caddy to start
    sleep 3

    # Verify Caddy is running
    if docker ps --format '{{.Names}}' | grep -q "caddy"; then
        success "Caddy container running"
    else
        error "Caddy container not running"
        log "Container logs:"
        docker logs caddy >> "$LOG_FILE" 2>&1 || true
        track_status "Caddy" "FAIL"
        return 1
    fi

    success "Caddy deployed with Cloudflare DNS-01 TLS"
    track_status "Caddy" "OK"
}

#-------------------------------------------------------------------------------
# DOCKGE DEPLOYMENT
#-------------------------------------------------------------------------------
deploy_dockge() {
    header "DEPLOYING DOCKGE (CONTAINER MANAGER)"

    if [[ "$SKIP_DOCKGE" == true ]]; then
        log "Skipping Dockge deployment (--skip-dockge)"
        track_status "Dockge" "SKIP"
        return 0
    fi

    # Create directories
    mkdir -p "$DOCKGE_DIR/data"
    mkdir -p "$STACKS_DIR"

    # Copy docker-compose.yml
    cp "$STACKS_SRC/dockge/docker-compose.yml" "$DOCKGE_DIR/docker-compose.yml"
    success "Dockge compose file installed to $DOCKGE_DIR/"

    # Pull and start
    log "Pulling Dockge image..."
    spin "Pulling louislam/dockge:1" \
        docker compose -f "$DOCKGE_DIR/docker-compose.yml" pull

    log "Starting Dockge..."
    spin "Starting Dockge container" \
        docker compose -f "$DOCKGE_DIR/docker-compose.yml" up -d

    # Wait for Dockge to start
    sleep 3

    # Verify
    if docker ps --format '{{.Names}}' | grep -q "dockge"; then
        success "Dockge container running"
    else
        error "Dockge container not running"
        docker logs dockge >> "$LOG_FILE" 2>&1 || true
        track_status "Dockge" "FAIL"
        return 1
    fi

    # Check port
    if curl -sf "http://localhost:${DOCKGE_PORT}" > /dev/null 2>&1; then
        success "Dockge responding on port $DOCKGE_PORT"
    else
        warn "Dockge not yet responding on port $DOCKGE_PORT (may still be starting)"
    fi

    success "Dockge deployed"
    track_status "Dockge" "OK"
}

#-------------------------------------------------------------------------------
# OPEN WEBUI DEPLOYMENT
#-------------------------------------------------------------------------------
deploy_open_webui() {
    header "DEPLOYING OPEN WEBUI (CHAT INTERFACE)"

    if [[ "$SKIP_WEBUI" == true ]]; then
        log "Skipping Open WebUI deployment (--skip-webui)"
        track_status "Open WebUI" "SKIP"
        return 0
    fi

    # Create directory in stacks (so Dockge can manage it)
    mkdir -p "$WEBUI_DIR"

    # Copy docker-compose.yml
    cp "$STACKS_SRC/open-webui/docker-compose.yml" "$WEBUI_DIR/docker-compose.yml"
    success "Open WebUI compose file installed to $WEBUI_DIR/"

    # Pull and start
    log "Pulling Open WebUI image (this may take a while on first run)..."
    spin "Pulling ghcr.io/open-webui/open-webui:main" \
        docker compose -f "$WEBUI_DIR/docker-compose.yml" pull

    log "Starting Open WebUI..."
    spin "Starting Open WebUI container" \
        docker compose -f "$WEBUI_DIR/docker-compose.yml" up -d

    # Wait for Open WebUI to initialize (it takes longer on first start)
    log "Waiting for Open WebUI to initialize..."
    local attempts=0
    local max_attempts=30
    while [[ $attempts -lt $max_attempts ]]; do
        if curl -sf "http://localhost:${WEBUI_PORT}" > /dev/null 2>&1; then
            break
        fi
        ((attempts++)) || true
        sleep 2
    done

    # Verify
    if docker ps --format '{{.Names}}' | grep -q "open-webui"; then
        success "Open WebUI container running"
    else
        error "Open WebUI container not running"
        docker logs open-webui >> "$LOG_FILE" 2>&1 || true
        track_status "Open WebUI" "FAIL"
        return 1
    fi

    if curl -sf "http://localhost:${WEBUI_PORT}" > /dev/null 2>&1; then
        success "Open WebUI responding on port $WEBUI_PORT"
    else
        warn "Open WebUI not yet responding (may still be initializing)"
    fi

    success "Open WebUI deployed"
    track_status "Open WebUI" "OK"
}

#-------------------------------------------------------------------------------
# HEALTH CHECK
#-------------------------------------------------------------------------------
health_check() {
    header "HEALTH CHECK"

    local checks_passed=0
    local checks_total=0

    # Docker
    ((checks_total++)) || true
    if command -v docker &> /dev/null && docker info > /dev/null 2>&1; then
        success "Docker Engine: running"
        ((checks_passed++)) || true
    else
        error "Docker Engine: not running"
    fi

    # Caddy
    if [[ "$SKIP_CADDY" != true ]]; then
        ((checks_total++)) || true
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "caddy"; then
            success "Caddy: running"
            ((checks_passed++)) || true
        else
            error "Caddy: not running"
        fi
    fi

    # Dockge
    if [[ "$SKIP_DOCKGE" != true ]]; then
        ((checks_total++)) || true
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "dockge"; then
            success "Dockge: running"
            ((checks_passed++)) || true

            ((checks_total++)) || true
            if curl -sf "http://localhost:${DOCKGE_PORT}" > /dev/null 2>&1; then
                success "Dockge port $DOCKGE_PORT: responding"
                ((checks_passed++)) || true
            else
                warn "Dockge port $DOCKGE_PORT: not responding yet"
            fi
        else
            error "Dockge: not running"
        fi
    fi

    # Open WebUI
    if [[ "$SKIP_WEBUI" != true ]]; then
        ((checks_total++)) || true
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "open-webui"; then
            success "Open WebUI: running"
            ((checks_passed++)) || true

            ((checks_total++)) || true
            if curl -sf "http://localhost:${WEBUI_PORT}" > /dev/null 2>&1; then
                success "Open WebUI port $WEBUI_PORT: responding"
                ((checks_passed++)) || true
            else
                warn "Open WebUI port $WEBUI_PORT: not responding yet"
            fi
        else
            error "Open WebUI: not running"
        fi
    fi

    # Ollama connectivity
    ((checks_total++)) || true
    if curl -sf "http://localhost:${OLLAMA_PORT}/api/tags" > /dev/null 2>&1; then
        success "Ollama API: responding"
        ((checks_passed++)) || true
    else
        warn "Ollama API: not responding"
    fi

    echo ""
    log "Health check: $checks_passed/$checks_total checks passed"

    if [[ $checks_passed -eq $checks_total ]]; then
        track_status "Health Check" "OK"
    else
        track_status "Health Check" "FAIL"
    fi
}

#-------------------------------------------------------------------------------
# STATUS DISPLAY
#-------------------------------------------------------------------------------
show_status() {
    header "WEB STACK STATUS"

    echo -e "${BOLD}Service            Status         Port      URL${NC}"
    echo "─────────────────────────────────────────────────────────────────"

    # Docker
    if command -v docker &> /dev/null && docker info > /dev/null 2>&1; then
        echo -e "Docker Engine      ${GREEN}running${NC}        —         —"
    else
        echo -e "Docker Engine      ${RED}stopped${NC}        —         —"
    fi

    # Caddy
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "caddy"; then
        echo -e "Caddy              ${GREEN}running${NC}        80/443    https://*.lab.hoens.fun"
    else
        echo -e "Caddy              ${RED}stopped${NC}        80/443    —"
    fi

    # Dockge
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "dockge"; then
        echo -e "Dockge             ${GREEN}running${NC}        $DOCKGE_PORT      https://dockge.lab.hoens.fun"
    else
        echo -e "Dockge             ${RED}stopped${NC}        $DOCKGE_PORT      —"
    fi

    # Open WebUI
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "open-webui"; then
        echo -e "Open WebUI         ${GREEN}running${NC}        $WEBUI_PORT      https://chat.lab.hoens.fun"
    else
        echo -e "Open WebUI         ${RED}stopped${NC}        $WEBUI_PORT      —"
    fi

    # Ollama
    if curl -sf "http://localhost:${OLLAMA_PORT}/api/tags" > /dev/null 2>&1; then
        local model_count
        model_count=$(curl -sf "http://localhost:${OLLAMA_PORT}/api/tags" | grep -c '"name"' || true)
        echo -e "Ollama             ${GREEN}running${NC}        $OLLAMA_PORT    http://localhost:$OLLAMA_PORT"
        echo -e "  └─ Models: $model_count"
    else
        echo -e "Ollama             ${RED}stopped${NC}        $OLLAMA_PORT    —"
    fi

    echo ""

    # Container details
    if command -v docker &> /dev/null; then
        echo -e "${BOLD}Container Details:${NC}"
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | head -20 || true
    fi
}

#-------------------------------------------------------------------------------
# TEARDOWN
#-------------------------------------------------------------------------------
teardown() {
    header "TEARDOWN — REMOVING WEB STACK"

    warn "This will remove web stack components from Elminster."
    echo ""
    echo "Components:"
    echo "  1. Open WebUI  (WARNING: deletes chat history)"
    echo "  2. Dockge"
    echo "  3. Caddy       (removes TLS config + token)"
    echo "  4. Docker       (removes engine + all containers/images)"
    echo ""
    read -rp "Continue with teardown? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log "Teardown cancelled"
        return 0
    fi

    # Open WebUI
    echo ""
    read -rp "Remove Open WebUI? (y/n): " rm_webui
    if [[ "$rm_webui" == "y" ]]; then
        log "Removing Open WebUI..."
        if [[ -f "$WEBUI_DIR/docker-compose.yml" ]]; then
            docker compose -f "$WEBUI_DIR/docker-compose.yml" down -v 2>/dev/null || true
        else
            docker stop open-webui 2>/dev/null || true
            docker rm open-webui 2>/dev/null || true
        fi
        rm -rf "$WEBUI_DIR"
        success "Open WebUI removed"
    fi

    # Dockge
    read -rp "Remove Dockge? (y/n): " rm_dockge
    if [[ "$rm_dockge" == "y" ]]; then
        log "Removing Dockge..."
        if [[ -f "$DOCKGE_DIR/docker-compose.yml" ]]; then
            docker compose -f "$DOCKGE_DIR/docker-compose.yml" down -v 2>/dev/null || true
        else
            docker stop dockge 2>/dev/null || true
            docker rm dockge 2>/dev/null || true
        fi
        rm -rf "$DOCKGE_DIR"
        rm -rf "$STACKS_DIR"
        success "Dockge removed"
    fi

    # Caddy
    read -rp "Remove Caddy? (y/n): " rm_caddy
    if [[ "$rm_caddy" == "y" ]]; then
        log "Removing Caddy..."
        if [[ -f "$CADDY_DIR/docker-compose.yml" ]]; then
            docker compose -f "$CADDY_DIR/docker-compose.yml" down -v 2>/dev/null || true
        else
            docker stop caddy 2>/dev/null || true
            docker rm caddy 2>/dev/null || true
        fi
        rm -rf "$CADDY_DIR"
        rm -rf "$CADDY_DATA"
        success "Caddy removed (config + token deleted)"
    fi

    # Docker
    read -rp "Remove Docker Engine entirely? (y/n): " rm_docker
    if [[ "$rm_docker" == "y" ]]; then
        log "Removing Docker Engine..."
        # Stop all containers first
        docker stop $(docker ps -q) 2>/dev/null || true
        # Remove packages
        apt-get purge -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
        rm -rf /var/lib/docker /var/lib/containerd
        rm -f /etc/apt/sources.list.d/docker.list
        rm -f /etc/apt/keyrings/docker.gpg
        success "Docker Engine removed"
    fi

    echo ""
    success "Teardown complete"
    echo ""
    warn "Manual cleanup still needed:"
    echo "  • Delete DNS overrides in OPNsense (chat + dockge .lab.hoens.fun)"
    echo "  • Apply changes in OPNsense Unbound"
}

#-------------------------------------------------------------------------------
# SUMMARY
#-------------------------------------------------------------------------------
print_summary() {
    header "DEPLOYMENT SUMMARY"

    # Status table
    echo -e "${BOLD}Step                    Result${NC}"
    echo "──────────────────────────────────"
    for step in "Preflight" "Docker" "Cloudflare Token" "Caddy" "Dockge" "Open WebUI" "Health Check"; do
        local result="${STATUS[$step]:-—}"
        local color="$NC"
        case "$result" in
            OK)   color="$GREEN" ;;
            FAIL) color="$RED" ;;
            SKIP) color="$YELLOW" ;;
        esac
        printf "%-24s%b%s%b\n" "$step" "$color" "$result" "$NC"
    done

    echo ""

    if [[ $FAILURES -gt 0 ]]; then
        warn "$FAILURES step(s) failed — check $LOG_FILE for details"
    else
        success "All steps completed successfully"
    fi

    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  NEXT STEPS${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  1. Add OPNsense DNS overrides (Unbound → Host Overrides):"
    echo ""
    echo "     Host: chat     Domain: lab.hoens.fun  IP: $ELMINSTER_IP"
    echo "     Host: dockge   Domain: lab.hoens.fun  IP: $ELMINSTER_IP"
    echo ""
    echo "  2. Apply Unbound changes in OPNsense"
    echo ""
    echo "  3. Open https://chat.lab.hoens.fun"
    echo "     → First user to register becomes admin (Abe)"
    echo "     → Create Mary's account"
    echo "     → Set ENABLE_SIGNUP=false in $WEBUI_DIR/docker-compose.yml"
    echo "     → Restart: docker compose -f $WEBUI_DIR/docker-compose.yml up -d"
    echo ""
    echo "  4. Open https://dockge.lab.hoens.fun"
    echo "     → Create Abe's admin account"
    echo ""
    echo "  5. Test from Mary's phone:"
    echo "     → https://chat.lab.hoens.fun → log in → pick a model → chat"
    echo ""
    echo -e "  ${DIM}Log file: $LOG_FILE${NC}"
    echo -e "  ${DIM}Status:   sudo bash $0 --status${NC}"
    echo ""
    echo -e "  ${DIM}\"A web of magic, woven through the aether, that even the least${NC}"
    echo -e "  ${DIM} arcane among us can touch with a finger.\" — Elminster${NC}"
    echo ""
}

#-------------------------------------------------------------------------------
# MAIN
#-------------------------------------------------------------------------------
main() {
    echo "" | tee -a "$LOG_FILE"
    log "elminster-web-stack.sh started at $(date)"
    log "Args: $*"

    # Handle special modes
    if [[ "$DO_STATUS" == true ]]; then
        show_status
        return 0
    fi

    if [[ "$DO_TEARDOWN" == true ]]; then
        teardown
        return 0
    fi

    # Normal deployment
    preflight
    install_docker          || true
    deploy_caddy            || true
    deploy_dockge           || true
    deploy_open_webui       || true
    health_check            || true
    print_summary

    log "elminster-web-stack.sh finished at $(date)"

    # Exit with failure count
    exit "$FAILURES"
}

main "$@"
