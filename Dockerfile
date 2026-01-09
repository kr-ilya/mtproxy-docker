FROM debian:bookworm-slim AS builder

ARG MTPROTO_REPO_URL=https://github.com/TelegramMessenger/MTProxy
ARG MTPROTO_COMMIT=cafc338

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    build-essential \
    libssl-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN git clone --depth=1 ${MTPROTO_REPO_URL} . \
    && git checkout ${MTPROTO_COMMIT} \
    && make -j$(nproc) \
    && strip objs/bin/mtproto-proxy


FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    socat \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -r -u 10001 mtproxy

COPY --from=builder /build/objs/bin/mtproto-proxy /usr/local/bin/mtproto-proxy
COPY entrypoint.sh /entrypoint.sh
COPY update-config.sh /usr/local/bin/update-config.sh
COPY healthcheck.sh /healthcheck.sh

RUN chmod +x /entrypoint.sh /usr/local/bin/update-config.sh /healthcheck.sh \
    && mkdir -p /data \
    && chown -R mtproxy:mtproxy /data

USER mtproxy
WORKDIR /data

ENV PORT=443 \
    PORTS="" \
    STATS_PORT=8888 \
    WORKERS="" \
    SECRET="" \
    TAG="" \
    EXTERNAL_IP="" \
    EXTRA_ARGS=""

EXPOSE 443 8888
VOLUME ["/data"]

HEALTHCHECK --interval=60s --timeout=5s --start-period=20s --retries=3 \
  CMD /healthcheck.sh

ENTRYPOINT ["/entrypoint.sh"]
