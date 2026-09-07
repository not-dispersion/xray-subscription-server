#!/bin/bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Error: Run as root."; exit 1; }
echo "Root: OK"

[[ -d /run/systemd/system ]] || {
    echo "Error: Systemd is not running."
    exit 1
}
echo "Systemd: OK"

for port in 80 443 8000; do
    if ss -ltnp "sport = :$port" | grep -q LISTEN; then
        echo "WARNING: TCP port $port is already in use."
        read -p "Do you want to continue anyway? (Y/n): " answer
        [[ "${answer:-y}" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
    else
        echo "Port $port TCP: OK"
    fi
done

ip=$(curl -4 -s icanhazip.com)

read -p "Enter your domain name: " domain
domain=$(echo "$domain" | sed -e 's|^[^/]*//||' -e 's|/.*$||' | xargs)
[[ -n "$domain" ]] || { echo "Domain cannot be empty."; exit 1; }
echo "Your domain is: $domain"

domain_ip=$(getent ahostsv4 "$domain" | awk '{ print $1 }' | head -n1)
echo "Domain A-record: $domain_ip"
echo "Server IP: $ip"

[[ "$domain_ip" == "$ip" ]] || {
    echo "Error: A-record and server IP don't match."
    exit 1
}
echo "DNS check: OK"

read -p "Enter Let's Encrypt email (for SSL renewal alerts): " cert_email
[[ -n "$cert_email" ]] || { echo "Email cannot be empty."; exit 1; }
[[ "$cert_email" == *"@"* ]] || { echo "Email must contain @."; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    python3 \
    python3-venv \
    python3-pip \
    nginx \
    certbot \
    python3-certbot-nginx \
    curl \
    jq \
    sqlite3 \
    openssl
apt-get clean
echo "Environment and python dependencies: OK"
echo "Central Hub is going to be installed into current working directory"

install_dir="$(pwd)"
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

git clone --depth 1 --filter=blob:none --sparse \
    "https://github.com/not-dispersion/xray-subscription-server.git" \
    "$tmp_dir"

(
    cd "$tmp_dir"
    git sparse-checkout set central-hub
    mkdir -p "$install_dir/central-hub"
    cp -r central-hub/. "$install_dir/central-hub/"
)

node_key=$(openssl rand -hex 16)
admin_api_key=$(openssl rand -hex 16)

printf 'NODE_KEY=%s\nADMIN_API_KEY=%s\n' "$node_key" "$admin_api_key" > "$install_dir/central-hub/.env"
chmod 600 "$install_dir/central-hub/.env"

echo "Setting up virtual environment and python dependencies..."

python3 -m venv "$install_dir/central-hub/.venv"
"$install_dir/central-hub/.venv/bin/pip" install --upgrade pip
"$install_dir/central-hub/.venv/bin/pip" install -r "$install_dir/central-hub/requirements.txt"

cat <<EOF > /etc/systemd/system/central-hub.service
[Unit]
Description=Xray Subscription Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$install_dir/central-hub
ExecStart=$install_dir/central-hub/.venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000 --workers 1
Restart=always
RestartSec=3
EnvironmentFile=$install_dir/central-hub/.env

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now central-hub.service

sleep 2
if ! curl -s -f http://127.0.0.1:8000/docs > /dev/null; then
    echo "Warning: FastAPI backend did not respond at 127.0.0.1:8000. Check 'journalctl -u central-hub -n 50'"
else
    echo "FastAPI backend: OK"
fi

cat <<EOF > "/etc/nginx/sites-available/$domain"
server {
    listen 80;
    server_name $domain;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf "/etc/nginx/sites-available/$domain" "/etc/nginx/sites-enabled/$domain"
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

certbot --nginx \
    -d "$domain" \
    --non-interactive \
    --agree-tos \
    -m "$cert_email" \
    --redirect

systemctl reload nginx
echo "Nginx & SSL configured successfully on https://$domain"

cat <<EOF > "/usr/local/bin/crl-hub-ctl"
#!/bin/bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Error: Please run as root (sudo crl-hub-ctl)"; exit 1; }

hub_domain="$domain"
api_url="https://$domain"
env_file="$install_dir/central-hub/.env"
EOF

cat <<'EOF' >> "/usr/local/bin/crl-hub-ctl"

admin_key=$(grep -E '^(ADMIN_API_KEY)=' "$env_file" | cut -d '=' -f2- | tr -d '\r"')
if [[ -z "$admin_key" ]]; then
    echo "Error: ADMIN_API_KEY is missing in $env_file"
    exit 1
fi

prompt_non_empty() {
    local prompt_text="$1"
    local var_name="$2"
    local input=""
    while true; do
        read -rp "$prompt_text: " input
        if [[ -n "${input// /}" ]]; then
            eval "$var_name=\"$input\""
            break
        fi
        echo " [!] Field cannot be empty. Try again."
    done
}

prompt_integer() {
    local prompt_text="$1"
    local var_name="$2"
    local default_val="$3"
    local min_val="$4"
    local max_val="$5"
    local input=""

    while true; do
        if [[ -n "$default_val" ]]; then
            read -rp "$prompt_text [$default_val]: " input
            input="${input:-$default_val}"
        else
            read -rp "$prompt_text: " input
        fi

        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= min_val && input <= max_val )); then
            eval "$var_name=\"$input\""
            break
        fi
        echo " [!] Invalid input. Enter an integer between $min_val and $max_val."
    done
}

prompt_url() {
    local prompt_text="$1"
    local var_name="$2"
    local input=""
    local url_regex='^https?://[a-zA-Z0-9.-]+(:[0-9]{1,5})?(/.*)?$'

    while true; do
        read -rp "$prompt_text (e.g. http://1.2.3.4:8443): " input
        if [[ "$input" =~ $url_regex ]]; then
            eval "$var_name=\"$input\""
            break
        fi
        echo " [!] Invalid URL syntax. Must begin with http:// or https://."
    done
}

add_node() {
    echo "--- [1] Add New Node ---"
    prompt_non_empty "Node Name (e.g. Node-GB)" name
    prompt_url "Node API URL" node_api_url

    local payload
    payload=$(jq -n --arg n "$name" --arg u "$node_api_url" '{name: $n, api_url: $u}')

    local resp code body
    resp=$(curl -s -w "\n%{http_code}" -X POST "$api_url/nodes" \
        -H "Authorization: Bearer $admin_key" \
        -H "Content-Type: application/json" \
        -d "$payload")
    code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')

    if [[ "$code" == "201" ]]; then
        echo -e "\n[OK] Node registered successfully:"
        echo "$body" | jq .
    else
        echo -e "\n[ERROR] Request failed (HTTP $code):"
        echo "$body" | jq . 2>/dev/null || echo "$body"
    fi
}

list_nodes() {
    echo "--- [2] All Registered Nodes ---"
    local resp code body
    resp=$(curl -s -w "\n%{http_code}" -X GET "$api_url/nodes" \
        -H "Authorization: Bearer $admin_key")
    code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')

    if [[ "$code" == "200" ]]; then
        echo "$body" | jq -r '["ID", "NAME", "ACTIVE", "API_URL"], ["--", "----", "------", "-------"], (.[] | [.id, .name, .is_active, .api_url]) | @tsv' | column -t
    else
        echo "[ERROR] Failed to fetch nodes (HTTP $code): $body"
    fi
}

delete_node() {
    echo "--- [3] Delete Node ---"
    prompt_integer "Node ID" node_id "" 1 1000000

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$api_url/nodes/$node_id" \
        -H "Authorization: Bearer $admin_key")

    if [[ "$code" == "204" ]]; then
        echo -e "\n[OK] Node #$node_id and its client mappings deleted successfully."
    elif [[ "$code" == "404" ]]; then
        echo -e "\n[!] Node #$node_id not found."
    else
        echo -e "\n[ERROR] Failed to delete node (HTTP $code)."
    fi
}

add_user() {
    echo "--- [4] Add New User ---"
    prompt_non_empty "User Surname" surname
    prompt_integer "Device Limit" device_limit "1" 1 50

    local payload
    payload=$(jq -n --arg s "$surname" --argjson d "$device_limit" '{surname: $s, device_limit: $d}')

    local resp code body
    resp=$(curl -s -w "\n%{http_code}" -X POST "$api_url/users" \
        -H "Authorization: Bearer $admin_key" \
        -H "Content-Type: application/json" \
        -d "$payload")
    code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')

    if [[ "$code" == "201" ]]; then
        echo -e "\n[OK] User created successfully:"
        echo "$body" | jq .
    else
        echo -e "\n[ERROR] Request failed (HTTP $code):"
        echo "$body" | jq . 2>/dev/null || echo "$body"
    fi
}

list_users() {
    echo "--- [5] All Users ---"
    local resp code body
    resp=$(curl -s -w "\n%{http_code}" -X GET "$api_url/users" \
        -H "Authorization: Bearer $admin_key")
    code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')

    if [[ "$code" == "200" ]]; then
        echo "$body" | jq -r '["ID", "SURNAME", "LIMIT", "SUBSCRIPTION LINK"], ["--", "-------", "-----", "-----------------"], (.[] | [.id, .surname, .device_limit, .link]) | @tsv' | column -t
    else
        echo "[ERROR] Failed to fetch users (HTTP $code): $body"
    fi
}

get_user() {
    echo "--- [6] Get User Details ---"
    prompt_integer "User ID" user_id "" 1 1000000

    local resp code body
    resp=$(curl -s -w "\n%{http_code}" -X GET "$api_url/users/$user_id" \
        -H "Authorization: Bearer $admin_key")
    code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')

    if [[ "$code" == "200" ]]; then
        echo "$body" | jq .
    elif [[ "$code" == "404" ]]; then
        echo "[!] User #$user_id not found."
    else
        echo "[ERROR] HTTP $code: $body"
    fi
}

patch_user() {
    echo "--- [7] Update User ---"
    prompt_integer "User ID to update" user_id "" 1 1000000
    read -rp "New Surname (Leave empty to keep unchanged): " surname
    read -rp "New Device Limit 1-50 (Leave empty to keep unchanged): " limit

    if [[ -z "$surname" && -z "$limit" ]]; then
        echo "[!] Nothing to update."
        return
    fi

    local payload="{}"
    if [[ -n "$surname" ]]; then
        payload=$(echo "$payload" | jq --arg s "$surname" '. + {surname: $s}')
    fi
    if [[ -n "$limit" ]]; then
        if [[ "$limit" =~ ^[0-9]+$ ]] && (( limit >= 1 && limit <= 50 )); then
            payload=$(echo "$payload" | jq --argjson l "$limit" '. + {device_limit: $l}')
        else
            echo "[!] Invalid device limit. Must be 1-50. Aborted."
            return
        fi
    fi

    local resp code body
    resp=$(curl -s -w "\n%{http_code}" -X PATCH "$api_url/users/$user_id" \
        -H "Authorization: Bearer $admin_key" \
        -H "Content-Type: application/json" \
        -d "$payload")
    code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')

    if [[ "$code" == "200" ]]; then
        echo -e "\n[OK] User updated:"
        echo "$body" | jq .
    else
        echo -e "\n[ERROR] HTTP $code:"
        echo "$body" | jq . 2>/dev/null || echo "$body"
    fi
}

delete_user() {
    echo "--- [8] Delete User ---"
    prompt_integer "User ID" user_id "" 1 1000000

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$api_url/users/$user_id" \
        -H "Authorization: Bearer $admin_key")

    if [[ "$code" == "204" ]]; then
        echo -e "\n[OK] User #$user_id and link dropped from all nodes."
    elif [[ "$code" == "404" ]]; then
        echo -e "\n[!] User #$user_id not found."
    else
        echo -e "\n[ERROR] Failed to delete user (HTTP $code)."
    fi
}

list_devices() {
    echo "--- [9] User Active Devices ---"
    prompt_integer "User ID" user_id "" 1 1000000

    local resp code body
    resp=$(curl -s -w "\n%{http_code}" -X GET "$api_url/users/$user_id/devices" \
        -H "Authorization: Bearer $admin_key")
    code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')

    if [[ "$code" == "200" ]]; then
        local count
        count=$(echo "$body" | jq '. | length')
        if [[ "$count" -eq 0 ]]; then
            echo "No devices registered for this user yet."
        else
            echo "$body" | jq -r '["SLOT", "DEVICE HWID", "OS", "CREATED AT"], ["----", "-----------", "--", "----------"], (.[] | [.slot, .device_identifier, .device_os, .created_at]) | @tsv' | column -t
        fi
    elif [[ "$code" == "404" ]]; then
        echo "[!] User or subscription not found."
    else
        echo "[ERROR] HTTP $code: $body"
    fi
}

delete_device() {
    echo "--- [10] Delete Device Slot ---"
    prompt_integer "User ID" user_id "" 1 1000000
    prompt_integer "Slot Number" slot "" 1 50

    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$api_url/users/$user_id/devices/$slot" \
        -H "Authorization: Bearer $admin_key")

    if [[ "$code" == "204" ]]; then
        echo -e "\n[OK] Device in slot #$slot deleted. Slots re-indexed."
    elif [[ "$code" == "404" ]]; then
        echo -e "\n[!] Slot or user not found."
    else
        echo -e "\n[ERROR] HTTP $code."
    fi
}

generate_node_cmd() {
    echo "--- [11] Generate Node Installation Command ---"
    
    local node_key
    node_key=$(grep -E '^(NODE_KEY)=' "$env_file" | cut -d '=' -f2- | tr -d '\r"')

    if [[ -z "$node_key" ]]; then
        echo "[ERROR] NODE_KEY not found in $env_file"
        return
    fi

    local repo_script="https://raw.githubusercontent.com/not-dispersion/xray-subscription-server/main/node-deploy.sh"

    echo
    echo "Run this command on your remote node (Ubuntu/Debian):"
    echo "--------------------------------------------------------------------------------"
    echo -e "\e[32mcurl -sSL $repo_script | sudo transfer_domain=\"$hub_domain\" transfer_key=\"$node_key\" bash\e[0m"
    echo "--------------------------------------------------------------------------------"
    echo "This will install the node agent and bind it to this Central Hub automatically."
}

show_menu() {
    clear
    echo "=================================================="
    echo "         VPN SUBSCRIPTION MANAGER CLI             "
    echo "=================================================="
    echo " [Nodes]"
    echo "   1) Add remote node"
    echo "   2) List nodes"
    echo "   3) Delete node"
    echo
    echo " [Users]"
    echo "   4) Add user"
    echo "   5) List users"
    echo "   6) Get user by ID"
    echo "   7) Update user (surname / limit)"
    echo "   8) Delete user"
    echo
    echo " [Devices & Slots]"
    echo "   9) List user devices (slots)"
    echo "  10) Delete device by slot"
    echo
    echo " [Diagnostics]"
    echo "  11) Show node setup link"
    echo "  12) View live systemd logs"
    echo "  13) Restart central-hub service"
    echo
    echo "   0) Exit"
    echo "=================================================="
}

while true; do
    show_menu
    read -rp "Select option [0-13]: " choice
    echo
    case "$choice" in
        1) add_node ;;
        2) list_nodes ;;
        3) delete_node ;;
        4) add_user ;;
        5) list_users ;;
        6) get_user ;;
        7) patch_user ;;
        8) delete_user ;;
        9) list_devices ;;
        10) delete_device ;;
        11) generate_node_cmd ;;
        12) journalctl -u central-hub -f ;;
        13) systemctl restart central-hub && echo "Service restarted." ;;
        0) echo "Goodbye!"; exit 0 ;;
        *) echo "Invalid option." ;;
    esac
    echo
    read -rp "Press Enter to continue..."
done
EOF

chmod +x /usr/local/bin/crl-hub-ctl

