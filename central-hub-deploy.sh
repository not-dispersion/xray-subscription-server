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

read -rp "Enter your root domain (e.g. example.com): " domain
domain=$(echo "$domain" | sed -e 's|^[^/]*//||' -e 's|/.*$||' | xargs)
[[ -n "$domain" ]] || { echo "Domain cannot be empty."; exit 1; }

api_domain="api.$domain"
echo "Root domain (Vue web): $domain"
echo "API domain (Central Hub): $api_domain"

domain_ip=$(getent ahostsv4 "$domain" | awk '{ print $1 }' | head -n1 || true)
api_ip=$(getent ahostsv4 "$api_domain" | awk '{ print $1 }' | head -n1 || true)

echo "Server detected IP: $ip"
echo "$domain A-record:    ${domain_ip:-NOT FOUND}"
echo "$api_domain A-record: ${api_ip:-NOT FOUND}"

[[ "$domain_ip" == "$ip" ]] || {
    echo "Error: A-record for $domain does not match server IP ($ip)."
    exit 1
}

[[ "$api_ip" == "$ip" ]] || {
    echo "Error: A-record for $api_domain does not match server IP ($ip)."
    exit 1
}
echo "DNS checks: OK"

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
    bsdextrautils \
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

mkdir -p "/var/www/$domain"
cat <<EOF > "/var/www/$domain/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$domain</title>
</head>
<body style="font-family: system-ui, -apple-system, sans-serif; display: grid; place-content: center; height: 100vh; margin: 0; background: #0f172a; color: #f8fafc; text-align: center;">
    <main>
        <h1 style="font-size: 2.5rem; margin-bottom: 0.5rem;">$domain</h1>
        <p style="color: #94a3b8;">Frontend placeholder. Deploy your Vue build files to <code>/var/www/$domain</code></p>
    </main>
</body>
</html>
EOF

cat <<EOF > "/etc/nginx/sites-available/$domain"
# central hub API backend
server {
    listen 80;
    server_name $api_domain;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

# web frontend (Vue SPA)
server {
    listen 80;
    server_name $domain;
    root /var/www/$domain;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

ln -sf "/etc/nginx/sites-available/$domain" "/etc/nginx/sites-enabled/$domain"
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

certbot --nginx \
    -d "$domain" \
    -d "$api_domain" \
    --non-interactive \
    --agree-tos \
    -m "$cert_email" \
    --redirect

echo "Nginx & SSL configured successfully:"
echo " - Web: https://$domain"
echo " - API: https://$api_domain"

cat <<EOF > "/usr/local/bin/central-hub-cli"
#!/bin/bash
set -euo pipefail

[[ \$EUID -eq 0 ]] || {
    echo "Error: Please run as root (sudo central-hub-cli)"
    exit 1
}

hub_domain="$api_domain"
api_url="https://$api_domain"
env_file="$install_dir/central-hub/.env"
EOF

cat <<'EOF' >> "/usr/local/bin/central-hub-cli"

required_commands=(
    curl
    jq
    grep
    cut
    tr
    sed
    column
    systemctl
    journalctl
)

for command in "${required_commands[@]}"; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Error: Required command '$command' is not installed."
        exit 1
    fi
done

if [[ ! -f "$env_file" ]]; then
    echo "Error: Environment file not found: $env_file"
    exit 1
fi

admin_key=$(grep -E '^ADMIN_API_KEY=' "$env_file" | cut -d '=' -f2- | tr -d '\r"')
if [[ -z "$admin_key" ]]; then
    echo "Error: ADMIN_API_KEY is missing in $env_file"
    exit 1
fi

pause() {
    while read -r -t 0 2>/dev/null; do read -r -n 1; done
    read -n 1 -s -r -p "Press any key to continue..."
    echo
}

print_error_response() {
    local body="$1"

    if [[ -n "$body" ]]; then
        echo "$body" | jq . 2>/dev/null || echo "$body"
    else
        echo "No response body."
    fi
}

api_request() {
    local method="$1"
    local endpoint="$2"
    local payload="${3:-}"

    local http_code
    local curl_args=(
        --silent
        --show-error
        --request "$method"
        "$api_url$endpoint"
        -H "Authorization: Bearer $admin_key"
    )

    if [[ -n "$payload" ]]; then
        curl_args+=(
            -H "Content-Type: application/json"
            --data "$payload"
        )
    fi

    local response
    local curl_exit_code=0
    
    set +e
    response=$(curl "${curl_args[@]}" -w "%{http_code}" 2>&1)
    curl_exit_code=$?
    set -e

    if (( curl_exit_code != 0 )); then
        echo
        echo "[ERROR] Failed to connect to backend."
        echo "$response"
        return 1
    fi

    API_CODE="${response: -3}"
    API_BODY="${response:0:${#response}-3}"

    return 0
}

prompt_non_empty() {
    local prompt_text="$1"
    local var_name="$2"
    local input=""
    while true; do
        read -rp "$prompt_text: " input
        if [[ -n "${input// /}" ]]; then
            printf -v "$var_name" '%s' "$input"
            return 0
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

        if [[ "$input" =~ ^[0-9]+$ ]] &&
            (( 10#$input >= min_val && 10#$input <= max_val )); then
            printf -v "$var_name" '%s' "$input"
            return 0
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
            printf -v "$var_name" '%s' "$input"
            return 0
        fi
        echo " [!] Invalid URL syntax. Must begin with http:// or https://."
    done
}

add_node() {
    echo "--- [1] Add New Node ---"
    prompt_non_empty "Node Name (e.g. Node-GB)" name
    prompt_url "Node API URL" node_api_url

    local payload
    payload=$(jq -n \
        --arg name "$name" \
        --arg api_url "$node_api_url" \
        '{
            name: $name,
            api_url: $api_url
        }')

    if ! api_request "POST" "/nodes" "$payload"; then
        return
    fi

    if [[ "$API_CODE" == "201" ]]; then
        echo
        echo "[OK] Node registered successfully:"

        echo "$API_BODY" |
            jq -r '
                ["ID", "NAME", "ACTIVE", "API_URL"],
                ["--", "----", "------", "-------"],
                [.id, .name, .is_active, .api_url] |
                @tsv
            ' |
            column -t
    else
        echo
        echo "[ERROR] Request failed (HTTP $API_CODE):"
        print_error_response "$API_BODY"
    fi
}

list_nodes() {
    echo "--- [2] All Registered Nodes ---"
    if ! api_request "GET" "/nodes"; then
        return
    fi

    if [[ "$API_CODE" == "200" ]]; then
        if [[ "$(echo "$API_BODY" | jq 'length')" -eq 0 ]]; then
            echo "No nodes registered."
            return
        fi

        echo "$API_BODY" |
            jq -r '
                ["ID", "NAME", "ACTIVE", "API_URL"],
                ["--", "----", "------", "-------"],
                (.[] | [.id, .name, .is_active, .api_url]) |
                @tsv
            ' |
            column -t
    else
        echo "[ERROR] Failed to fetch nodes (HTTP $API_CODE):"
        print_error_response "$API_BODY"
    fi
}

delete_node() {
    echo "--- [3] Delete Node ---"
    list_nodes
    echo
    prompt_integer "Node ID" node_id "" 1 1000000

    if ! api_request "DELETE" "/nodes/$node_id"; then
        return
    fi

    case "$API_CODE" in
        204)
            echo
            echo "[OK] Node #$node_id and its client mappings deleted successfully."
            ;;
        404)
            echo
            echo "[!] Node #$node_id not found."
            ;;
        *)
            echo
            echo "[ERROR] Failed to delete node (HTTP $API_CODE):"
            print_error_response "$API_BODY"
            ;;
    esac
}

add_user() {
    echo "--- [4] Add New User ---"
    prompt_non_empty "User Surname" surname
    prompt_integer "Device Limit" device_limit "1" 1 50

    local payload
    payload=$(jq -n \
        --arg surname "$surname" \
        --argjson device_limit "$device_limit" \
        '{
            surname: $surname,
            device_limit: $device_limit
        }')

    if ! api_request "POST" "/users" "$payload"; then
        return
    fi

    if [[ "$API_CODE" == "201" ]]; then
        echo
        echo "[OK] User created successfully:"

        echo "$API_BODY" |
            jq -r '
                ["ID", "SURNAME", "DEVICES", "SUBSCRIPTION LINK"],
                ["--", "-------", "-------", "-----------------"],
                [.id, .surname, "\(.used_devices // 0)/\(.device_limit)", .link] |
                @tsv
            ' |
            column -t
    else
        echo
        echo "[ERROR] Request failed (HTTP $API_CODE):"
        print_error_response "$API_BODY"
    fi
}

list_users() {
    echo "--- [5] All Users ---"
    if ! api_request "GET" "/users"; then
        return
    fi

    if [[ "$API_CODE" == "200" ]]; then
        if [[ "$(echo "$API_BODY" | jq 'length')" -eq 0 ]]; then
            echo "No users registered."
            return
        fi

        echo "$API_BODY" |
            jq -r '
                ["ID", "SURNAME", "DEVICES", "SUBSCRIPTION LINK"],
                ["--", "-------", "-------", "-----------------"],
                (
                    .[] |
                    [
                        .id,
                        .surname,
                        "\(.used_devices)/\(.device_limit)",
                        .link
                    ]
                ) |
                @tsv
            ' |
            column -t
    else
        echo "[ERROR] Failed to fetch users (HTTP $API_CODE):"
        print_error_response "$API_BODY"
    fi
}

patch_user() {
    echo "--- [6] Update User ---"
    list_users
    echo
    prompt_integer "User ID to update" user_id "" 1 1000000
    read -rp "New Surname (Leave empty to keep unchanged): " surname
    read -rp "New Device Limit 1-50 (Leave empty to keep unchanged): " limit

    if [[ -z "$surname" && -z "$limit" ]]; then
        echo "[!] Nothing to update."
        return
    fi

    local payload="{}"
    if [[ -n "$surname" ]]; then
        payload=$(jq \
            --arg surname "$surname" \
            '. + {surname: $surname}' <<< "$payload")
    fi
    if [[ -n "$limit" ]]; then
         if [[ "$limit" =~ ^[0-9]+$ ]] &&
           (( 10#$limit >= 1 && 10#$limit <= 50 )); then

            payload=$(jq \
                --argjson device_limit "$limit" \
                '. + {device_limit: $device_limit}' <<< "$payload")
        else
            echo "[!] Invalid device limit. Must be 1-50. Aborted."
            return
        fi
    fi

    if ! api_request "PATCH" "/users/$user_id" "$payload"; then
        return
    fi

    if [[ "$API_CODE" == "200" ]]; then
        echo
        echo "[OK] User updated successfully:"

        echo "$API_BODY" |
            jq -r '
                ["ID", "SURNAME", "DEVICES", "SUBSCRIPTION LINK"],
                ["--", "-------", "-------", "-----------------"],
                [.id, .surname, "\(.used_devices // 0)/\(.device_limit)", .link] |
                @tsv
            ' |
            column -t
    else
        echo
        echo "[ERROR] Request failed (HTTP $API_CODE):"
        print_error_response "$API_BODY"
    fi
}

delete_user() {
    echo "--- [7] Delete User ---"
    list_users
    echo
    prompt_integer "User ID" user_id "" 1 1000000

    if ! api_request "DELETE" "/users/$user_id"; then
        return
    fi

    case "$API_CODE" in
        204)
            echo
            echo "[OK] User #$user_id and link dropped from all nodes."
            ;;
        404)
            echo
            echo "[!] User #$user_id not found."
            ;;
        *)
            echo
            echo "[ERROR] Failed to delete user (HTTP $API_CODE):"
            print_error_response "$API_BODY"
            ;;
    esac
}

list_devices() {
    echo "--- [8] User Active Devices ---"
    list_users
    echo
    prompt_integer "User ID" user_id "" 1 1000000

    if ! api_request "GET" "/users/$user_id/devices"; then
        return
    fi

    if [[ "$API_CODE" == "200" ]]; then
        local count
        count=$(echo "$API_BODY" | jq 'length')

        if [[ "$count" -eq 0 ]]; then
            echo "No devices registered for this user yet."
            return
        fi

        echo "$API_BODY" |
            jq -r '
                ["SLOT", "DEVICE HWID", "OS", "CREATED AT"],
                ["----", "-----------", "--", "----------"],
                (
                    .[] |
                    [
                        .slot,
                        .device_identifier,
                        .device_os,
                        .created_at
                    ]
                ) |
                @tsv
            ' |
            column -t
    elif [[ "$API_CODE" == "404" ]]; then
        echo "[!] User or subscription not found."
    else
        echo "[ERROR] Request failed (HTTP $API_CODE):"
        print_error_response "$API_BODY"
    fi
}

delete_device() {
    echo "--- [9] Delete Device Slot ---"
    prompt_integer "User ID" user_id "" 1 1000000
    prompt_integer "Slot Number" slot "" 1 50

    if ! api_request "DELETE" "/users/$user_id/devices/$slot"; then
        return
    fi

    case "$API_CODE" in
        204)
            echo
            echo "[OK] Device in slot #$slot deleted. Slots re-indexed."
            ;;
        404)
            echo
            echo "[!] Slot or user not found."
            ;;
        *)
            echo
            echo "[ERROR] Failed to delete device (HTTP $API_CODE):"
            print_error_response "$API_BODY"
            ;;
    esac
}

generate_node_cmd() {
    echo "--- [10] Generate Node Installation Command ---"
    
    local node_key
    node_key=$(grep -E '^NODE_KEY=' "$env_file" |
        cut -d '=' -f2- |
        tr -d '\r"')

    if [[ -z "$node_key" ]]; then
        echo "[ERROR] NODE_KEY not found in $env_file"
        return
    fi

    local repo_script="https://raw.githubusercontent.com/not-dispersion/xray-subscription-server/main/node-deploy.sh"

    echo
    echo "Run this command on your remote node (Ubuntu/Debian):"
    echo "--------------------------------------------------------------------------------"
    printf '\033[32m%s\033[0m\n' \
        "curl -sSL $repo_script | sudo transfer_domain=\"$hub_domain\" transfer_key=\"$node_key\" bash"
    echo "--------------------------------------------------------------------------------"
    echo
    echo "The node agent will be installed and registered with this Central Hub."
}

view_logs() {
    echo "--- [11] Central Hub Live Logs ---"
    echo "Streaming logs (press Ctrl+C to stop)..."
    echo

    trap 'echo ""; return 0' INT
    journalctl -u central-hub -n 50 -f || true
    trap - INT

    while read -r -t 0 2>/dev/null; do read -r -n 1; done
    SKIP_PAUSE=1
}

restart_service() {
    echo "--- [12] Restart Central Hub ---"

    if systemctl restart central-hub; then
        echo
        echo "[OK] Central Hub service restarted successfully."
    else
        echo
        echo "[ERROR] Failed to restart central-hub."
        echo
        systemctl status central-hub --no-pager || true
    fi
}

show_menu() {
    clear
    echo "=================================================="
    echo "                 CENTRAL HUB CLI"
    echo "=================================================="
    echo " [Nodes]"
    echo "   1) Add remote node"
    echo "   2) List nodes"
    echo "   3) Delete node"
    echo
    echo " [Users]"
    echo "   4) Add user"
    echo "   5) List users"
    echo "   6) Update user (surname / limit)"
    echo "   7) Delete user"
    echo
    echo " [Devices & Slots]"
    echo "   8) List user devices (slots)"
    echo "   9) Delete device by slot"
    echo
    echo " [Diagnostics]"
    echo "  10) Show node setup link"
    echo "  11) View live systemd logs"
    echo "  12) Restart central-hub service"
    echo
    echo "   0) Exit"
    echo "=================================================="
}

while true; do
    show_menu
    read -rp "Select option [0-12]: " choice
    echo
    case "$choice" in
        1) add_node ;;
        2) list_nodes ;;
        3) delete_node ;;
        4) add_user ;;
        5) list_users ;;
        6) patch_user ;;
        7) delete_user ;;
        8) list_devices ;;
        9) delete_device ;;
        10) generate_node_cmd ;;
        11) view_logs ;;
        12) restart_service ;;
        0) echo "Goodbye!"; exit 0 ;;
        *) echo "[!] Invalid option. Enter a number between 0 and 12." ;;
    esac
    echo
    if [[ "${SKIP_PAUSE:-0}" == "1" ]]; then
        SKIP_PAUSE=0
    else
        echo
        pause
    fi
done
EOF

chmod +x /usr/local/bin/central-hub-cli