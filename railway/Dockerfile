# syntax=docker/dockerfile:1

# ============================================================
# Stage 1 — Build tproxy-server
# ============================================================

FROM golang:1.24-bookworm AS tproxy-builder

WORKDIR /src

COPY . .

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build \
    -trimpath \
    -ldflags="-s -w" \
    -o /out/tproxy-server \
    ./cmd/tproxy-server


# ============================================================
# Stage 2 — Build MTProxy
# ============================================================

FROM debian:bookworm-slim AS mtproxy-builder

ARG MTPROXY_COMMIT=f36d8af769ffaeac36978d38c2c0f6d1104c2137

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        build-essential \
        libssl-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp

RUN curl --fail --silent --show-error --location \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    --output MTProxy.tar.gz \
    "https://github.com/TelegramMessenger/MTProxy/archive/${MTPROXY_COMMIT}.tar.gz" \
    && mkdir MTProxy \
    && tar -C MTProxy --strip-components=1 -xzf MTProxy.tar.gz \
    && make -C MTProxy -j"$(nproc)" \
    && test -x MTProxy/objs/bin/mtproto-proxy


# ============================================================
# Stage 3 — Runtime
# ============================================================

FROM debian:bookworm-slim
ARG CADDY_VERSION=2.10.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libssl3 \
        zlib1g \
        python3 \
    && rm -rf /var/lib/apt/lists/*

RUN curl --fail --silent --show-error --location \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    --output /tmp/caddy.tar.gz \
    "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" \
    && tar -xzf /tmp/caddy.tar.gz -C /tmp \
    && install -m 0755 /tmp/caddy /usr/local/bin/caddy \
    && rm -rf /tmp/caddy /tmp/caddy.tar.gz
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libssl3 \
        zlib1g \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# tproxy-server
COPY --from=tproxy-builder \
    /out/tproxy-server \
    /usr/local/bin/tproxy-server

# MTProxy
COPY --from=mtproxy-builder \
    /tmp/MTProxy/objs/bin/mtproto-proxy \
    /usr/local/bin/mtproto-proxy

# Railway startup script
COPY railway/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY railway/Caddyfile /etc/caddy/Caddyfile
# Configuration
COPY railway/config.json /etc/tproxy-server/config.json
COPY railway/profiles.json /etc/tproxy-server/profiles.json

# Public website
COPY railway/site /srv/tproxy-site

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p /etc/mtproxy \
    && mkdir -p /var/log/tproxy-server

ENV TPROXY_CONFIG=/etc/tproxy-server/config.json

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
