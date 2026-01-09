#!/bin/sh

STATS_PORT="${STATS_PORT:-8888}"

pgrep -f mtproto-proxy >/dev/null || exit 1
curl -sf --max-time 3 "http://127.0.0.1:$STATS_PORT/stats" >/dev/null || exit 1
