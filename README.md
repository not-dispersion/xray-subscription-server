
# **VPN Subscription Manager** (Central Hub)

A lightweight, asynchronous backend for managing multi-node Xray VPN subscriptions with dynamic split-tunneling configuration tailored for the **INCY** client.

No bloated panels or heavy databases. Built with FastAPI, SQLite (AsyncIO), and background state synchronization.

---

## Features

- **Dynamic Split-Tunneling:** Automatically tailors routing rules per client operating system (`Android`, `iOS`, `macOS`, `Windows`, `Linux`).
- **Hardware-Locked Device Limits:** Enforces device limits via `x-hwid` headers with support for manual slot clearing.
- **Auto-Healing & Synchronization:** Background worker regularly checks node reachability and provisions missing user keys automatically.
- **Client Verification:** Subscription delivery strictly verifies official INCY headers.
- **Zero-Friction Integration:** Clean REST API with Bearer token authentication.

---

## Installation & Deployment

### 1. Paste this into your server's shell command to start the installation: 

```bash
wget -qO install.sh https://raw.githubusercontent.com/not-dispersion/xray-subscription-server/refs/heads/main/central-hub-deploy.sh && sudo bash install.sh && rm install.sh

```
---
You can now manage everything by runnuing (**`sudo`**) `crl-hub-cli`