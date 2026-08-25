# syntax=docker/dockerfile:1

# ============================================================
# Stage 1 - Build tproxy-server
# ============================================================

FROM golang:1.26-bookworm AS tproxy-builder

WORKDIR /src

COPY . .

RUN go test ./...

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build \
    -trimpath \
    -ldflags="-s -w" \
    -o /out/tproxy-server \
    ./cmd/tproxy-server


# ============================================================
# Stage 2 - Build official MTProxy
# ============================================================

FROM debian:bookworm-slim AS mtproxy-builder

ARG MTPROXY_COMMIT=f36d8af769ffaeac36978d38c2c0f6d1104c2137
ARG MTPROXY_SHA256=919795c416b870670841a21d1930ad97a24c7b84b9eb8c6f9e3de32f2fdf4655

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        build-essential \
        libssl-dev \
        util-linux \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --system \
    --home /nonexistent \
    --shell /usr/sbin/nologin \
    mtproxy

WORKDIR /tmp

RUN curl --fail --silent --show-error --location \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    --output MTProxy.tar.gz \
    "https://github.com/TelegramMessenger/MTProxy/archive/${MTPROXY_COMMIT}.tar.gz" \
    && echo "${MTPROXY_SHA256}  MTProxy.tar.gz" | sha256sum -c - \
    && mkdir MTProxy \
    && tar -C MTProxy --strip-components=1 -xzf MTProxy.tar.gz \
    && chown -R mtproxy:mtproxy MTProxy \
    && runuser -u mtproxy -- make -C MTProxy -j"$(nproc)" \
    && test -x MTProxy/objs/bin/mtproto-proxy


# ============================================================
# Stage 3 - Build Caddy
# ============================================================

FROM debian:bookworm-slim AS caddy-builder

ARG CADDY_VERSION=2.11.4
ARG CADDY_SHA512=8220d1f013b6f27510247b2360c9e0ca9f018feebd82515f07635318b34ff9777ccc8fd0b6e6f2486ce3a33fe389fbb7db12d05baa474f4587509fb4f5ebf1c9

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        tar \
        coreutils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp

RUN curl --fail --silent --show-error --location \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    --output caddy.tar.gz \
    "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" \
    && echo "${CADDY_SHA512}  caddy.tar.gz" | sha512sum -c - \
    && tar -xzf caddy.tar.gz \
    && test -x caddy


# ============================================================
# Stage 4 - Runtime
# ============================================================

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libssl3 \
        zlib1g \
        python3 \
    && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------
# Binaries
# ------------------------------------------------------------

COPY --from=tproxy-builder \
    /out/tproxy-server \
    /usr/local/bin/tproxy-server

COPY --from=mtproxy-builder \
    /tmp/MTProxy/objs/bin/mtproto-proxy \
    /usr/local/bin/mtproto-proxy

COPY --from=caddy-builder \
    /tmp/caddy \
    /usr/local/bin/caddy

# ------------------------------------------------------------
# Railway configuration
# ------------------------------------------------------------

COPY railway/entrypoint.sh \
    /usr/local/bin/entrypoint.sh

COPY railway/config.json \
    /etc/tproxy-server/config.json

COPY railway/profiles.json \
    /etc/tproxy-server/profiles.json

COPY railway/Caddyfile \
    /etc/caddy/Caddyfile

COPY railway/site \
    /srv/tproxy-site

# ------------------------------------------------------------
# Permissions / directories
# ------------------------------------------------------------

RUN chmod 0755 /usr/local/bin/entrypoint.sh \
    && chmod 0755 /usr/local/bin/tproxy-server \
    && chmod 0755 /usr/local/bin/mtproto-proxy \
    && chmod 0755 /usr/local/bin/caddy \
    && chmod 0644 /etc/tproxy-server/config.json \
    && chmod 0400 /etc/tproxy-server/profiles.json \
    && mkdir -p /etc/mtproxy \
    && mkdir -p /var/log/tproxy-server

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
