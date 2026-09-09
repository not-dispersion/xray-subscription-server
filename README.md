# **Xray Subscription Server and Nodes**

A lightweight, asynchronous backend for managing multi-node Xray VPN subscriptions with dynamic split-tunneling configuration transfer tailored for the **INCY** client.

No bloated panels or heavy databases. Built with FastAPI, SQLite (AsyncIO), and background state synchronization.

---

## Features

- **Split-Tunneling:** Delivers platform-ready routing profiles directly to clients (e.g., bypass rules for RU services).
- **Hardware-Locked Device Limits:** Enforces strict device limits via `x-hwid` headers with support for manual slot clearing.
- **Auto-Healing & Synchronization:** Background worker regularly health-checks nodes and auto-provisions missing client keys.
- **Client Verification:** Subscription delivery strictly verifies official INCY headers.
- **Dual-Host Ready:** Automatically configures Nginx for an `api.` backend subdomain while reserving the root domain for a frontend (e.g., Vue SPA).
- **Zero-Friction Management:** Interactive CLI utility (`central-hub-cli`) and REST API protected by Bearer token authentication.

---

## Installation & Deployment

### Step 1: Deploy Central Hub

Prerequisites: Point your root domain (`example.com`) and API subdomain (`api.example.com`) to your Central Hub server's IP address.

Run this command on your clean Ubuntu/Debian server:

```bash
wget -qO install.sh [https://raw.githubusercontent.com/not-dispersion/xray-subscription-server/refs/heads/main/central-hub-deploy.sh](https://raw.githubusercontent.com/not-dispersion/xray-subscription-server/refs/heads/main/central-hub-deploy.sh) && sudo bash install.sh && rm install.sh

```

Follow the interactive prompts (enter root domain and Let's Encrypt email). Once finished, manage your hub anytime using:

```bash
sudo central-hub-cli

```

---

### Step 2: Deploy & Connect Remote Nodes

1. Open the management CLI on your Central Hub:
```bash
sudo central-hub-cli

```


2. Select option **`10` (`Generate Node Installation Command`)**. Copy the generated green command string.
3. Paste and run that command on your remote node server (Ubuntu/Debian):
```bash
curl -sSL [https://raw.githubusercontent.com/not-dispersion/xray-subscription-server/main/node-deploy.sh](https://raw.githubusercontent.com/not-dispersion/xray-subscription-server/main/node-deploy.sh) | sudo transfer_domain="api.example.com" transfer_key="<YOUR_GENERATED_KEY>" bash

```


*The script installs the Node Agent, provisions UFW rules to accept control traffic **only** from the Central Hub IP, and starts the systemd service.*
4. Return to `central-hub-cli` on the Central Hub and select option **`1` (`Add remote node`)**:
* **Node Name:** A label of your choice (e.g., `Node-NL`, `Node-DE`).
* **Node API URL:** `http://<NODE_IP>:8443` (or your custom node port).



The Central Hub's background reconciliation worker will automatically discover the node, perform a handshake, and sync all active users.