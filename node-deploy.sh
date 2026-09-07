#!/bin/bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Error: Run as root"; exit 1; }
echo "Root: OK"

[[ -d /run/systemd/system ]] || {
    echo "Error: Systemd is not running"
    exit 1
}
echo "Systemd: OK"

hub_domain="${transfer_domain:-}"
[[ -n "$hub_domain" ]] || { echo "Error: transfer_domain is required"; exit 1; }

node_key="${transfer_key:-}"
[[ -n "$node_key" ]] || { echo "Error: transfer_key is required"; exit 1; }

hub_ip=$(getent ahostsv4 "$hub_domain" | awk '{ print $1 }' | head -n1)
[[ -n "$hub_ip" ]] || { echo "Error: Could not resolve IP for domain $hub_domain"; exit 1; }
echo "Hub domain: $hub_domain -> Resolved IP: $hub_ip"
read -rp "Enter your SSH port (or press Enter for default: 22): " ssh_port < /dev/tty || ssh_port=""

ssh_port=${ssh_port:-22}
echo "Your SSH port is: $ssh_port"

read -rp "Enter your server-to-node access port (or press Enter for default: 8443): " node_port < /dev/tty || node_port=""
node_port=${node_port:-8443}
echo "Your node access port is: $node_port"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    git \
    python3 \
    python3-venv \
    python3-pip \
    jq \
    ufw
apt-get clean
echo "Environment and python dependencies: OK"

echo "Node Agent is going to be installed into current working directory"
install_dir="$(pwd)"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

git clone --depth 1 --filter=blob:none --sparse \
    "https://github.com/not-dispersion/xray-subscription-server.git" \
    "$tmp_dir"

(
    cd "$tmp_dir"
    git sparse-checkout set node-agent
    mkdir -p "$install_dir/node-agent"
    cp -r node-agent/. "$install_dir/node-agent/"
)

printf 'NODE_KEY=%s\n' "$node_key" > "$install_dir/node-agent/.env"
chmod 600 "$install_dir/node-agent/.env"

echo "Setting up virtual environment and python dependencies..."

python3 -m venv "$install_dir/node-agent/.venv"
"$install_dir/node-agent/.venv/bin/pip" install --upgrade pip
"$install_dir/node-agent/.venv/bin/pip" install -r "$install_dir/node-agent/requirements.txt"

cat <<EOF > /etc/systemd/system/node-agent.service
[Unit]
Description=Xray Subscription Server - Node Agent
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$install_dir/node-agent
ExecStart=$install_dir/node-agent/.venv/bin/uvicorn node_agent:app --host 0.0.0.0 --port $node_port --workers 1
Restart=always
RestartSec=3
EnvironmentFile=$install_dir/node-agent/.env

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node-agent.service

sleep 2
if ! curl -s -f "http://127.0.0.1:$node_port/docs" > /dev/null; then
    echo "Warning: FastAPI backend did not respond at 127.0.0.1:$node_port. Check 'journalctl -u node-agent -n 50'"
else
    echo "FastAPI backend: OK"
fi

ufw allow "$ssh_port/tcp"
ufw allow 443/tcp
ufw allow from "$hub_ip" to any port "$node_port" proto tcp
ufw --force enable

echo " Allowed incoming control traffic ONLY from $hub_ip ($hub_domain)"