#!/bin/bash
set -Eeuo pipefail


DATA_DIR="/data"
PROXY_SECRET="$DATA_DIR/proxy-secret"
PROXY_CONFIG="$DATA_DIR/proxy-multi.conf"
SECRET_FILE="$DATA_DIR/secret"
CONFIG_UPDATE_INTERVAL="${CONFIG_UPDATE_INTERVAL:-604800}"  # default 7 days
MTPROXY_PID=""
SOCAT_PID=""
STATS_PORT_PUBLIC="${STATS_PORT:-8888}"

if (( STATS_PORT_PUBLIC <= 1024 )); then
    STATS_PORT_INTERNAL=$((STATS_PORT_PUBLIC + 1))
else
    STATS_PORT_INTERNAL=$((STATS_PORT_PUBLIC - 1))
fi

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
    [[ -n "${MTPROXY_PID:-}" ]] && kill -TERM "$MTPROXY_PID" 2>/dev/null || true
    [[ -n "${SOCAT_PID:-}" ]] && kill -TERM "$SOCAT_PID" 2>/dev/null || true
    wait "$MTPROXY_PID" 2>/dev/null || true
    wait "$SOCAT_PID" 2>/dev/null || true
    exit 0
}

trap cleanup TERM INT

# Secrets setup:  SECRETS takes priority, fallback to SECRET
if [[ -n "${SECRETS:-}" ]]; then
    # Multiple secrets provided
    SECRETS_LIST="${SECRETS//,/ }"
elif [[ -n "${SECRET:-}" ]]; then
    # Single secret provided
    SECRETS_LIST="$SECRET"
elif [[ -f "$SECRET_FILE" ]]; then
    # Read from file (one secret per line or comma-separated)
    SECRETS_LIST=$(tr ',\n' ' ' < "$SECRET_FILE" | xargs)
else
    # Generate new secret
    NEW_SECRET=$(generate_secret)
    echo "$NEW_SECRET" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    SECRETS_LIST="$NEW_SECRET"
    log "Generated new secret"
fi

# Validate all secrets
for secret in $SECRETS_LIST; do
    validate_secret "$secret" || {
        log "Invalid secret format:  $secret"
        exit 1
    }
done

# Count secrets
SECRET_COUNT=$(echo $SECRETS_LIST | wc -w)
log "Loaded $SECRET_COUNT secret(s)"

# Networking setup
INTERNAL_IP=$(hostname -i | awk '{print $1}')
EXTERNAL_IP=${EXTERNAL_IP:-$(get_external_ip)}
EXTERNAL_IP=${EXTERNAL_IP:-$INTERNAL_IP}

WORKERS=${WORKERS:-$(nproc)}
(( WORKERS > 16 )) && WORKERS=16

# Ports setup: PORTS takes priority, fallback to PORT, default to 443
PORTS="${PORTS:-${PORT:-443}}"
PORTS_LIST="${PORTS//,/ }"

# Display connection info
print_connection_links() {
    echo ""
    echo "═══════════════════════════════════════════"
    echo "  MTProxy connection info:"
    echo "  Ports:    $PORTS"
    echo "  Workers:  $WORKERS"
    echo "  Secrets:  $SECRET_COUNT"
    [[ -n "${TAG:-}" ]] && echo "  Tag:      $TAG"
    echo ""
    echo "  Connection links:"
    
    local secret_num=1
    for secret in $SECRETS_LIST; do
        for port in $PORTS_LIST; do
            echo "  [Secret $secret_num, Port $port]:"
            echo "  tg://proxy?server=${EXTERNAL_IP}&port=${port}&secret=dd${secret}"
        done
        ((secret_num++))
    done
    echo "═══════════════════════════════════════════"
    echo ""
}

start_stats_proxy() {
    # MTProxy listens on localhost only, socat exposes it to all interfaces
    if [[ "${STATS_EXPOSE:-true}" == "true" ]]; then
        socat TCP-LISTEN:${STATS_PORT_PUBLIC},bind=0.0.0.0,fork,reuseaddr TCP:127.0.0.1:${STATS_PORT_INTERNAL} &
        SOCAT_PID=$! 
        log "Stats proxy started:  0.0.0.0:${STATS_PORT_PUBLIC} -> 127.0.0.1:${STATS_PORT_INTERNAL} (PID $SOCAT_PID)"
    fi
}

start_mtproxy() {
    ARGS="-u root -p ${STATS_PORT_INTERNAL}"
    
    # Add all ports with -H flag
    for port in $PORTS_LIST; do
        ARGS="$ARGS -H $port"
    done
    
    # Add all secrets with -S flag
    for secret in $SECRETS_LIST; do
        ARGS="$ARGS -S $secret"
    done
    
    ARGS="$ARGS --aes-pwd $PROXY_SECRET $PROXY_CONFIG"
    ARGS="$ARGS --nat-info ${INTERNAL_IP}:${EXTERNAL_IP}"
    ARGS="$ARGS -M $WORKERS --http-stats"
    [[ -n "${TAG:-}" ]] && ARGS="$ARGS -P $TAG"

    /usr/local/bin/mtproto-proxy $ARGS &
    MTPROXY_PID=$!
    log "MTProxy started with PID $MTPROXY_PID"
}

log "Starting MTProxy"
log "Ports: $PORTS"
log "Secrets: $SECRET_COUNT"
log "Workers: $WORKERS"

print_connection_links

# Start stats proxy once
start_stats_proxy

log "Starting MTProxy main control loop (update interval:  $CONFIG_UPDATE_INTERVAL sec)"

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