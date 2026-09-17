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

exists=$(jq --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email)' /usr/local/etc/xray/config.json)
[[ -n "$exists" ]] && { echo "Error: user '$email' already exists."; exit 1; }

uuid=$(xray uuid)
tmp=$(mktemp)
jq --arg email "$email" --arg uuid "$uuid" \
    '.inbounds[0].settings.clients += [{"email": $email, "id": $uuid, "flow": "xtls-rprx-vision"}]' \
    /usr/local/etc/xray/config.json > "$tmp"

mv "$tmp" /usr/local/etc/xray/config.json
chmod 644 /usr/local/etc/xray/config.json
systemctl restart xray

protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
pbk=$(awk -F': ' '/^Password( \(PublicKey\))?:/ {print $2}' /usr/local/etc/xray/.keys)
sid=$(awk -F': ' '/^shortsid:/ {print $2}' /usr/local/etc/xray/.keys)
host=$(curl -4 -s icanhazip.com)

encoded_pbk=$(echo -n "$pbk" | jq -sRr @uri)

link="$protocol://$uuid@$host:$port?security=reality&sni=$sni&fp=firefox&pbk=$encoded_pbk&sid=$sid&spx=/&type=tcp&flow=xtls-rprx-vision&encryption=none#$email"

echo
echo "User added successfully."
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

mapfile -t emails < <(jq -r '.inbounds[0].settings.clients[].email' /usr/local/etc/xray/config.json)
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

tmp=$(mktemp)
jq --arg email "$selected" '(.inbounds[0].settings.clients) |= map(select(.email != $email))' /usr/local/etc/xray/config.json > "$tmp"
mv "$tmp" /usr/local/etc/xray/config.json
chmod 644 /usr/local/etc/xray/config.json
systemctl restart xray

echo "Client '$selected' removed."
EOF
chmod +x /usr/local/bin/rm-user

# share-link
cat << 'EOF' > /usr/local/bin/share-link
#!/bin/bash
set -euo pipefail

mapfile -t emails < <(jq -r '.inbounds[0].settings.clients[].email' /usr/local/etc/xray/config.json)
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
uuid=$(jq -r --arg email "$selected" '.inbounds[0].settings.clients[] | select(.email == $email) | .id' /usr/local/etc/xray/config.json)

protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
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

mapfile -t emails < <(jq -r '.inbounds[0].settings.clients[].email' /usr/local/etc/xray/config.json)
[[ ${#emails[@]} -eq 0 ]] && { echo "Error: No clients found."; exit 1; }

echo "Client list:"
for i in "${!emails[@]}"; do
    echo "$((i + 1)). ${emails[$i]}"
done
EOF
chmod +x /usr/local/bin/user-list

# trigger first user creation
echo
echo "Installation complete. Node is ready and listening for central-hub sync."
echo "Installation complete. To mannualy create a connection link run: sudo new-user"