#!/bin/bash

set -Eeuo pipefail

echo "=========================================="
echo " tproxy-server - Railway"
echo "=========================================="

: "${PORT:?PORT is required}"
: "${PUBLIC_HOSTNAME:?PUBLIC_HOSTNAME is required}"
: "${MTPROXY_SECRET:?MTPROXY_SECRET is required}"

echo "[INFO] PORT: ${PORT}"
echo "[INFO] PUBLIC_HOSTNAME: ${PUBLIC_HOSTNAME}"

# ------------------------------------------------------------
# Validate secret
# ------------------------------------------------------------

if [[ ! "${MTPROXY_SECRET}" =~ ^[0-9a-f]{32}$ ]]; then
    echo "[ERROR] MTPROXY_SECRET must be exactly 32 lowercase hex characters"
    exit 1
fi

# ------------------------------------------------------------
# Validate hostname
# ------------------------------------------------------------

if [[ ! "${PUBLIC_HOSTNAME}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    echo "[ERROR] PUBLIC_HOSTNAME must be a lowercase ASCII hostname"
    exit 1
fi

echo "[OK] Configuration validated"

# ------------------------------------------------------------
# Prepare MTProxy files
# ------------------------------------------------------------

mkdir -p /etc/mtproxy

echo "[INFO] Downloading MTProxy secret..."

curl --fail --silent --show-error --location \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    --output /etc/mtproxy/proxy-secret \
    https://core.telegram.org/getProxySecret

echo "[INFO] Downloading MTProxy routing configuration..."

curl --fail --silent --show-error --location \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    --output /etc/mtproxy/proxy-multi.conf \
    https://core.telegram.org/getProxyConfig

# Basic validation matching the official installer.
if [[ "$(wc -c < /etc/mtproxy/proxy-secret)" -ne 128 ]]; then
    echo "[ERROR] Invalid proxy-secret"
    exit 1
fi

if [[ "$(wc -c < /etc/mtproxy/proxy-multi.conf)" -lt 100 ]]; then
    echo "[ERROR] Invalid proxy-multi.conf"
    exit 1
fi

grep -q '^default ' /etc/mtproxy/proxy-multi.conf
grep -q '^proxy_for ' /etc/mtproxy/proxy-multi.conf

chmod 0640 /etc/mtproxy/proxy-secret
chmod 0640 /etc/mtproxy/proxy-multi.conf

# ------------------------------------------------------------
# Generate tproxy profile
# ------------------------------------------------------------

cat > /etc/tproxy-server/profiles.json <<EOF
{
  "profiles": [
    {
      "name": "default",
      "secret": "${MTPROXY_SECRET}",
      "backend": "127.0.0.1:2398",
      "carrier_mode": "https"
    }
  ]
}
EOF

chmod 0400 /etc/tproxy-server/profiles.json

# ------------------------------------------------------------
# Generate tproxy configuration
# ------------------------------------------------------------

cat > /etc/tproxy-server/config.json <<EOF
{
  "public_hostname": "${PUBLIC_HOSTNAME}",
  "listen": "127.0.0.1:8080",
  "admin_listen": "127.0.0.1:8081",
  "public_dir": "/srv/tproxy-site",
  "profiles_file": "/etc/tproxy-server/profiles.json",
  "enable_pprof": false,

  "limits": {
    "max_header_bytes": 16384,
    "max_body_bytes": 2097152,
    "max_frame_payload": 1048576,
    "carrier_batch_bytes": 2097152,

    "max_streams_per_session": 128,
    "max_closed_stream_ids": 4096,

    "max_pending_per_session": 33554432,
    "max_pending_global": 536870912,

    "max_pending_items_per_session": 16384,
    "max_pending_items_global": 262144,

    "max_sessions_per_ip": 0,
    "max_sessions_global": 128,

    "max_streams_global": 4096,
    "max_backend_dials_in_flight": 256,

    "new_sessions_per_minute": 600,
    "new_sessions_burst": 128,

    "new_streams_per_minute": 6000,
    "new_streams_burst": 512,

    "max_bootstraps_per_ip": 0,
    "max_bootstraps_global": 512,

    "new_bootstraps_per_minute": 1200,
    "new_bootstraps_burst": 256,

    "max_profiles": 32
  },

  "timeouts": {
    "backend_dial": "5s",
    "long_poll": "25s",
    "reconnect_grace": "2m",
    "bootstrap_lifetime": "2m",
    "read_header": "10s",
    "idle": "75s",
    "shutdown": "15s"
  }
}
EOF

# ------------------------------------------------------------
# Validate tproxy configuration
# ------------------------------------------------------------

echo "[INFO] Validating tproxy-server configuration..."

/usr/local/bin/tproxy-server \
    -config /etc/tproxy-server/config.json \
    -profiles-file /etc/tproxy-server/profiles.json \
    -check

echo "[OK] tproxy-server configuration valid"

# ------------------------------------------------------------
# Start official MTProxy
# ------------------------------------------------------------

echo "[INFO] Starting MTProxy..."

mtproto-proxy \
    -u nobody \
    -p 8888 \
    -H 2398 \
    -S "${MTPROXY_SECRET}" \
    --aes-pwd /etc/mtproxy/proxy-secret \
    /etc/mtproxy/proxy-multi.conf \
    -M 1 \
    -C 4096 \
    > /var/log/tproxy-server/mtproxy.log 2>&1 &

MTPROXY_PID=$!

sleep 2

if ! kill -0 "${MTPROXY_PID}" 2>/dev/null; then
    echo "[ERROR] MTProxy failed to start"
    cat /var/log/tproxy-server/mtproxy.log || true
    exit 1
fi

echo "[OK] MTProxy started"

# ------------------------------------------------------------
# Start tproxy-server
# ------------------------------------------------------------

echo "[INFO] Starting tproxy-server..."

/usr/local/bin/tproxy-server \
    -config /etc/tproxy-server/config.json \
    -profiles-file /etc/tproxy-server/profiles.json \
    > /var/log/tproxy-server/tproxy.log 2>&1 &

TPROXY_PID=$!

sleep 2

if ! kill -0 "${TPROXY_PID}" 2>/dev/null; then
    echo "[ERROR] tproxy-server failed to start"
    cat /var/log/tproxy-server/tproxy.log || true
    exit 1
fi

echo "[OK] tproxy-server started"

# ------------------------------------------------------------
# Wait until relay is ready
# ------------------------------------------------------------

echo "[INFO] Waiting for relay readiness..."

READY=0

for i in $(seq 1 20); do
    if curl --fail --silent \
        http://127.0.0.1:8081/readyz \
        > /dev/null; then

        READY=1
        break
    fi

    sleep 1
done

if [[ "${READY}" != "1" ]]; then
    echo "[ERROR] tproxy-server did not become ready"

    echo "----- tproxy-server log -----"
    cat /var/log/tproxy-server/tproxy.log || true

    echo "----- MTProxy log -----"
    cat /var/log/tproxy-server/mtproxy.log || true

    exit 1
fi

echo "[OK] tproxy-server is ready"

# ------------------------------------------------------------
# Validate Caddy configuration
# ------------------------------------------------------------

echo "[INFO] Validating Caddy configuration..."

caddy validate \
    --config /etc/caddy/Caddyfile \
    --adapter caddyfile

echo "[OK] Caddy configuration valid"

# ------------------------------------------------------------
# Start Caddy
# ------------------------------------------------------------

echo "[INFO] Starting Caddy on port ${PORT}..."

caddy run \
    --config /etc/caddy/Caddyfile \
    --adapter caddyfile \
    > /var/log/tproxy-server/caddy.log 2>&1 &

CADDY_PID=$!

sleep 2

if ! kill -0 "${CADDY_PID}" 2>/dev/null; then
    echo "[ERROR] Caddy failed to start"
    cat /var/log/tproxy-server/caddy.log || true
    exit 1
fi

echo "[OK] Caddy started"

echo "=========================================="
echo " All services are running"
echo "=========================================="

# ------------------------------------------------------------
# Shutdown handling
# ------------------------------------------------------------

cleanup() {
    echo "[INFO] Shutting down..."

    kill "${CADDY_PID}" 2>/dev/null || true
    kill "${TPROXY_PID}" 2>/dev/null || true
    kill "${MTPROXY_PID}" 2>/dev/null || true

    wait "${CADDY_PID}" 2>/dev/null || true
    wait "${TPROXY_PID}" 2>/dev/null || true
    wait "${MTPROXY_PID}" 2>/dev/null || true
}

trap cleanup SIGTERM SIGINT

# Keep container alive while monitoring all processes.
while true; do

    if ! kill -0 "${CADDY_PID}" 2>/dev/null; then
        echo "[ERROR] Caddy stopped"
        exit 1
    fi

    if ! kill -0 "${TPROXY_PID}" 2>/dev/null; then
        echo "[ERROR] tproxy-server stopped"
        exit 1
    fi

    if ! kill -0 "${MTPROXY_PID}" 2>/dev/null; then
        echo "[ERROR] MTProxy stopped"
        exit 1
    fi

    sleep 5

done
