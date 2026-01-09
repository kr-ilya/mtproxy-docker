#!/bin/bash
set -Eeuo pipefail


DATA_DIR="/data"
PROXY_SECRET="$DATA_DIR/proxy-secret"
PROXY_CONFIG="$DATA_DIR/proxy-multi.conf"
SECRET_FILE="$DATA_DIR/secret"
CONFIG_UPDATE_INTERVAL="${CONFIG_UPDATE_INTERVAL:-604800}"  # default 7 days
MTPROXY_PID=""

log() {
    echo "[mtproxy] $(date '+%Y-%m-%d %H:%M:%S') $*"
}


generate_secret() {
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

validate_secret() {
    [[ "$1" =~ ^[a-fA-F0-9]{32}$ ]]
}

get_external_ip() {
    for svc in ifconfig.me api.ipify.org icanhazip.com; do
        ip=$(curl -sf --max-time 5 "https://$svc" || true)
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return
    done
}

cleanup() {
    log "Shutting down..."
    kill -TERM "$MTPROXY_PID" 2>/dev/null || true
    wait "$MTPROXY_PID" 2>/dev/null || true
    exit 0
}

trap cleanup TERM INT

# Secret setup
if [[ -z "${SECRET:-}" ]]; then
    if [[ -f "$SECRET_FILE" ]]; then
        SECRET=$(<"$SECRET_FILE")
    else
        SECRET=$(generate_secret)
        echo "$SECRET" > "$SECRET_FILE"
        chmod 600 "$SECRET_FILE"
        log "Generated new secret"
    fi
fi

validate_secret "$SECRET" || {
    log "Invalid SECRET format"
    exit 1
}

# Networking setup
INTERNAL_IP=$(hostname -i | awk '{print $1}')
EXTERNAL_IP=${EXTERNAL_IP:-$(get_external_ip)}
EXTERNAL_IP=${EXTERNAL_IP:-$INTERNAL_IP}

WORKERS=${WORKERS:-$(nproc)}
(( WORKERS > 16 )) && WORKERS=16

# Ports setup:  PORTS takes priority, fallback to PORT, default to 443
PORTS="${PORTS:-${PORT:-443}}"

# Display connection info
print_connection_link() {
    echo ""
    echo "═══════════════════════════════════════════"
    echo "  MTProxy connection info:"
    echo "  Ports:    $PORTS"
    echo "  Workers:  $WORKERS"
    echo "  Secret:   $SECRET"
    [[ -n "${TAG:-}" ]] && echo "  Tag:      $TAG"
    echo ""
    echo "  Connection links:"
    for port in ${PORTS//,/ }; do
        echo "  tg://proxy?server=${EXTERNAL_IP}&port=${port}&secret=dd${SECRET}"
    done
    echo "═══════════════════════════════════════════"
    echo ""
}

start_mtproxy() {
    ARGS="-u root -p ${STATS_PORT:-8888}"
    
    # Add all ports with -H flag
    for port in ${PORTS//,/ }; do
        ARGS="$ARGS -H $port"
    done
    
    ARGS="$ARGS --aes-pwd $PROXY_SECRET $PROXY_CONFIG"
    ARGS="$ARGS --nat-info ${INTERNAL_IP}:${EXTERNAL_IP}"
    ARGS="$ARGS -M $WORKERS -S $SECRET --http-stats"
    [[ -n "${TAG:-}" ]] && ARGS="$ARGS -P $TAG"

    /usr/local/bin/mtproto-proxy $ARGS &
    MTPROXY_PID=$!
    log "MTProxy started with PID $MTPROXY_PID"
}

log "Starting MTProxy"
log "Ports: $PORTS"
log "Workers: $WORKERS"

print_connection_link

log "Starting MTProxy main control loop (update interval: $CONFIG_UPDATE_INTERVAL sec)"

while true; do
    # 1. Update config
    if [[ "$CONFIG_UPDATE_INTERVAL" -gt 0 ]]; then
        log "Updating Telegram config..."
        if /usr/local/bin/update-config.sh; then
            log "Config updated"
        else
            log "Config update failed (keeping old config)"
        fi
    fi

    # 2. Stop old MTProxy if running
    if [[ -n "${MTPROXY_PID:-}" ]]; then
        log "Stopping MTProxy (PID $MTPROXY_PID)..."
        kill -TERM "$MTPROXY_PID" 2>/dev/null || true

        # на всякий случай — воркеры
        pkill -P "$MTPROXY_PID" 2>/dev/null || true

        wait "$MTPROXY_PID" 2>/dev/null || true
        MTPROXY_PID=""
    fi

    # 3. Start MTProxy
    start_mtproxy

    # 4. Sleep until next update
    sleep "$CONFIG_UPDATE_INTERVAL"
done