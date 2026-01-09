#!/bin/sh
set -e

curl -sf --max-time 30 \
  https://core.telegram.org/getProxySecret \
  -o /data/proxy-secret.tmp && \
  mv /data/proxy-secret.tmp /data/proxy-secret

curl -sf --max-time 30 \
  https://core.telegram.org/getProxyConfig \
  -o /data/proxy-multi.conf.tmp && \
  mv /data/proxy-multi.conf.tmp /data/proxy-multi.conf
