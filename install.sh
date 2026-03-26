#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
BLUE='\033[0;34m'
NC='\033[0m'

IMAGE="imilya/mtproxy:latest"
CONTAINER_NAME="mtproxy"

println() { echo -e "$*"; }
ok()      { echo -e "${GREEN}✓${NC} $*"; }
info()    { echo -e "${CYAN}→${NC} $*"; }
die()     { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

# ── Secret generation ─────────────────────────────────────────────────────────
generate_plain_secret() {
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

generate_fake_tls_secret() {
    local domain="$1"
    local domain_hex
    domain_hex=$(echo -n "$domain" | od -An -tx1 | tr -d ' \n')
    local max_len=30
    local domain_len=${#domain_hex}
    if (( domain_len >= max_len )); then
        echo "ee${domain_hex:0:$max_len}"
    else
        local needed=$(( max_len - domain_len ))
        local random_hex
        random_hex=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-"$needed")
        echo "ee${domain_hex}${random_hex}"
    fi
}

println ""
println "${BOLD}MTProxy installer${NC}"
println "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
println ""

# ── Dependency check ──────────────────────────────────────────────────────────
command -v docker &>/dev/null || die "Docker is required but not installed."
ok "Docker found"
println ""

# ── PID limit ─────────────────────────────────────────────────────────────────
println "${BOLD}PID limit${NC}"
println "MTProxy crashes if its PID exceeds 65535."
println "Setting kernel.pid_max=65535 prevents this."
read -rp "Apply PID limit? [Y/n]: " PID_LIMIT_INPUT
case "${PID_LIMIT_INPUT,,}" in
    n|no)
        ok "PID limit skipped"
        ;;
    *)
        echo "kernel.pid_max = 65535" | tee /etc/sysctl.d/99-mtproxy.conf > /dev/null
        sysctl --system > /dev/null
        ok "PID limit applied"
        ;;
esac

# ── Port ──────────────────────────────────────────────────────────────────────
println "${BOLD}Port${NC}"
println "Which port should MTProxy listen on?"
println "Common choices: 443 (best for censored regions), 8443, 8744"
read -rp "Port [443]: " PORT_INPUT
PORT="${PORT_INPUT:-443}"
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    die "Invalid port: $PORT"
fi
ok "Port: $PORT"
println ""

# ── Fake TLS ──────────────────────────────────────────────────────────────────
println "${BOLD}Fake TLS${NC}"
println "Disguises traffic as HTTPS to bypass deep packet inspection."
println "Recommended if MTProxy is blocked in your region."
read -rp "Enable Fake TLS? [Y/n]: " FAKE_TLS_INPUT
case "${FAKE_TLS_INPUT,,}" in
    n|no)
        FAKE_TLS=0
        FAKE_TLS_DOMAIN="cloudflare.com"
        SECRET=$(generate_plain_secret)
        ok "Fake TLS: disabled"
        ;;
    *)
        FAKE_TLS=1
        println ""
        println "${BOLD}Fake TLS domain${NC}"
        println "Used as SNI in TLS handshake. Pick a popular unblocked domain."
        read -rp "Domain [cloudflare.com]: " DOMAIN_INPUT
        FAKE_TLS_DOMAIN="${DOMAIN_INPUT:-cloudflare.com}"
        SECRET=$(generate_fake_tls_secret "$FAKE_TLS_DOMAIN")
        ok "Fake TLS: enabled (domain: $FAKE_TLS_DOMAIN)"
        ;;
        
esac
println ""

# ── Detect external IP ────────────────────────────────────────────────────────
info "Detecting external IP..."
EXTERNAL_IP=""
for svc in ifconfig.me api.ipify.org icanhazip.com; do
    EXTERNAL_IP=$(curl -sf --max-time 5 "https://$svc" || true)
    [[ "$EXTERNAL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    EXTERNAL_IP=""
done
if [[ -z "$EXTERNAL_IP" ]]; then
    die "Could not detect external IP (server public IP). Set EXTERNAL_IP manually and re-run."
fi
ok "External IP: $EXTERNAL_IP"
println ""

# ── Stop existing container if any ───────────────────────────────────────────
if docker inspect "$CONTAINER_NAME" &>/dev/null 2>&1; then
    info "Stopping existing container '$CONTAINER_NAME'..."
    docker stop "$CONTAINER_NAME" &>/dev/null || true
    docker rm   "$CONTAINER_NAME" &>/dev/null || true
    ok "Old container removed"
    println ""
fi

# ── Pull & run ────────────────────────────────────────────────────────────────
STATS_PORT=8888

info "Pulling $IMAGE..."
docker pull "$IMAGE"
println ""

info "Starting container..."
docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    -p "${PORT}:${PORT}/tcp" \
    -p "${PORT}:${PORT}/udp" \
    -p "127.0.0.1:${STATS_PORT}:${STATS_PORT}/tcp" \
    -e PORT="${PORT}" \
    -e STATS_PORT="${STATS_PORT}" \
    -e SECRET="${SECRET}" \
    -e EXTERNAL_IP="${EXTERNAL_IP}" \
    -e FAKE_TLS="${FAKE_TLS}" \
    -e FAKE_TLS_DOMAIN="${FAKE_TLS_DOMAIN}" \
    -v mtproxy-data:/data \
    "${IMAGE}"

# ── Build connection link ─────────────────────────────────────────────────────
if [[ "$FAKE_TLS" == "1" ]]; then
    # Fake TLS secret already has "ee" prefix
    LINK="tg://proxy?server=${EXTERNAL_IP}&port=${PORT}&secret=${SECRET}"
else
    # Plain secret gets "dd" prefix in the link
    LINK="tg://proxy?server=${EXTERNAL_IP}&port=${PORT}&secret=dd${SECRET}"
fi

println ""
println "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "${BOLD}MTProxy is running!${NC}"
println ""
println "  ${BOLD}Connection link:${NC}"
println "  ${GREEN}${LINK}${NC}"
println ""
println "  Server:  ${EXTERNAL_IP}"
println "  Port:    ${PORT}"
println "  Secret:  ${SECRET}"
[[ "$FAKE_TLS" == "1" ]] && println "  Domain:  ${FAKE_TLS_DOMAIN}"
println ""
println "  Logs:    ${CYAN}sudo docker logs -f ${CONTAINER_NAME}${NC}"
println "  Stop:    ${CYAN}sudo docker stop ${CONTAINER_NAME}${NC}"
println "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
println ""