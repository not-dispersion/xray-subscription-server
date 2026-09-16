#!/bin/bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Error: Run as root (sudo hub-update)"; exit 1; }

INSTALL_DIR="${1:-$(pwd)}"
HUB_DIR="$INSTALL_DIR/central-hub"

if [[ ! -d "$HUB_DIR" ]]; then
    echo "Error: Directory $HUB_DIR not found."
    exit 1
fi

echo "=================================================="
echo "      UPDATING CENTRAL HUB BACKEND & SCRIPTS      "
echo "=================================================="

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

echo "--> Fetching latest release from Git..."
git clone --depth 1 --filter=blob:none --sparse \
    "https://github.com/not-dispersion/xray-subscription-server.git" \
    "$tmp_dir"

(
    cd "$tmp_dir"
    git sparse-checkout set central-hub
)

echo "--> Stopping central-hub service..."
systemctl stop central-hub.service || true

if ss -ltnp 'sport = :8000' | grep -q LISTEN; then
    echo "--> Waiting for port 8000 to be freed..."
    fuser -k 8000/tcp 2>/dev/null || true
    sleep 1
fi

echo "--> Syncing Python backend files..."
rsync -av --delete \
    --exclude='.env' \
    --exclude='.venv' \
    --exclude='*.db' \
    --exclude='*.db-wal' \
    --exclude='*.db-shm' \
    --exclude='__pycache__' \
    "$tmp_dir/central-hub/" "$HUB_DIR/"

if [[ -f "$HUB_DIR/requirements.txt" && -f "$HUB_DIR/.venv/bin/pip" ]]; then
    echo "--> Verifying Python dependencies..."
    "$HUB_DIR/.venv/bin/pip" install --upgrade pip --quiet
    "$HUB_DIR/.venv/bin/pip" install -r "$HUB_DIR/requirements.txt" --quiet
fi

echo "--> Reloading systemd daemon..."
systemctl daemon-reload

echo "--> Starting central-hub service..."
systemctl start central-hub.service

sleep 2
if ! curl -s -f http://127.0.0.1:8000/docs > /dev/null; then
    echo "[ERROR] FastAPI backend did not respond on 127.0.0.1:8000."
    echo "Check logs: journalctl -u central-hub -n 50"
    exit 1
fi

echo "=================================================="
echo " [OK] Central Hub updated and running cleanly!     "
echo "=================================================="