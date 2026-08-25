#!/bin/bash

set -Eeuo pipefail

echo "=========================================="
echo " tproxy-server Railway"
echo "=========================================="

: "${PORT:=8080}"
: "${PUBLIC_HOSTNAME:?PUBLIC_HOSTNAME is required}"
: "${MTPROXY_SECRET:?MTPROXY_SECRET is required}"

echo "[INFO] Hostname: ${PUBLIC_HOSTNAME}"
echo "[INFO] Railway PORT: ${PORT}"

mkdir -p /etc/mtproxy
mkdir -p /var/log/tproxy-server

echo "[INFO] Downloading MTProxy secret..."

curl --fail --silent --show-error --location \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    --output /etc/mtproxy/proxy-secret \
    https://core.telegram.org/getProxySecret

echo "[INFO] Downloading MTProxy config..."

curl --fail --silent --show-error --location \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    --output /etc/mtproxy/proxy-multi.conf \
    https://core.telegram.org/getProxyConfig

chmod 600 /etc/mtproxy/proxy-secret
chmod 600 /etc/mtproxy/proxy-multi.conf

echo "[INFO] Starting MTProxy..."

mtproto-proxy \
    -u nobody \
    -p 2398 \
    -H 2398 \
    -S "${MTPROXY_SECRET}" \
    -M 1 \
    > /var/log/tproxy-server/mtproxy.log 2>&1 &

MTPROXY_PID=$!

sleep 2

if ! kill -0 "${MTPROXY_PID}" 2>/dev/null; then
    echo "[ERROR] MTProxy failed to start"
    cat /var/log/tproxy-server/mtproxy.log || true
    exit 1
fi

echo "[OK] MTProxy started"


echo "[INFO] Preparing tproxy-server configuration..."

python3 <<'PY'
import json
import os

path = "/etc/tproxy-server/config.json"

with open(path, "r", encoding="utf-8") as f:
    config = json.load(f)

config["public_hostname"] = os.environ["PUBLIC_HOSTNAME"]

# tproxy-server remains internal.
config["listen"] = "127.0.0.1:8080"
config["admin_listen"] = "127.0.0.1:8081"

config["public_dir"] = "/srv/tproxy-site"

config["profiles_file"] = "/etc/tproxy-server/profiles.json"

with open(path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
PY


echo "[INFO] Preparing profile..."

python3 <<'PY'
import json
import os

path = "/etc/tproxy-server/profiles.json"

data = {
    "profiles": [
        {
            "name": "railway",
            "secret": os.environ["MTPROXY_SECRET"],
            "backend": "127.0.0.1:2398",
            "carrier_mode": "https",
            "limits": {}
        }
    ]
}

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY


echo "[INFO] Starting tproxy-server..."

tproxy-server \
    -config "${TPROXY_CONFIG}" \
    > /var/log/tproxy-server/tproxy.log 2>&1 &

TPROXY_PID=$!

sleep 2

if ! kill -0 "${TPROXY_PID}" 2>/dev/null; then
    echo "[ERROR] tproxy-server failed to start"
    cat /var/log/tproxy-server/tproxy.log || true
    exit 1
fi

echo "[OK] tproxy-server started"

echo "=========================================="
echo " All services started"
echo "=========================================="

wait "${TPROXY_PID}"
