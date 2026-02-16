#!/bin/bash
#===============================================================================
# deploy-web-stack.sh — Elminster Phase 2: Web Stack Deployment
# Version: 1
#
# WHAT:  Deploys Docker, Caddy, Dockge, and Open WebUI on Elminster
# WHY:   Give Mary a browser chat UI, give Abe a container manager
# HOW:   Run this script as root (or with sudo) on Elminster
#
# USAGE: sudo bash deploy-web-stack.sh
#
# PREREQUISITES:
#   - Elminster dropin.sh v3 complete (Ollama running, 15 models)
#   - Cloudflare API token with Zone:DNS:Edit on hoens.fun
#   - Internet connection (pulls Docker images)
#
# ARCHITECTURE:
#   Mary's phone → https://chat.lab.hoens.fun   → Caddy → Open WebUI → Ollama
#   Abe's browser → https://dockge.lab.hoens.fun → Caddy → Dockge
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# CONFIGURATION
#-------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_STACK_DIR="$SCRIPT_DIR/web-stack"
LOG_FILE="/var/log/deploy-web-stack.log"
STACKS_DIR="/opt/stacks"
DOCKGE_DATA_DIR="/opt/dockge/data"
CADDY_ENV_DIR="/etc/caddy"
CADDY_ENV_FILE="$CADDY_ENV_DIR/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# Track failures
FAILURES=0

#-------------------------------------------------------------------------------
# LOGGING HELPERS
#-------------------------------------------------------------------------------
log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}  ✓${NC} $*" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}  ⚠${NC} $*" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}  ✗${NC} $*" | tee -a "$LOG_FILE"
}

header() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}  $*${NC}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
}

#-------------------------------------------------------------------------------
# PRE-FLIGHT CHECKS
#-------------------------------------------------------------------------------
preflight() {
    header "Pre-Flight Checks"

    # Must be root
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
    success "Running as root"

    # Check architecture
    local arch
    arch="$(uname -m)"
    if [[ "$arch" != "aarch64" ]]; then
        warn "Expected aarch64, got $arch — proceeding anyway"
    else
        success "Architecture: $arch"
    fi

    # Check Ollama is running
    if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
        local model_count
        model_count=$(curl -sf http://localhost:11434/api/tags | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('models',[])))" 2>/dev/null || echo "?")
        success "Ollama running — $model_count models available"
    else
        warn "Ollama not responding on :11434 — Open WebUI won't connect until it's running"
    fi

    # Check disk space (need at least 10GB free for images)
    local free_gb
    free_gb=$(df / --output=avail -BG | tail -1 | tr -d ' G')
    if [[ "$free_gb" -lt 10 ]]; then
        error "Only ${free_gb}GB free. Need at least 10GB for Docker images."
        exit 1
    fi
    success "Disk space: ${free_gb}GB free"

    # Check RAM
    local total_ram_mb
    total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    success "RAM: ${total_ram_mb}MB total"

    # Check internet
    if curl -sf --max-time 5 https://download.docker.com >/dev/null 2>&1; then
        success "Internet connectivity OK"
    else
        error "Cannot reach download.docker.com — need internet for Docker install"
        exit 1
    fi

    # Check web-stack directory exists
    if [[ ! -d "$WEB_STACK_DIR" ]]; then
        error "web-stack directory not found at $WEB_STACK_DIR"
        error "Run this script from the pi-bootstrap repo root"
        exit 1
    fi
    success "Web stack configs found at $WEB_STACK_DIR"
}

#-------------------------------------------------------------------------------
# STEP 1: INSTALL DOCKER ENGINE
#-------------------------------------------------------------------------------
install_docker() {
    header "Step 1: Docker Engine"

    if command -v docker &>/dev/null; then
        local docker_ver
        docker_ver=$(docker --version | awk '{print $3}' | tr -d ',')
        success "Docker already installed: $docker_ver"

        # Make sure compose plugin is available
        if docker compose version &>/dev/null; then
            success "Docker Compose plugin available"
        else
            warn "Docker Compose plugin missing — installing"
            apt-get install -y docker-compose-plugin >> "$LOG_FILE" 2>&1
        fi
        return 0
    fi

    log "Installing Docker CE from official repository..."

    # Remove any conflicting packages
    log "Removing conflicting packages (if any)..."
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        apt-get remove -y "$pkg" >> "$LOG_FILE" 2>&1 || true
    done

    # Install prerequisites
    apt-get update >> "$LOG_FILE" 2>&1
    apt-get install -y ca-certificates curl gnupg >> "$LOG_FILE" 2>&1

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Determine which Debian release to use for the repo
    # Debian 13 (trixie) may not have Docker packages yet — fall back to bookworm
    local version_codename
    version_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    local repo_codename="$version_codename"

    # Test if Docker repo exists for this codename
    if ! curl -sf "https://download.docker.com/linux/debian/dists/${version_codename}/Release" >/dev/null 2>&1; then
        warn "Docker repo not available for '$version_codename' — using 'bookworm' instead"
        repo_codename="bookworm"
    fi

    # Add Docker repo
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $repo_codename stable" \
        > /etc/apt/sources.list.d/docker.list

    # Install Docker Engine
    apt-get update >> "$LOG_FILE" 2>&1
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1

    # Verify
    if docker --version &>/dev/null; then
        success "Docker installed: $(docker --version | awk '{print $3}' | tr -d ',')"
    else
        error "Docker installation failed"
        ((FAILURES++))
        return 1
    fi

    # Enable and start
    systemctl enable docker >> "$LOG_FILE" 2>&1
    systemctl start docker >> "$LOG_FILE" 2>&1
    success "Docker service enabled and started"

    # Add the invoking user to docker group (if run via sudo)
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER"
        success "Added $SUDO_USER to docker group (re-login to take effect)"
    fi

    success "Docker Engine ready"
}

#-------------------------------------------------------------------------------
# STEP 2: SET UP CLOUDFLARE TOKEN
#-------------------------------------------------------------------------------
setup_cloudflare_token() {
    header "Step 2: Cloudflare API Token"

    mkdir -p "$CADDY_ENV_DIR"

    if [[ -f "$CADDY_ENV_FILE" ]]; then
        # Validate existing token file has content
        if grep -q "CLOUDFLARE_API_TOKEN=" "$CADDY_ENV_FILE" 2>/dev/null; then
            success "Cloudflare token already configured at $CADDY_ENV_FILE"
            return 0
        fi
    fi

    echo ""
    echo -e "${BOLD}Caddy needs a Cloudflare API token for DNS-01 TLS challenges.${NC}"
    echo ""
    echo "The token needs:"
    echo "  - Permission: Zone > DNS > Edit"
    echo "  - Zone Resource: Include > hoens.fun"
    echo ""
    echo "If you already have one from OPNsense ACME, it may work here too."
    echo "Create one at: https://dash.cloudflare.com/profile/api-tokens"
    echo ""
    read -rp "Paste your Cloudflare API token: " cf_token

    if [[ -z "$cf_token" ]]; then
        error "No token provided. Caddy cannot issue TLS certificates without it."
        error "Re-run this script when you have the token, or create $CADDY_ENV_FILE manually:"
        error "  echo 'CLOUDFLARE_API_TOKEN=your_token_here' > $CADDY_ENV_FILE"
        ((FAILURES++))
        return 1
    fi

    echo "CLOUDFLARE_API_TOKEN=$cf_token" > "$CADDY_ENV_FILE"
    chmod 600 "$CADDY_ENV_FILE"
    chown root:root "$CADDY_ENV_FILE"
    success "Token saved to $CADDY_ENV_FILE (mode 600, root-only)"
}

#-------------------------------------------------------------------------------
# STEP 3: DEPLOY CADDY
#-------------------------------------------------------------------------------
deploy_caddy() {
    header "Step 3: Caddy (Reverse Proxy + TLS)"

    local caddy_stack="$STACKS_DIR/caddy"
    mkdir -p "$caddy_stack"

    # Copy compose and config files
    cp "$WEB_STACK_DIR/caddy/compose.yaml" "$caddy_stack/compose.yaml"
    cp "$WEB_STACK_DIR/caddy/Caddyfile" "$caddy_stack/Caddyfile"
    cp "$WEB_STACK_DIR/caddy/Dockerfile" "$caddy_stack/Dockerfile"
    success "Caddy configs copied to $caddy_stack"

    log "Building custom Caddy image with Cloudflare DNS plugin (this takes a few minutes on ARM64)..."
    if docker compose -f "$caddy_stack/compose.yaml" build >> "$LOG_FILE" 2>&1; then
        success "Caddy image built"
    else
        error "Caddy image build failed — check $LOG_FILE"
        ((FAILURES++))
        return 1
    fi

    log "Starting Caddy..."
    if docker compose -f "$caddy_stack/compose.yaml" up -d >> "$LOG_FILE" 2>&1; then
        success "Caddy container started"
    else
        error "Caddy failed to start — check: docker logs caddy"
        ((FAILURES++))
        return 1
    fi

    # Brief wait for Caddy to initialize
    sleep 3

    # Check if Caddy is running
    if docker ps --format '{{.Names}}' | grep -q '^caddy$'; then
        success "Caddy is running"
    else
        error "Caddy container not running — check: docker logs caddy"
        ((FAILURES++))
        return 1
    fi

    success "Caddy deployed with Cloudflare DNS-01 TLS"
}

#-------------------------------------------------------------------------------
# STEP 4: DEPLOY DOCKGE
#-------------------------------------------------------------------------------
deploy_dockge() {
    header "Step 4: Dockge (Container Manager)"

    mkdir -p "$STACKS_DIR/dockge" "$DOCKGE_DATA_DIR"

    # Copy compose file
    cp "$WEB_STACK_DIR/dockge/compose.yaml" "$STACKS_DIR/dockge/compose.yaml"
    success "Dockge config copied to $STACKS_DIR/dockge"

    log "Pulling Dockge image..."
    if docker compose -f "$STACKS_DIR/dockge/compose.yaml" pull >> "$LOG_FILE" 2>&1; then
        success "Dockge image pulled"
    else
        error "Failed to pull Dockge image"
        ((FAILURES++))
        return 1
    fi

    log "Starting Dockge..."
    if docker compose -f "$STACKS_DIR/dockge/compose.yaml" up -d >> "$LOG_FILE" 2>&1; then
        success "Dockge container started"
    else
        error "Dockge failed to start — check: docker logs dockge"
        ((FAILURES++))
        return 1
    fi

    sleep 3

    if docker ps --format '{{.Names}}' | grep -q '^dockge$'; then
        success "Dockge is running on port 5001"
    else
        error "Dockge container not running — check: docker logs dockge"
        ((FAILURES++))
        return 1
    fi

    success "Dockge deployed — set up admin account at https://dockge.lab.hoens.fun"
}

#-------------------------------------------------------------------------------
# STEP 5: DEPLOY OPEN WEBUI
#-------------------------------------------------------------------------------
deploy_open_webui() {
    header "Step 5: Open WebUI (Chat Interface)"

    mkdir -p "$STACKS_DIR/open-webui"

    # Copy compose file
    cp "$WEB_STACK_DIR/open-webui/compose.yaml" "$STACKS_DIR/open-webui/compose.yaml"
    success "Open WebUI config copied to $STACKS_DIR/open-webui"

    log "Pulling Open WebUI image (this is a large image — be patient)..."
    if docker compose -f "$STACKS_DIR/open-webui/compose.yaml" pull >> "$LOG_FILE" 2>&1; then
        success "Open WebUI image pulled"
    else
        error "Failed to pull Open WebUI image"
        ((FAILURES++))
        return 1
    fi

    log "Starting Open WebUI..."
    if docker compose -f "$STACKS_DIR/open-webui/compose.yaml" up -d >> "$LOG_FILE" 2>&1; then
        success "Open WebUI container started"
    else
        error "Open WebUI failed to start — check: docker logs open-webui"
        ((FAILURES++))
        return 1
    fi

    # Open WebUI takes a moment to initialize on first run
    log "Waiting for Open WebUI to initialize..."
    local retries=0
    while [[ $retries -lt 30 ]]; do
        if curl -sf http://localhost:8080 >/dev/null 2>&1; then
            break
        fi
        sleep 2
        ((retries++))
    done

    if docker ps --format '{{.Names}}' | grep -q '^open-webui$'; then
        success "Open WebUI is running on port 8080"
    else
        error "Open WebUI container not running — check: docker logs open-webui"
        ((FAILURES++))
        return 1
    fi

    success "Open WebUI deployed — first user to register becomes admin"
}

#-------------------------------------------------------------------------------
# STEP 6: VERIFY ALL SERVICES
#-------------------------------------------------------------------------------
verify_services() {
    header "Step 6: Verification"

    echo ""
    log "Checking all containers..."
    echo ""

    local all_ok=true

    # Check each container
    for svc in caddy dockge open-webui; do
        if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
            local status
            status=$(docker inspect -f '{{.State.Status}}' "$svc" 2>/dev/null)
            success "$svc — $status"
        else
            error "$svc — NOT RUNNING"
            all_ok=false
        fi
    done

    echo ""

    # Check ports
    log "Checking ports..."
    for port_desc in "443:Caddy HTTPS" "80:Caddy HTTP" "8080:Open WebUI" "5001:Dockge"; do
        local port="${port_desc%%:*}"
        local desc="${port_desc#*:}"
        if ss -tlnp | grep -q ":${port} "; then
            success "Port $port ($desc) — listening"
        else
            warn "Port $port ($desc) — not listening"
        fi
    done

    echo ""

    # Check Ollama connectivity from Docker
    log "Checking Ollama connectivity..."
    if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
        success "Ollama API accessible on localhost:11434"
    else
        warn "Ollama API not responding — Open WebUI needs this to list models"
    fi

    echo ""

    # Docker resource usage
    log "Container resource usage:"
    docker stats --no-stream --format "  {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | tee -a "$LOG_FILE" || true

    echo ""

    if $all_ok; then
        success "All services running"
    else
        warn "Some services failed — check above for details"
    fi
}

#-------------------------------------------------------------------------------
# SUMMARY
#-------------------------------------------------------------------------------
print_summary() {
    header "Deployment Complete"

    echo ""
    echo -e "${BOLD}Services:${NC}"
    echo -e "  Chat UI:           ${CYAN}https://chat.lab.hoens.fun${NC}"
    echo -e "  Container Manager: ${CYAN}https://dockge.lab.hoens.fun${NC}"
    echo ""
    echo -e "${BOLD}Next Steps:${NC}"
    echo -e "  ${YELLOW}1.${NC} Add DNS overrides in OPNsense (Unbound):"
    echo -e "     ${DIM}chat.lab.hoens.fun   → 10.0.0.70${NC}"
    echo -e "     ${DIM}dockge.lab.hoens.fun → 10.0.0.70${NC}"
    echo ""
    echo -e "  ${YELLOW}2.${NC} Open ${CYAN}https://dockge.lab.hoens.fun${NC}"
    echo -e "     Create Abe's admin account"
    echo ""
    echo -e "  ${YELLOW}3.${NC} Open ${CYAN}https://chat.lab.hoens.fun${NC}"
    echo -e "     First user to register becomes admin (Abe)"
    echo -e "     Then create Mary's account"
    echo ""
    echo -e "  ${YELLOW}4.${NC} Lock registration:"
    echo -e "     Edit ${DIM}/opt/stacks/open-webui/compose.yaml${NC}"
    echo -e "     Change ${DIM}ENABLE_SIGNUP=true${NC} → ${DIM}ENABLE_SIGNUP=false${NC}"
    echo -e "     Restart: ${DIM}docker compose -f /opt/stacks/open-webui/compose.yaml up -d${NC}"
    echo ""
    echo -e "  ${YELLOW}5.${NC} Test from Mary's phone:"
    echo -e "     Open ${CYAN}https://chat.lab.hoens.fun${NC} — pick a model — chat"
    echo ""

    if [[ $FAILURES -gt 0 ]]; then
        echo -e "${YELLOW}  ⚠ $FAILURES step(s) had issues — review the output above${NC}"
    else
        echo -e "${GREEN}  All steps completed successfully.${NC}"
    fi

    echo ""
    echo -e "${DIM}Log: $LOG_FILE${NC}"
    echo -e "${DIM}Stacks: $STACKS_DIR${NC}"
    echo ""
    echo -e "${DIM}\"A web of magic, woven through the aether, that even the least${NC}"
    echo -e "${DIM} arcane among us can touch with a finger.\" — Elminster${NC}"
    echo ""
}

#-------------------------------------------------------------------------------
# MAIN
#-------------------------------------------------------------------------------
main() {
    echo "" > "$LOG_FILE"  # Fresh log

    header "Elminster Phase 2: Web Stack Deployment"
    echo ""
    echo -e "  ${DIM}This script deploys:${NC}"
    echo -e "  ${DIM}  1. Docker Engine${NC}"
    echo -e "  ${DIM}  2. Caddy (reverse proxy + TLS)${NC}"
    echo -e "  ${DIM}  3. Dockge (container manager)${NC}"
    echo -e "  ${DIM}  4. Open WebUI (chat interface)${NC}"
    echo ""

    preflight
    install_docker
    setup_cloudflare_token
    deploy_caddy
    deploy_dockge
    deploy_open_webui
    verify_services
    print_summary
}

main "$@"
