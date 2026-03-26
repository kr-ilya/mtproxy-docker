#!/bin/bash
set -Eeuo pipefail


DATA_DIR="/data"
PROXY_SECRET="$DATA_DIR/proxy-secret"
PROXY_CONFIG="$DATA_DIR/proxy-multi.conf"
SECRET_FILE="$DATA_DIR/secret"
CONFIG_UPDATE_INTERVAL="${CONFIG_UPDATE_INTERVAL:-604800}"  # default 7 days
SLEEP_PID=""
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

# Generates a Fake TLS secret: ee<domain_hex><random_padding> = 32 hex chars total after prefix
# Format: "ee" + 30 hex chars, where the first chars encode the domain
generate_fake_tls_secret() {
    local domain="${1}"
    local domain_hex
    domain_hex=$(echo -n "$domain" | od -An -tx1 | tr -d ' \n')

    # Total payload must be 30 hex chars (15 bytes), domain_hex may be shorter
    local max_len=30
    local domain_len=${#domain_hex}

    if (( domain_len >= max_len )); then
        # Domain too long — truncate to 30 chars
        echo "ee${domain_hex:0:$max_len}"
    else
        local needed=$(( max_len - domain_len ))
        local random_hex
        random_hex=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-"$needed")
        echo "ee${domain_hex}${random_hex}"
    fi
}

validate_secret() {
    # Plain secret: 32 hex chars
    # Fake TLS secret: "ee" + 30 hex chars (32 total) — same pattern
    [[ "$1" =~ ^[a-fA-F0-9]{32}$ ]] || [[ "$1" =~ ^ee[a-fA-F0-9]{30}$ ]]
}

get_external_ip() {
    for svc in ifconfig.me api.ipify.org icanhazip.com; do
        ip=$(curl -sf --max-time 5 "https://$svc" || true)
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return
    done
}

cleanup() {
    log "Shutting down..."
    [[ -n "${SLEEP_PID:-}" ]] && kill "$SLEEP_PID" 2>/dev/null || true
    [[ -n "${MTPROXY_PID:-}" ]] && kill -TERM "$MTPROXY_PID" 2>/dev/null || true
    [[ -n "${SOCAT_PID:-}" ]] && kill -TERM "$SOCAT_PID" 2>/dev/null || true
    wait "$MTPROXY_PID" 2>/dev/null || true
    wait "$SOCAT_PID" 2>/dev/null || true
    exit 0
}

trap cleanup TERM INT

# ── Fake TLS mode ────────────────────────────────────────────────────────────
# FAKE_TLS=1            — enable Fake TLS
# FAKE_TLS_DOMAIN=...   — domain to encode (default: cloudflare.com)
#
# When enabled, any secret that is provided without the "ee" prefix is ignored
# and replaced with a generated Fake TLS secret.  If SECRETS/SECRET already
# contains a valid "ee..." secret it is kept as-is.
# ─────────────────────────────────────────────────────────────────────────────
FAKE_TLS="${FAKE_TLS:-0}"
FAKE_TLS_DOMAIN="${FAKE_TLS_DOMAIN:-cloudflare.com}"

# ── Secrets setup ─────────────────────────────────────────────────────────────
# Priority: SECRETS env > SECRET env > file > auto-generate
if [[ -n "${SECRETS:-}" ]]; then
    SECRETS_LIST="${SECRETS//,/ }"
elif [[ -n "${SECRET:-}" ]]; then
    SECRETS_LIST="$SECRET"
elif [[ -f "$SECRET_FILE" ]]; then
    SECRETS_LIST=$(tr ',\n' ' ' < "$SECRET_FILE" | xargs)
else
    if [[ "$FAKE_TLS" == "1" ]]; then
        NEW_SECRET=$(generate_fake_tls_secret "$FAKE_TLS_DOMAIN")
        log "Generated new Fake TLS secret for domain: $FAKE_TLS_DOMAIN"
    else
        NEW_SECRET=$(generate_secret)
        log "Generated new plain secret"
    fi
    echo "$NEW_SECRET" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    SECRETS_LIST="$NEW_SECRET"
fi

# In Fake TLS mode: convert any plain secret to a Fake TLS secret
if [[ "$FAKE_TLS" == "1" ]]; then
    NEW_SECRETS_LIST=""
    for secret in $SECRETS_LIST; do
        if [[ "$secret" =~ ^ee[a-fA-F0-9]{30}$ ]]; then
            # Already a valid Fake TLS secret — keep it
            NEW_SECRETS_LIST="$NEW_SECRETS_LIST $secret"
        else
            log "FAKE_TLS=1: replacing plain secret with Fake TLS secret (domain: $FAKE_TLS_DOMAIN)"
            NEW_SECRETS_LIST="$NEW_SECRETS_LIST $(generate_fake_tls_secret "$FAKE_TLS_DOMAIN")"
        fi
    done
    SECRETS_LIST="${NEW_SECRETS_LIST# }"
fi

# Validate all secrets
for secret in $SECRETS_LIST; do
    validate_secret "$secret" || {
        log "Invalid secret format: $secret"
        exit 1
    }
done

SECRET_COUNT=$(echo $SECRETS_LIST | wc -w)
log "Loaded $SECRET_COUNT secret(s) (Fake TLS: $FAKE_TLS)"

# ── Networking setup ──────────────────────────────────────────────────────────
INTERNAL_IP=$(hostname -i | awk '{print $1}')
EXTERNAL_IP=${EXTERNAL_IP:-$(get_external_ip)}
EXTERNAL_IP=${EXTERNAL_IP:-$INTERNAL_IP}

WORKERS=${WORKERS:-$(nproc)}
(( WORKERS > 16 )) && WORKERS=16

# Ports: PORTS takes priority, fallback to PORT, default 443
PORTS="${PORTS:-${PORT:-443}}"
PORTS_LIST="${PORTS//,/ }"

# ── Connection info ───────────────────────────────────────────────────────────
print_connection_links() {
    echo ""
    echo "═══════════════════════════════════════════"
    echo "  MTProxy connection info:"
    echo "  Ports:    $PORTS"
    echo "  Workers:  $WORKERS"
    echo "  Secrets:  $SECRET_COUNT"
    [[ "$FAKE_TLS" == "1" ]] && echo "  Mode:     Fake TLS (domain: $FAKE_TLS_DOMAIN)"
    [[ -n "${TAG:-}" ]] && echo "  Tag:      $TAG"
    echo ""
    echo "  Connection links:"

    local secret_num=1
    for secret in $SECRETS_LIST; do
        for port in $PORTS_LIST; do
            echo "  [Secret $secret_num, Port $port]:"
            if [[ "$FAKE_TLS" == "1" ]]; then
                # Fake TLS secrets already start with "ee", pass as-is
                echo "  tg://proxy?server=${EXTERNAL_IP}&port=${port}&secret=${secret}"
            else
                echo "  tg://proxy?server=${EXTERNAL_IP}&port=${port}&secret=dd${secret}"
            fi
        done
        ((secret_num++))
    done
    echo "═══════════════════════════════════════════"
    echo ""
}

start_stats_proxy() {
    # MTProxy listens on localhost only, socat exposes it to all interfaces
    socat TCP-LISTEN:${STATS_PORT_PUBLIC},bind=0.0.0.0,fork,reuseaddr TCP:127.0.0.1:${STATS_PORT_INTERNAL} &
    SOCAT_PID=$!
    log "Stats proxy started: 0.0.0.0:${STATS_PORT_PUBLIC} -> 127.0.0.1:${STATS_PORT_INTERNAL} (PID $SOCAT_PID)"
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

# ── Main ──────────────────────────────────────────────────────────────────────
log "Starting MTProxy"
log "Ports: $PORTS"
log "Secrets: $SECRET_COUNT"
log "Workers: $WORKERS"

log "Fetching Telegram config"
if /usr/local/bin/update-config.sh; then
    log "Initial config fetched successfully"
else
    log "Initial config fetch failed"
    exit 1
fi

start_mtproxy
start_stats_proxy
print_connection_links

if [[ "$CONFIG_UPDATE_INTERVAL" -gt 0 ]]; then
    log "Starting periodic config update loop (interval: $CONFIG_UPDATE_INTERVAL sec)"
    while true; do
        sleep "$CONFIG_UPDATE_INTERVAL" &
        SLEEP_PID=$!
        wait "$SLEEP_PID"

        log "Updating Telegram config..."
        if /usr/local/bin/update-config.sh; then
            log "Config updated"

            if [[ -n "${MTPROXY_PID:-}" ]]; then
                log "Stopping MTProxy (PID $MTPROXY_PID)..."
                kill -TERM "$MTPROXY_PID" 2>/dev/null || true
                pkill -P "$MTPROXY_PID" 2>/dev/null || true
                wait "$MTPROXY_PID" 2>/dev/null || true
                MTPROXY_PID=""
            fi
            start_mtproxy
        else
            log "Config update failed (keeping old config)"
        fi
    done
else
    log "Config update disabled"
    if [[ -n "${MTPROXY_PID:-}" ]]; then
        wait "$MTPROXY_PID"
    fi
fi