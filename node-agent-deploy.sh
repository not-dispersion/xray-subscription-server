#!/bin/bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Error: Run as root"; exit 1; }
echo "Root: OK"

[[ -d /run/systemd/system ]] || {
    echo "Error: Systemd is not running"
    exit 1
}
echo "Systemd: OK"

if ss -ltnp 'sport = :443' | grep -q LISTEN; then
    echo "WARNING: Port 443 is already in use."
    read -rp "Do you want to continue anyway? (Y/n): " answer < /dev/tty || answer=""
    [[ "${answer:-y}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
else
    echo "Ports 443 TCP: OK"
fi

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
    ufw \
    qrencode
apt-get clean
echo "Environment and dependencies: OK"

# enabling BBR
if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
    echo "BBR is already enabled."
else
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || \
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf

    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || \
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

    sysctl -p
    echo "BBR enabled: OK"
fi

# installing Xray
bash -c "$(curl -4 -fSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# creating .keys
short_sid=$(openssl rand -hex 8)

echo "shortsid: $short_sid" > /usr/local/etc/xray/.keys
xray x25519 >> /usr/local/etc/xray/.keys

xray_private_key=$(awk -F': ' '/^PrivateKey:/ {print $2}' /usr/local/etc/xray/.keys)
chmod 644 /usr/local/etc/xray/.keys

# creating a configuration file
cat << EOF > /usr/local/etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "api": {
    "tag": "api",
    "services": [
      "HandlerService",
      "StatsService"
    ]
  },
  "dns": {
    "servers": [
      "1.1.1.1",
      "8.8.8.8",
      "localhost"
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "inboundTag": ["api"],
        "outboundTag": "api",
        "type": "field"
      },
      {
        "type": "field",
        "inboundTag": ["dns-in"],
        "outboundTag": "dns-out"
      },
      {
        "type": "field",
        "domain": [
          "geosite:category-ads-all"
        ],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "VLESS-IN",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "addons.mozilla.org:443",
          "xver": 0,
          "serverNames": [
            "addons.mozilla.org"
          ],
          "privateKey": "${xray_private_key}",
          "shortIds": [
            "${short_sid}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "tag": "api",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "dns",
      "tag": "dns-out"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

chmod 644 /usr/local/etc/xray/config.json
systemctl enable --now xray

mkdir -p /etc/node-agent
if [[ ! -f /etc/node-agent/users_state.json ]]; then
    echo "{}" > /etc/node-agent/users_state.json
    chmod 644 /etc/node-agent/users_state.json
fi

echo "Installing Node Agent into current working directory."
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

echo "Setting up virtual environment and python dependencies."
python3 -m venv "$install_dir/node-agent/.venv"
"$install_dir/node-agent/.venv/bin/pip" install --upgrade pip
"$install_dir/node-agent/.venv/bin/pip" install -r "$install_dir/node-agent/requirements.txt"

cat <<EOF > /etc/systemd/system/node-agent.service
[Unit]
Description=Xray Subscription Server - Node Agent
After=network.target xray.service
Wants=xray.service

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
if ! curl -s -f "http://127.0.0.1:$node_port/health" -H "X-Node-Secret: $node_key" > /dev/null; then
    echo "Warning: FastAPI backend did not respond at 127.0.0.1:$node_port. Check 'journalctl -u node-agent -n 50'"
else
    echo "FastAPI backend: OK"
fi

ufw allow "$ssh_port/tcp"
ufw allow 443/tcp
ufw allow from "$hub_ip" to any port "$node_port" proto tcp
ufw --force enable
echo "Allowed incoming control traffic ONLY from $hub_ip ($hub_domain)"

# new-user
cat << 'EOF' > /usr/local/bin/new-user
#!/bin/bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Error: Run as root."; exit 1; }

read -rp "Enter username (email): " email
[[ -z "$email" || "$email" == *" "* ]] && { echo "Error: username cannot be empty or contain spaces."; exit 1; }

uuid=$(xray uuid)

tmp_json=$(mktemp --suffix=.json)
trap 'rm -f "$tmp_json"' EXIT

cat << JSON_EOF > "$tmp_json"
{
  "tag": "VLESS-IN",
  "users": [
    {
      "id": "$uuid",
      "email": "$email",
      "flow": "xtls-rprx-vision",
      "level": 0
    }
  ]
}
JSON_EOF

if ! xray api adu --server=127.0.0.1:10085 "$tmp_json"; then
    echo "Error: Failed to add user to Xray API."
    exit 1
fi

state_file="/etc/node-agent/users_state.json"
mkdir -p /etc/node-agent
if [[ ! -f "$state_file" ]]; then
    echo "{}" > "$state_file"
fi

tmp=$(mktemp)
jq --arg email "$email" --arg uuid "$uuid" '.[$email] = $uuid' "$state_file" > "$tmp"
mv "$tmp" "$state_file"
chmod 644 "$state_file"

protocol=$(jq -r '.inbounds[] | select(.tag=="VLESS-IN") | .protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[] | select(.tag=="VLESS-IN") | .port' /usr/local/etc/xray/config.json)
sni=$(jq -r '.inbounds[] | select(.tag=="VLESS-IN") | .streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
pbk=$(awk -F': ' '/^Password( \(PublicKey\))?:/ {print $2}' /usr/local/etc/xray/.keys)
sid=$(awk -F': ' '/^shortsid:/ {print $2}' /usr/local/etc/xray/.keys)
host=$(curl -4 -s icanhazip.com)

encoded_pbk=$(echo -n "$pbk" | jq -sRr @uri)

link="$protocol://$uuid@$host:$port?security=reality&sni=$sni&fp=firefox&pbk=$encoded_pbk&sid=$sid&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#$email"

echo
echo "User added dynamically."
echo "Connection link:"
echo "$link"
echo
echo "QR code:"
echo "$link" | qrencode -t ansiutf8
EOF
chmod +x /usr/local/bin/new-user

# rm-user
cat << 'EOF' > /usr/local/bin/rm-user
#!/bin/bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Error: Run as root."; exit 1; }

state_file="/etc/node-agent/users_state.json"
[[ -f "$state_file" ]] || { echo "No users found in $state_file"; exit 1; }

mapfile -t emails < <(jq -r 'keys[]' "$state_file")
[[ ${#emails[@]} -eq 0 ]] && { echo "No clients to remove."; exit 1; }

echo "Client list:"
for i in "${!emails[@]}"; do
    echo "$((i + 1)). ${emails[$i]}"
done

read -rp "Enter client number to remove: " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
    echo "Error: invalid number."
    exit 1
fi

selected="${emails[$((choice - 1))]}"

xray api rmu --server=127.0.0.1:10085 -tag="VLESS-IN" "$selected" || true
tmp=$(mktemp)
jq --arg email "$selected" 'del(.[$email])' "$state_file" > "$tmp"
mv "$tmp" "$state_file"
chmod 644 "$state_file"

echo "Client '$selected' removed."
EOF
chmod +x /usr/local/bin/rm-user

# share-link
cat << 'EOF' > /usr/local/bin/share-link
#!/bin/bash
set -euo pipefail

state_file="/etc/node-agent/users_state.json"
[[ -f "$state_file" ]] || { echo "Error: No state file found."; exit 1; }

mapfile -t emails < <(jq -r 'keys[]' "$state_file")
[[ ${#emails[@]} -eq 0 ]] && { echo "No clients found."; exit 1; }

echo "Client list:"
for i in "${!emails[@]}"; do
    echo "$((i + 1)). ${emails[$i]}"
done

read -rp "Select client: " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
    echo "Error: number must be between 1 and ${#emails[@]}"
    exit 1
fi

selected="${emails[$((choice - 1))]}"
uuid=$(jq -r --arg email "$selected" '.[$email]' "$state_file")

protocol=$(jq -r '.inbounds[] | select(.tag=="VLESS-IN") | .protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[] | select(.tag=="VLESS-IN") | .port' /usr/local/etc/xray/config.json)
sni=$(jq -r '.inbounds[] | select(.tag=="VLESS-IN") | .streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
pbk=$(awk -F': ' '/^Password( \(PublicKey\))?:/ {print $2}' /usr/local/etc/xray/.keys)
sid=$(awk -F': ' '/^shortsid:/ {print $2}' /usr/local/etc/xray/.keys)
host=$(curl -4 -s icanhazip.com)

encoded_pbk=$(echo -n "$pbk" | jq -sRr @uri)

link="$protocol://$uuid@$host:$port?security=reality&sni=$sni&fp=firefox&pbk=$encoded_pbk&sid=$sid&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#$selected"

echo
echo "Connection link:"
echo "$link"
echo
echo "QR code:"
echo "$link" | qrencode -t ansiutf8
EOF
chmod +x /usr/local/bin/share-link

# user-list
cat << 'EOF' > /usr/local/bin/user-list
#!/bin/bash
set -euo pipefail

state_file="/etc/node-agent/users_state.json"
[[ -f "$state_file" ]] || { echo "Error: No state file found."; exit 1; }

mapfile -t emails < <(jq -r 'keys[]' "$state_file")
[[ ${#emails[@]} -eq 0 ]] && { echo "Error: No clients found."; exit 1; }

echo "Client list:"
for i in "${!emails[@]}"; do
    echo "$((i + 1)). ${emails[$i]}"
done
EOF
chmod +x /usr/local/bin/user-list

# trigger first user creation
echo
echo "Installation complete. To mannualy create a connection link run: sudo new-user"